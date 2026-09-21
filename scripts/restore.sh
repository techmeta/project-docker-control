#!/usr/bin/env bash
# =============================================================================
#  Restore.     scripts/restore.sh <db|redis|files|config> [artifact]
# -----------------------------------------------------------------------------
#  Every path through this script is destructive, so every path through it:
#
#    1. requires CONFIRM=yes                (no accidental invocation)
#    2. verifies the artifact's checksum    (before anything is touched)
#    3. takes a safety backup first         (SKIP_SAFETY=1 to opt out)
#    4. stops the writers                   (a restore under live traffic
#                                            produces a database that matches
#                                            neither the backup nor production)
#    5. names exactly what it did           (including how to undo it)
#
#  With no artifact it lists what is available and asks. With LATEST=1 it takes
#  the newest of that target, which is what the disaster-recovery runbook uses.
#
#  `config` is the exception and does NOT overwrite anything: it unpacks to a
#  staging directory and tells you what differs. Restoring a .env over a
#  running stack silently changes credentials the datastores were created with,
#  and the symptom is an authentication failure against a file that looks
#  correct.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

assert_configured
need docker

TARGET="${1:-}"
ARTIFACT="${2:-${FILE:-}}"
BACKUPS="$(abs "$(cfg BACKUP_DIR ./backups)")"
APP_SERVICES="octane scheduler queue-important queue-default"

case "$TARGET" in
    db|redis|files|config) ;;
    "") die "which target?" "  make restore TARGET=db" "  make restore TARGET=redis FILE=redis-20260921-020000.rdb.zst" ;;
    *)  die "unknown target '$TARGET'." "Use one of: db  redis  files  config" ;;
esac

# ─── choose the artifact ────────────────────────────────────────────────────
list_target() {
    find "$BACKUPS" -maxdepth 1 -type f -name "$1-*" \
        ! -name '*.sha256' ! -name '*.json' ! -name '*.part' \
        -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-
}

if [ -z "$ARTIFACT" ]; then
    mapfile -t available < <(list_target "$TARGET")
    [ "${#available[@]}" -gt 0 ] || die "no '$TARGET' artifacts in $BACKUPS." \
        "  make backup-list        # what is there" \
        "  make backup TARGET=$TARGET"

    if [ "${LATEST:-0}" = 1 ] || [ ! -t 0 ]; then
        ARTIFACT="${available[0]}"
        c_info "using the newest: $(basename "$ARTIFACT")"
    else
        c_head "Available '$TARGET' backups"
        i=0
        for f in "${available[@]}"; do
            i=$((i + 1))
            printf '  %2d) %-42s %8s  %s\n' "$i" "$(basename "$f")" \
                "$(human "$(stat -c '%s' "$f")")" \
                "$(date -d "@$(stat -c '%Y' "$f")" '+%Y-%m-%d %H:%M')"
            [ "$i" -ge 20 ] && break
        done
        printf '\n  Which? [1-%d, or Enter for 1]: ' "$i"
        read -r choice
        choice="${choice:-1}"
        [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] \
            || die "'$choice' is not one of the listed numbers."
        ARTIFACT="${available[$((choice - 1))]}"
    fi
fi

[ -f "$ARTIFACT" ] || ARTIFACT="$BACKUPS/$ARTIFACT"
[ -f "$ARTIFACT" ] || die "no such artifact: $ARTIFACT"

# ─── verify before touching anything ────────────────────────────────────────
c_head "Restore $TARGET from $(basename "$ARTIFACT")"

if [ -f "$ARTIFACT.sha256" ]; then
    c_do "verifying checksum"
    ( cd "$(dirname "$ARTIFACT")" && sha256sum -c --status "$(basename "$ARTIFACT").sha256" ) \
        || die "CHECKSUM MISMATCH on $(basename "$ARTIFACT")." \
               "The artifact is corrupt or was modified. Do not restore it." \
               "Pick another:  make backup-list"
    c_ok "checksum matches"
else
    c_warn "no .sha256 beside this artifact — restoring unverified"
fi

if [ -f "$ARTIFACT.json" ]; then
    c_info "taken $(sed -n 's/.*"created_at": *"\([^"]*\)".*/\1/p' "$ARTIFACT.json") from image tag $(sed -n 's/.*"app_tag": *"\([^"]*\)".*/\1/p' "$ARTIFACT.json")"
fi

# ─── confirm ────────────────────────────────────────────────────────────────
if [ "$TARGET" != "config" ] && [ "${CONFIRM:-}" != "yes" ]; then
    die "this replaces the live $TARGET. Re-run with CONFIRM=yes." \
        "  make restore TARGET=$TARGET FILE=$(basename "$ARTIFACT") CONFIRM=yes" \
        "" \
        "A safety backup is taken first unless SKIP_SAFETY=1."
fi
if [ "$(cfg DEPLOY_ENV)" = "production" ] && [ "$TARGET" != "config" ]; then
    c_warn "DEPLOY_ENV=production — this is the live stack"
fi

# ─── a way back ─────────────────────────────────────────────────────────────
#  The commonest restore disaster is restoring the wrong artifact, and the
#  commonest reason it is unrecoverable is that the thing being replaced was
#  never captured. This is cheap; skip it only when the disk cannot hold it.
safety_backup() {
    [ "${SKIP_SAFETY:-0}" = 1 ] && { c_warn "SKIP_SAFETY=1 — no way back from this"; return 0; }
    c_do "safety backup of the current $1 first"
    "$REPO_ROOT/scripts/backup.sh" "$1" --no-retention >/dev/null \
        || die "the safety backup failed, so the restore has not started." \
               "Fix that first, or re-run with SKIP_SAFETY=1 to accept the risk."
    c_ok "current $1 captured"
}

# Run a command as root against a data directory without needing host sudo,
# using an image that is already on this machine. `docker run` is root inside
# the container; the bind mount is the same directory either way.
in_root_container() {
    local hostdir="$1" indir="$2" script="$3"
    local -a mounts=(-v "$hostdir:/target")
    [ -n "$indir" ] && mounts+=(-v "$indir:/in:ro")
    docker run --rm --network none "${mounts[@]}" \
        "redis:$(cfg REDIS_VERSION 8-alpine)" sh -c "$script"
}

stop_writers() {
    c_do "stopping the application containers"
    # shellcheck disable=SC2086
    dc stop $APP_SERVICES >/dev/null 2>&1 || true
}
start_writers() {
    c_do "starting the application containers"
    # shellcheck disable=SC2086
    dc up -d $APP_SERVICES >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
#  db
# -----------------------------------------------------------------------------
#  REPLACE by default, MERGE=1 to opt out, and the difference is not academic.
#
#  The obvious implementation — `pg_restore --clean --if-exists` — is a MERGE,
#  whatever it looks like. --clean drops each object THE DUMP CONTAINS before
#  recreating it, so anything created after the backup was taken simply stays.
#  Restoring a dump from before a bad migration leaves that migration's new
#  tables in place while replacing the `migrations` table with one that does
#  not list them, and the next deploy then fails on "relation already exists".
#  That is a confusing morning after an already bad night.
#
#  So the default drops the public schema and restores into an empty one, which
#  is what "restore" means to everyone who asks for it.
#
#  THE WINDOW: dropping the schema and restoring it are two transactions. In
#  between, the database is empty. If pg_restore then fails, the database STAYS
#  empty, and the way back is the safety backup this script took moments
#  earlier — which is why that backup is not optional and why the failure
#  message below names the artifact rather than describing it.
#
#  MERGE=1 keeps the old behaviour, which is the right choice for the other
#  common case: rows were deleted, the schema is fine, and you want the dump's
#  contents laid back over a database that is otherwise current.
# ─────────────────────────────────────────────────────────────────────────────
restore_db() {
    require_service postgres
    safety_backup db
    local safety
    safety="$(find "$BACKUPS" -maxdepth 1 -name 'db-*.dump' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2-)"
    stop_writers

    local db user
    db="$(app_cfg DB_DATABASE)"; user="$(app_cfg DB_USERNAME)"

    local -a restore_args=(-U "$user" -d "$db" --no-owner --no-acl --single-transaction)

    if [ "${MERGE:-0}" = 1 ]; then
        c_do "pg_restore into $db (MERGE — objects not in the dump are kept)"
        restore_args+=(--clean --if-exists)
    else
        c_do "dropping the public schema (MERGE=1 to restore over the top instead)"
        dc exec -T postgres psql -U "$user" -d "$db" -q -v ON_ERROR_STOP=1 \
            -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; ALTER SCHEMA public OWNER TO \"$user\"; GRANT ALL ON SCHEMA public TO \"$user\"; GRANT USAGE ON SCHEMA public TO public;" \
            || { start_writers; die "could not reset the schema; nothing was changed."; }
        c_do "pg_restore into $db"
    fi

    local errs=0
    dc exec -T postgres pg_restore "${restore_args[@]}" < "$ARTIFACT" 2>/tmp/otc-pgrestore.err || errs=1

    if [ "$errs" = 1 ]; then
        c_warn "pg_restore reported errors"
        tail -8 /tmp/otc-pgrestore.err >&2 || true
        start_writers
        if [ "${MERGE:-0}" = 1 ]; then
            # --single-transaction rolled the whole thing back, so the
            # database is exactly as it was.
            die "restore failed and rolled back; the database is unchanged." \
                "Full output: /tmp/otc-pgrestore.err"
        fi
        die "restore failed AFTER the schema was dropped — THE DATABASE IS EMPTY." \
            "Full output: /tmp/otc-pgrestore.err" \
            "" \
            "The safety backup taken moments ago is the way back:" \
            "  make restore TARGET=db FILE=$(basename "${safety:-<see make backup-list>}") CONFIRM=yes SKIP_SAFETY=1"
    fi

    # A freshly restored database has NO statistics, so the planner picks
    # sequential scans for everything until autovacuum gets round to it. The
    # first hour after a restore is otherwise mysteriously slow.
    c_do "ANALYZE"
    dc exec -T postgres psql -U "$user" -d "$db" -q -c 'ANALYZE;' >/dev/null 2>&1 || true

    local tables
    tables="$(dc exec -T postgres psql -U "$user" -d "$db" -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d '\r')"
    c_ok "${tables:-?} tables in public"

    start_writers
    log_line OK "restored db from $(basename "$ARTIFACT")${MERGE:+ (merge)}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  redis
# -----------------------------------------------------------------------------
#  THE TRAP: with appendonly yes, redis loads the AOF and IGNORES dump.rdb.
#  Dropping a restored RDB into data/redis and restarting therefore appears to
#  work and restores nothing — the old dataset comes back from the AOF and the
#  only evidence is a line in the log nobody reads.
#
#  So: stop, move the AOF directory ASIDE (kept, not deleted), put the RDB in
#  place, start with appendonly=no so the RDB is actually loaded, then turn
#  appendonly back on — which triggers a rewrite of the AOF from the loaded
#  dataset — and finally recreate the container on the declared configuration.
# ─────────────────────────────────────────────────────────────────────────────
restore_redis() {
    safety_backup redis
    stop_writers

    local dir tmpd suffix
    dir="$(abs "$(cfg DATA_REDIS_DIR ./data/redis)")"
    tmpd="$(mktemp -d -t otc-redis-restore-XXXXXX)"
    suffix="pre-restore-$(stamp)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpd'" EXIT

    c_do "decompressing the snapshot"
    case "$ARTIFACT" in
        *.zst) need zstd; zstd -dc "$ARTIFACT" > "$tmpd/dump.rdb" ;;
        *.gz)  gzip -dc "$ARTIFACT" > "$tmpd/dump.rdb" ;;
        *)     cp "$ARTIFACT" "$tmpd/dump.rdb" ;;
    esac
    [ "$(head -c 5 "$tmpd/dump.rdb")" = "REDIS" ] \
        || die "that file is not an RDB snapshot." "Header: $(head -c 5 "$tmpd/dump.rdb" | tr -c '[:print:]' '.')"
    chmod 0644 "$tmpd/dump.rdb"

    c_do "stopping redis"
    dc stop redis >/dev/null 2>&1 || true

    # Move the AOF aside rather than deleting it. It is the only copy of
    # everything written since the snapshot, and it is small.
    c_do "moving the existing AOF aside (appendonlydir.$suffix)"
    in_root_container "$dir" "$tmpd" "
        set -e
        [ -d /target/appendonlydir ] && mv /target/appendonlydir /target/appendonlydir.$suffix || true
        [ -f /target/dump.rdb ] && mv /target/dump.rdb /target/dump.rdb.$suffix || true
        cp /in/dump.rdb /target/dump.rdb
        chown -R 999:999 /target
        chmod 0660 /target/dump.rdb
    " >/dev/null

    # One boot with appendonly off, so the RDB is what gets loaded.
    c_do "starting redis with appendonly=no so the snapshot is loaded"
    REDIS_APPENDONLY=no dc up -d --force-recreate redis >/dev/null
    local waited=0
    until dc exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; do
        sleep 1; waited=$((waited + 1))
        [ "$waited" -lt 60 ] || die "redis did not come up within 60s." "docker compose logs redis"
    done
    c_ok "loaded $(dc exec -T redis redis-cli dbsize 2>/dev/null | tr -d '\r') keys in db0"

    # Turning appendonly on rewrites the AOF from the in-memory dataset, which
    # is what makes the restore durable. Waiting for it matters: recreating the
    # container mid-rewrite loses the restored data and silently reloads the
    # RDB again on the next boot.
    c_do "rebuilding the AOF from the restored dataset"
    dc exec -T redis redis-cli config set appendonly yes >/dev/null
    waited=0
    until [ "$(dc exec -T redis redis-cli info persistence 2>/dev/null | sed -n 's/^aof_rewrite_in_progress:\([0-9]*\).*/\1/p' | tr -d '\r')" = "0" ]; do
        sleep 1; waited=$((waited + 1))
        [ "$waited" -lt 300 ] || die "the AOF rewrite did not finish within 300s." \
            "Do NOT recreate the container; check: docker compose logs redis"
    done
    c_ok "AOF rewritten"

    c_do "recreating redis on the declared configuration"
    dc up -d --force-recreate redis >/dev/null
    waited=0
    until dc exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; do
        sleep 1; waited=$((waited + 1))
        [ "$waited" -lt 60 ] || die "redis did not come back up after the rewrite." "docker compose logs redis"
    done

    start_writers
    c_info "the previous dataset is kept at $dir/appendonlydir.$suffix — delete it when you are satisfied"
    log_line OK "restored redis from $(basename "$ARTIFACT")"
}

# ─────────────────────────────────────────────────────────────────────────────
#  files
# ---------------------------------------------------------------------------
#  Extracted OVER the existing tree, not into an empty one: a files backup
#  excludes the regenerable subtrees, so wiping first would delete the live
#  cache for no reason. Anything present in both is overwritten by the backup.
# ─────────────────────────────────────────────────────────────────────────────
restore_files() {
    safety_backup files
    stop_writers

    local dir gid
    dir="$(abs "$(cfg DATA_STORAGE_DIR ./data/storage)")"
    gid="$(cfg HOST_GID "$(id -g)")"

    c_do "extracting into $dir"
    case "$ARTIFACT" in
        *.zst) need zstd; zstd -dc "$ARTIFACT" | tar -C "$dir" -xf - --numeric-owner ;;
        *.gz)  gzip -dc "$ARTIFACT" | tar -C "$dir" -xf - --numeric-owner ;;
        *)     tar -C "$dir" -xf "$ARTIFACT" --numeric-owner ;;
    esac

    # Whatever the tar left, the containers must be able to write it.
    c_do "restoring ownership (uid 33, gid $gid)"
    in_root_container "$dir" "" "chown -R 33:$gid /target && chmod -R g+rwX /target && find /target -type d -exec chmod g+s {} +" >/dev/null

    start_writers
    log_line OK "restored files from $(basename "$ARTIFACT")"
}

# ─────────────────────────────────────────────────────────────────────────────
#  config — unpacked, never applied
# ---------------------------------------------------------------------------
#  Overwriting a live .env changes the credentials the datastores were CREATED
#  with. postgres does not re-read POSTGRES_PASSWORD on an existing cluster, so
#  the result is an app that cannot authenticate against a file that looks
#  right — the hardest class of failure to see. So: unpack, diff, decide.
# ─────────────────────────────────────────────────────────────────────────────
restore_config() {
    local dest
    dest="$REPO_ROOT/restore-config-$(stamp)"
    mkdir -p "$dest"; chmod 0700 "$dest"

    c_do "unpacking to $(basename "$dest")/"
    case "$ARTIFACT" in
        *.gpg) need gpg; gpg --batch --quiet --decrypt "$ARTIFACT" | tar -C "$dest" -xzf - ;;
        *)     tar -C "$dest" -xzf "$ARTIFACT" ;;
    esac
    chmod -R go-rwx "$dest"

    c_head "What differs from the live configuration"
    local any=0
    while IFS= read -r f; do
        rel="${f#$dest/}"
        if [ -f "$REPO_ROOT/$rel" ]; then
            if ! diff -q "$REPO_ROOT/$rel" "$f" >/dev/null 2>&1; then
                any=1
                printf '  %s%s%s\n' "$C_YLW" "$rel" "$C_OFF"
                diff -u "$REPO_ROOT/$rel" "$f" | sed -n '3,12p' | sed 's/^/      /'
            fi
        else
            any=1; printf '  %s%s%s (not present in the live tree)\n' "$C_YLW" "$rel" "$C_OFF"
        fi
    done < <(find "$dest" -type f)
    [ "$any" = 1 ] || c_ok "identical to the live configuration"

    c_head "Nothing has been changed"
    c_info "the files are in $dest/ — copy across what you want, by hand"
    c_info "changing DB_PASSWORD here does NOT change the role on an existing cluster: make db-password"
    c_info "rm -rf $dest   when you are done (it holds secrets)"
    log_line OK "unpacked config from $(basename "$ARTIFACT") to $(basename "$dest")"
}

with_lock datastore "restore_$TARGET"
c_head "Restore complete"
