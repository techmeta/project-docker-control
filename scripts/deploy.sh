#!/usr/bin/env bash
# =============================================================================
#  Deploy.     scripts/deploy.sh [TAG]        scripts/deploy.sh --rollback
# -----------------------------------------------------------------------------
#      pull the tag  ->  restart  ->  wait for healthy  ->  migrate  ->  verify
#
#  Nothing is built. The image was built and reviewed somewhere else; this
#  fetches it by an immutable tag and swaps it in.
#
#  THE ORDER IS THE POINT. A database backup is taken BEFORE the new image
#  runs, and migrations run AFTER the containers are healthy — so a migration
#  that fails has a dump taken minutes earlier, from a schema that matched the
#  code that was running.
#
#  The tag that is deployed is written back into .env and recorded in
#  .deployed, and the one it replaced in .deployed.prev, which is what makes
#  `--rollback` a command rather than an archaeology exercise.
#
#  ROLLBACK IS NOT SYMMETRIC, and the script says so rather than pretending:
#  it restores the previous IMAGE. It does not un-run a migration. If the
#  deploy that failed applied one, the old image may not understand the new
#  schema, and the restore is from the dump this script took.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

assert_configured
need docker

ROLLBACK=0
NEW_TAG=""
case "${1:-}" in
    --rollback) ROLLBACK=1 ;;
    "")         ;;
    *)          NEW_TAG="$1" ;;
esac

IMAGE="$(cfg APP_IMAGE)"
CURRENT_TAG="$(cfg APP_TAG)"
STACK="$(cfg STACK_NAME otc)"
TIMEOUT="$(cfg DEPLOY_TIMEOUT 180)"
SERVICES="postgres redis octane scheduler queue-important queue-default"

# Rewrite APP_TAG in place. sed on the one line, not a rewrite of the file:
# .env holds the registry token and comments an operator wrote, and a
# regenerated file loses both.
set_tag() {
    local tag="$1"
    if grep -q '^APP_TAG=' "$ENV_FILE"; then
        sed -i "s|^APP_TAG=.*|APP_TAG=$tag|" "$ENV_FILE"
    else
        printf 'APP_TAG=%s\n' "$tag" >> "$ENV_FILE"
    fi
}

if [ "$ROLLBACK" = 1 ]; then
    [ -f "$REPO_ROOT/.deployed.prev" ] || die "no previous deploy recorded." \
        "Nothing has been deployed from this checkout yet, or .deployed.prev was removed." \
        "Deploy an explicit tag instead:  make deploy TAG=sha-1a79309"
    NEW_TAG="$(cat "$REPO_ROOT/.deployed.prev")"
    c_head "Rolling back to $NEW_TAG"
    c_warn "this restores the IMAGE only — a migration applied since then is still applied"
    c_info "if the schema moved:  make restore TARGET=db CONFIRM=yes"
fi

[ -n "$NEW_TAG" ] || NEW_TAG="$CURRENT_TAG"
case "$NEW_TAG" in
    latest|main|master|stable)
        die "refusing to deploy the floating tag '$NEW_TAG'." \
            "There would be nothing to roll back to, and no way to tell two hosts apart." \
            "Use the sha-<short> tag the build published." ;;
esac

c_head "Deploy $IMAGE:$NEW_TAG   (stack: $STACK)"
[ "$NEW_TAG" = "$CURRENT_TAG" ] && c_info "same tag as the running deploy — this is a restart with a re-pull"

# ─── 1. host state ──────────────────────────────────────────────────────────
"$REPO_ROOT/scripts/preflight.sh" >/dev/null || die "preflight failed." "Run it directly to see why:  make preflight"
c_ok "preflight"

# ─── 2. a way back, taken before anything changes ───────────────────────────
if [ "$(cfg DEPLOY_BACKUP 1)" = 1 ] && [ "$ROLLBACK" = 0 ] && svc_running postgres; then
    c_do "database backup before deploying"
    "$REPO_ROOT/scripts/backup.sh" db --no-retention >/dev/null \
        || die "the pre-deploy backup failed, so the deploy has not started." \
               "Fix the backup first — deploying without one is how a bad migration becomes an incident." \
               "To proceed anyway:  DEPLOY_BACKUP=0 make deploy TAG=$NEW_TAG"
    c_ok "backup taken"
elif [ "$ROLLBACK" = 0 ]; then
    [ "$(cfg DEPLOY_BACKUP 1)" = 1 ] || c_warn "DEPLOY_BACKUP=0 — deploying without a way back"
fi

# ─── 3. pull ────────────────────────────────────────────────────────────────
if [ "$(cfg DEPLOY_PULL 1)" = 1 ]; then
    c_do "docker pull $IMAGE:$NEW_TAG"
    if ! docker pull "$IMAGE:$NEW_TAG"; then
        die "could not pull $IMAGE:$NEW_TAG" \
            "  • private package?   make login" \
            "  • ghcr.io needs the owner in lowercase, and a token with read:packages" \
            "  • wrong tag?         the build publishes sha-<short>, not a branch name" \
            "Nothing has changed; the running stack is untouched."
    fi
    c_ok "pulled"
else
    docker image inspect "$IMAGE:$NEW_TAG" >/dev/null 2>&1 \
        || die "DEPLOY_PULL=0 but $IMAGE:$NEW_TAG is not on this host."
fi

# The digest is what actually identifies the bits. Two hosts on the same tag
# can differ; two hosts on the same digest cannot.
digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE:$NEW_TAG" 2>/dev/null || echo '')"
[ -n "$digest" ] && c_info "digest ${digest##*@}"

# ─── 4. swap ────────────────────────────────────────────────────────────────
[ -f "$REPO_ROOT/.deployed" ] && cp "$REPO_ROOT/.deployed" "$REPO_ROOT/.deployed.prev"
[ -f "$REPO_ROOT/.deployed.prev" ] || printf '%s\n' "$CURRENT_TAG" > "$REPO_ROOT/.deployed.prev"
set_tag "$NEW_TAG"

c_do "recreating the containers"
# --remove-orphans is safe HERE and is not safe everywhere: it removes
# containers belonging to THIS compose project that this file no longer
# declares. The network and the project name are owned by this repository, so
# the blast radius is this stack. Against a shared or external project it
# would take other people's containers down with it.
#
# No -v. Never a -v on anything in this repository: the data is in bind
# mounts, but a named volume appearing later must not be silently removable
# by a routine deploy.
if ! dc up -d --remove-orphans; then
    set_tag "$CURRENT_TAG"
    die "compose could not start the stack; APP_TAG has been put back to $CURRENT_TAG." \
        "  docker compose logs --tail=50"
fi

# ─── 5. wait for it to actually be serving ──────────────────────────────────
#  `up -d` returns when the containers are CREATED, not when the application
#  answers. Deploys that "succeed" and then 502 for two minutes are this gap.
c_do "waiting for health (up to ${TIMEOUT}s)"
deadline=$(( $(date +%s) + TIMEOUT ))
unhealthy=""
while :; do
    unhealthy=""
    for svc in $SERVICES; do
        cid="$(dc ps -q "$svc" 2>/dev/null || true)"
        if [ -z "$cid" ]; then unhealthy="$unhealthy $svc(missing)"; continue; fi
        state="$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)"
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)"
        case "$health" in
            healthy|none)
                # No healthcheck (scheduler, the queue lanes): running is the
                # best signal available, and a crash-loop shows as restarting.
                [ "$state" = running ] || unhealthy="$unhealthy $svc($state)" ;;
            *) unhealthy="$unhealthy $svc($health)" ;;
        esac
    done
    [ -z "$unhealthy" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 3
done

if [ -n "$unhealthy" ]; then
    c_warn "not healthy after ${TIMEOUT}s:$unhealthy"
    dc logs --tail=30 octane 2>&1 | sed 's/^/    /' || true
    die "deploy failed — the stack is running $NEW_TAG and is not healthy." \
        "Roll the image back:   make rollback" \
        "Or investigate first:  make logs"
fi
c_ok "all containers healthy"

# ─── 6. migrations ──────────────────────────────────────────────────────────
#  After health, not before: a migration against a container that cannot even
#  boot tells you nothing, and a half-migrated database is worse than an
#  un-migrated one.
if [ "$(cfg DEPLOY_MIGRATE 1)" = 1 ] && [ "$ROLLBACK" = 0 ]; then
    pending="$(dc exec -T octane php artisan migrate:status --pending 2>/dev/null | grep -c 'Pending' || true)"
    if [ "${pending:-0}" -gt 0 ]; then
        c_do "$pending pending migration(s)"
        if ! dc exec -T octane php artisan migrate --force --no-interaction; then
            die "migrations FAILED against $NEW_TAG." \
                "The containers are healthy but the schema is in an unknown state." \
                "The dump taken at the start of this deploy is the way back:" \
                "  make backup-list" \
                "  make restore TARGET=db CONFIRM=yes" \
                "  make rollback"
        fi
        c_ok "migrated"
    else
        c_ok "no pending migrations"
    fi
elif [ "$ROLLBACK" = 1 ]; then
    c_info "migrations not touched by a rollback — see the warning above"
fi

# ─── 7. verify, record ──────────────────────────────────────────────────────
printf '%s\n' "$NEW_TAG" > "$REPO_ROOT/.deployed"
"$REPO_ROOT/scripts/health.sh" || c_warn "the stack is up but health reported a problem"

log_line OK "deployed $IMAGE:$NEW_TAG${digest:+ (${digest##*@})}"
notify ok "[$STACK] deployed $NEW_TAG"

c_head "Deployed $NEW_TAG"
c_info "previous: $(cat "$REPO_ROOT/.deployed.prev" 2>/dev/null || echo unknown)   (make rollback)"
