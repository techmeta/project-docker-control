#!/usr/bin/env bash
# =============================================================================
#  Everything that must be true BEFORE a container starts.
# -----------------------------------------------------------------------------
#  Run by `make up`, `make deploy` and `make init`. It is cheap; it runs every
#  time on purpose.
#
#  It checks four things, and each one is here because the failure it prevents
#  is expensive and reads like something else:
#
#    1. the two env files exist and hold the keys compose interpolates
#       — otherwise `up` dies on "${DB_PASSWORD:?...}" with no clue which file
#    2. the bind-mount directories exist with the right owner AND mode
#       — otherwise docker creates them root:root and postgres crash-loops on
#         "could not change permissions of directory"
#    3. the per-service memory limits actually fit inside STACK_MEM_LIMIT
#       — otherwise "4 GB" is a comment, and the kernel enforces the real
#         number by OOM-killing postgres mid-write
#    4. the storage sub-budgets fit inside STACK_STORAGE_LIMIT, and the disk
#       is big enough to hold them
#
#  MODES
#    (no args)      everything
#    --dirs-only    just the directories (what `make init` needs)
#    --budget-only  just the RAM and disk arithmetic, no host changes
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

MODE="${1:-all}"

# ─── 0. configuration exists ────────────────────────────────────────────────
assert_configured
APP_ENV="$(app_env_path)"

if [ "$MODE" != "--dirs-only" ] && [ "$MODE" != "--budget-only" ]; then
    c_head "Configuration"

    # The image reference. A floating tag on a server cannot be rolled back
    # and cannot tell you what it is running; two hosts pulling "the same"
    # latest can legitimately differ.
    image="$(cfg APP_IMAGE)"; tag="$(cfg APP_TAG)"
    [ -n "$image" ] || die "APP_IMAGE is empty in .env." \
        "This repository runs a published package; it has nothing to build." \
        "  APP_IMAGE=ghcr.io/<owner>/<package>"
    [ -n "$tag" ] || die "APP_TAG is empty in .env." \
        "Use the immutable sha-<short> tag the build published."
    case "$tag" in
        latest|main|master|stable)
            die "APP_TAG=$tag — a floating tag." \
                "A host running a floating tag cannot tell you what it is running," \
                "two hosts pulling it can differ, and there is nothing to roll back to." \
                "Use the sha-<short> tag:  make deploy TAG=sha-1a79309" ;;
    esac
    # ghcr.io rejects a capitalised owner with a bare "denied", which reads as
    # an authentication problem and sends people to regenerate a working token.
    case "$image" in
        ghcr.io/*[A-Z]*)
            die "APP_IMAGE has uppercase characters: $image" \
                "ghcr.io requires the owner and package in lowercase." \
                "It fails with a bare 'denied' that looks like an auth error." ;;
    esac
    c_ok "image  $image:$tag"

    # This stack speaks one database dialect. Asserting it names the file and
    # the key; not asserting it produces a 60-second connection timeout.
    conn="$(app_cfg DB_CONNECTION)"
    [ "$conn" = "pgsql" ] || die \
        "DB_CONNECTION=${conn:-<unset>} in $APP_ENV — this stack is PostgreSQL-only." \
        "There is no mysql client in the image and no mysql service in compose.yml." \
        "Set DB_CONNECTION=pgsql."

    # compose interpolates these out of config/app.env with ${VAR:?...}.
    # Catching them here names the file and the key.
    for key in DB_DATABASE DB_USERNAME DB_PASSWORD REDIS_PASSWORD APP_KEY; do
        [ -n "$(app_cfg "$key")" ] || die \
            "$key is empty in $APP_ENV." \
            "postgres and redis are created from these values; they cannot be blank." \
            "  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 28"
    done
    c_ok "credentials present in $(basename "$APP_ENV")"

    # DB_HOST/REDIS_HOST must name the compose SERVICES — inside the project
    # network that is the hostname. 127.0.0.1 is the container's own loopback
    # and reaches nothing.
    for pair in "DB_HOST postgres" "REDIS_HOST redis"; do
        set -- $pair
        got="$(app_cfg "$1")"
        [ -z "$got" ] || [ "$got" = "$2" ] || die \
            "$1=$got in $APP_ENV, but this stack serves it as the compose service '$2'." \
            "Inside the project network that name IS the hostname." \
            "Set $1=$2."
    done
    c_ok "service hostnames match compose.yml"

    # Debug mode in production dumps the environment — including DB_PASSWORD
    # and APP_KEY — into the browser on any unhandled exception.
    if [ "$(cfg DEPLOY_ENV)" = "production" ] && [ "$(app_cfg APP_DEBUG)" = "true" ]; then
        c_warn "APP_DEBUG=true with DEPLOY_ENV=production"
        c_info "an unhandled exception will render APP_KEY and DB_PASSWORD into the browser"
    fi
    if [ "$(cfg DEPLOY_ENV)" = "production" ] && [ "$(app_cfg TELESCOPE_ENABLED)" = "true" ]; then
        c_warn "TELESCOPE_ENABLED=true with DEPLOY_ENV=production"
        c_info "it records every request, query and job into the database"
    fi
fi

# ─── 1. the RAM budget is real arithmetic, not a comment ────────────────────
if [ "$MODE" != "--dirs-only" ]; then
    c_head "Resource budget"

    budget="$(to_bytes "$(cfg STACK_MEM_LIMIT 4g)")"
    total=0; breakdown=""
    for pair in \
        "PG_MEM_LIMIT postgres" \
        "REDIS_MEM_LIMIT redis" \
        "OCTANE_MEM_LIMIT octane" \
        "SCHEDULER_MEM_LIMIT scheduler" \
        "QUEUE_IMPORTANT_MEM_LIMIT queue-important" \
        "QUEUE_DEFAULT_MEM_LIMIT queue-default"
    do
        set -- $pair
        v="$(to_bytes "$(cfg "$1" 0)")"
        total=$((total + v))
        breakdown="${breakdown}$(printf '\n      %-16s %s' "$2" "$(human "$v")")"
    done

    if [ "$total" -gt "$budget" ]; then
        die "the per-service memory limits sum to $(human "$total"), over STACK_MEM_LIMIT=$(human "$budget")." \
            "Docker has no cross-service limit, so this is the only place the budget is real." \
            "Either lower a service limit or raise STACK_MEM_LIMIT in .env.${breakdown}"
    fi
    c_ok "memory  $(human "$total") of $(human "$budget") budgeted$([ "$total" -lt "$budget" ] && printf ' (%s unallocated)' "$(human $((budget - total)))")"

    # The budget can be internally consistent and still larger than the
    # machine. Containers do not share a limit; six of them at their ceiling
    # at once is the number the host has to survive.
    if [ -r /proc/meminfo ]; then
        host_kb="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)"
        host_b=$((host_kb * 1024))
        if [ "$total" -gt $((host_b * 9 / 10)) ]; then
            c_warn "the budget is $(human "$total") but this host has $(human "$host_b") of RAM"
            c_info "leave headroom for the kernel, the host nginx and your own shell"
        fi
    fi

    # Redis: maxmemory caps the dataset, the container limit caps the process.
    # Equal values mean the kernel kills redis instead of redis evicting a key
    # — during BGSAVE the copy-on-write fork can approach the dataset size.
    rmax="$(to_bytes "$(cfg REDIS_MAXMEMORY 512mb)")"
    rlim="$(to_bytes "$(cfg REDIS_MEM_LIMIT 768m)")"
    if [ "$rmax" -ge "$rlim" ]; then
        die "REDIS_MAXMEMORY ($(human "$rmax")) is not below REDIS_MEM_LIMIT ($(human "$rlim"))." \
            "maxmemory caps the DATASET; the process also needs client buffers and" \
            "the copy-on-write fork during BGSAVE. At these values the kernel OOM-kills" \
            "redis instead of redis evicting a key. Use roughly 1.5x."
    elif [ "$rmax" -gt $((rlim * 3 / 4)) ]; then
        c_warn "REDIS_MAXMEMORY is over 75% of REDIS_MEM_LIMIT — thin margin for BGSAVE"
    fi

    # Storage sub-budgets.
    sbudget="$(to_bytes "$(cfg STACK_STORAGE_LIMIT 40g)")"
    stotal=0
    for key in PG_STORAGE_BUDGET STORAGE_STORAGE_BUDGET BACKUP_STORAGE_BUDGET REDIS_STORAGE_BUDGET; do
        stotal=$((stotal + $(to_bytes "$(cfg "$key" 0)")))
    done
    if [ "$stotal" -gt "$sbudget" ]; then
        die "the storage sub-budgets sum to $(human "$stotal"), over STACK_STORAGE_LIMIT=$(human "$sbudget")." \
            "Adjust one of PG_/STORAGE_/BACKUP_/REDIS_STORAGE_BUDGET, or raise the limit."
    fi
    c_ok "storage $(human "$stotal") of $(human "$sbudget") budgeted"

    # And the disk has to be able to hold it. df on the repo root, because
    # that is where the bind mounts live unless someone moved them.
    if avail_kb="$(df -Pk "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4; exit}')"; then
        used="$(tree_bytes "$REPO_ROOT/data")"
        used=$((used + $(tree_bytes "$(abs "$(cfg BACKUP_DIR ./backups)")")))
        avail=$((avail_kb * 1024))
        if [ $((avail + used)) -lt "$sbudget" ]; then
            c_warn "the filesystem can offer $(human $((avail + used))) but the budget is $(human "$sbudget")"
            c_info "the budget cannot be honoured here — see docs/operations.md"
        fi
    fi
fi

[ "$MODE" = "--budget-only" ] && exit 0

# ─── 2. bind-mount directories, with the owner AND mode each service needs ──
#
#  Four identities write into these trees and they are not the same uid:
#
#      postgres:18-alpine   uid 70     its own data directory
#      redis:8-alpine       uid 999    its own data directory
#      the app containers   uid 33     storage/, backups/
#      you                  $(id -u)   everything, from a shell
#
#  Docker creates a missing bind-mount source as root:root, and then postgres
#  exits with "could not change permissions of directory ... Permission denied"
#  and redis with "Can't open the append-only file: Permission denied", both in
#  a restart loop that looks like a broken image.
#
#  The MODE is checked as well as the owner, and they fail differently:
#  postgres REFUSES to start on a group-readable PGDATA, and the app tree needs
#  to stay group-writable or your own shell cannot touch what the container
#  wrote. An ownership-only check passes the exact state a manual chown leaves.
#
#  For the app trees the answer is uid 33 + YOUR group, setgid, group-writable.
#  `chown -R 33:33` makes the containers work and locks you out; handing it to
#  you breaks the containers. A shared group holds in both directions.
#
#  chown needs root, and it is only ever attempted with `sudo -n` —
#  passwordless, never prompting. A `make up` on a host without passwordless
#  sudo prints the exact command to run instead of hanging on a password
#  prompt nobody was watching for.
c_head "Host directories"

gid="$(cfg HOST_GID "$(id -g)")"
# "path:uid:gid:mode:label" — one row per line, split on WHITESPACE below, so
# no field may contain a space. A label of "app storage" splits into two rows
# and the second one chowns a directory named "storage" that does not exist.
targets="
$(abs "$(cfg DATA_PG_DIR ./data/postgres)"):70:70:0700:postgres
$(abs "$(cfg DATA_REDIS_DIR ./data/redis)"):999:999:0700:redis
$(abs "$(cfg DATA_STORAGE_DIR ./data/storage)"):33:$gid:g+rwXs:app-storage
$(abs "$(cfg BACKUP_DIR ./backups)"):33:$gid:g+rwXs:backups
"

fixed=0
manual=""
for row in $targets; do
    [ -n "$row" ] || continue
    path="${row%%:*}"; rest="${row#*:}"
    want_u="${rest%%:*}"; rest="${rest#*:}"
    want_g="${rest%%:*}"; rest="${rest#*:}"
    want_m="${rest%%:*}"; label="${rest#*:}"

    created=0
    if [ ! -d "$path" ]; then
        c_do "creating $path  ($label)"
        mkdir -p "$path" || die "cannot create $path"
        created=1
    fi

    have_u="$(stat -c '%u' "$path")"
    have_g="$(stat -c '%g' "$path")"
    have_m="$(stat -c '%a' "$path")"

    ok_owner=0
    [ "$have_u" = "$want_u" ] && [ "$have_g" = "$want_g" ] && ok_owner=1

    ok_mode=1
    case "$want_m" in
        0700) [ "$have_m" = "700" ] || ok_mode=0 ;;
        g+rwXs)
            # group-writable and setgid, so new files inherit the group and
            # both sides can keep writing.
            [ "$(( 8#$have_m & 8#2020 ))" = "$(( 8#2020 ))" ] || ok_mode=0 ;;
    esac

    if [ "$ok_owner" = 1 ] && [ "$ok_mode" = 1 ]; then
        [ "$created" = 1 ] || c_ok "$path"
        continue
    fi

    if sudo -n true 2>/dev/null; then
        c_do "fixing ownership of $path -> $want_u:$want_g ($label)"
        sudo chown -R "$want_u:$want_g" "$path"
        case "$want_m" in
            0700)   sudo chmod 0700 "$path" ;;
            g+rwXs) sudo chmod -R g+rwX "$path"
                    sudo find "$path" -type d -exec chmod g+s {} + ;;
        esac
        fixed=$((fixed + 1))
    else
        manual="${manual}
  sudo chown -R $want_u:$want_g $path"
        case "$want_m" in
            0700)   manual="${manual}
  sudo chmod 0700 $path" ;;
            g+rwXs) manual="${manual}
  sudo chmod -R g+rwX $path && sudo find $path -type d -exec chmod g+s {} +" ;;
        esac
    fi
done

if [ -n "$manual" ]; then
    die "these directories need an owner this user cannot set, and passwordless sudo is not available." \
        "Run these once, then re-run:${manual}"
fi
[ "$fixed" -gt 0 ] && c_ok "$fixed director$([ "$fixed" = 1 ] && echo y || echo ies) corrected"

# ─── 3. the application env file ────────────────────────────────────────────
#  Mounted read-only at /app/.env in every application container, so uid 33
#  must be able to READ it — and since it holds APP_KEY and both passwords,
#  nobody else should.
#
#  The obvious `chmod 640` as your own user does not work, and fails in a way
#  that is easy to misread: every app container restart-loops on
#  "sed: can't read /app/.env: Permission denied", because uid 33 inside the
#  container is not in your host group. The answer is the same one the data
#  directories use — owner 33, YOUR group, 0660:
#
#      uid 33   owner, read/write   the containers
#      gid you  group, read/write   your shell, so you can still edit it
#      others   nothing             it is a secrets file
#
#  This is re-applied on every run rather than once, because `sed -i` and most
#  editors REPLACE the file rather than writing through it: one edit hands
#  ownership back to you and the next restart breaks. Re-checking here is what
#  makes that self-healing instead of a puzzle.
want_mode=0660
app_u="$(stat -c '%u' "$APP_ENV")"; app_g="$(stat -c '%g' "$APP_ENV")"
app_mode="$(stat -c '%a' "$APP_ENV")"
if [ "$app_u" != "33" ] || [ "$app_g" != "$gid" ] || [ "$app_mode" != "660" ]; then
    if sudo -n true 2>/dev/null; then
        c_do "fixing $(basename "$APP_ENV") -> 33:$gid mode $want_mode"
        sudo chown "33:$gid" "$APP_ENV"
        sudo chmod "$want_mode" "$APP_ENV"
    elif [ "$app_u" = "$(id -u)" ]; then
        # No sudo, but it is yours: the mode is still fixable, and a
        # group-readable file with your group is enough when HOST_GID is a
        # group the container also has. Say plainly if it is not.
        chmod "$want_mode" "$APP_ENV" 2>/dev/null || true
        c_warn "$APP_ENV is owned by uid $app_u, not 33"
        c_info "the containers run as uid 33 and will restart-loop on 'can't read /app/.env':"
        c_info "  sudo chown 33:$gid $APP_ENV && sudo chmod 0660 $APP_ENV"
    else
        die "$APP_ENV is $app_u:$app_g mode $app_mode; the containers need 33:$gid mode 0660." \
            "  sudo chown 33:$gid $APP_ENV" \
            "  sudo chmod 0660 $APP_ENV"
    fi
else
    c_ok "$(basename "$APP_ENV")  33:$gid mode $app_mode"
fi

c_ok "host state ready"
