#!/usr/bin/env bash
# =============================================================================
#  Shared helpers. Sourced by every script in this directory; not executable.
# =============================================================================

# Every script resolves the repository root the same way, so `make backup` and
# a cron entry running the script by absolute path behave identically. Cron has
# no working directory worth the name, and half of what breaks in a backup cron
# breaks because the script assumed one.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/.env"
APP_ENV_DEFAULT="$REPO_ROOT/config/app.env"

# Colour only when attached to a terminal. A cron mail full of escape sequences
# is a cron mail nobody reads.
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_CYN=$'\033[36m'; C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
else
    C_RED=; C_GRN=; C_YLW=; C_CYN=; C_DIM=; C_OFF=
fi

c_ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
c_do()   { printf '  %s→%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
c_warn() { printf '  %s!%s %s\n' "$C_YLW" "$C_OFF" "$*" >&2; }
c_info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
c_head() { printf '\n%s%s%s\n' "$C_CYN" "$*" "$C_OFF"; }

die() {
    printf '\n%sFATAL%s  %s\n' "$C_RED" "$C_OFF" "$1" >&2
    shift
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
    printf '\n' >&2
    exit 1
}

# ── Reading env files ────────────────────────────────────────────────────────
# sed, not `source`. These files hold values that PHP parses happily and bash
# does not: unquoted #, spaces, backticks, ${VAR} back-references. Sourcing
# config/app.env has a decent chance of executing something.
env_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    sed -n "s/^[[:space:]]*${key}=//p" "$file" \
        | head -n1 \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" -e 's/[[:space:]]*$//' \
        | tr -d '\r'
}

# cfg KEY [DEFAULT] — a value from .env, or the default.
cfg() {
    local v; v="$(env_get "$ENV_FILE" "$1")"
    printf '%s' "${v:-${2-}}"
}

# app_cfg KEY [DEFAULT] — a value from the application env file.
app_cfg() {
    local f; f="$(cfg APP_ENV_FILE "$APP_ENV_DEFAULT")"
    case "$f" in /*) ;; *) f="$REPO_ROOT/${f#./}" ;; esac
    local v; v="$(env_get "$f" "$1")"
    printf '%s' "${v:-${2-}}"
}

app_env_path() {
    local f; f="$(cfg APP_ENV_FILE "$APP_ENV_DEFAULT")"
    case "$f" in /*) printf '%s' "$f" ;; *) printf '%s' "$REPO_ROOT/${f#./}" ;; esac
}

# abs PATH — resolve a possibly-relative .env path against the repo root, so an
# operator can point DATA_PG_DIR at /mnt/data and everything still works.
abs() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s/%s' "$REPO_ROOT" "${1#./}" ;;
    esac
}

# ── Compose ──────────────────────────────────────────────────────────────────
# TWO --env-file, in this order, and the order matters.
#
#   .env             configures DOCKER: image, ports, limits, paths.
#   config/app.env   configures the APPLICATION: APP_KEY, DB_*, REDIS_*.
#
# compose reads both for interpolation, which is what lets the postgres service
# be created with exactly the credentials the application later logs in with.
# Drop the second and `make up` fails on ${DB_PASSWORD:?...}; copy DB_* into
# .env to avoid it and you have two copies of one secret, free to drift.
dc() {
    docker compose --env-file "$ENV_FILE" --env-file "$(app_env_path)" \
        -f "$REPO_ROOT/compose.yml" "$@"
}

# Is a service's container running right now?
svc_running() {
    [ -n "$(dc ps -q "$1" 2>/dev/null)" ]
}

require_service() {
    svc_running "$1" || die "the '$1' container is not running." \
        "Start the stack first:  make up"
}

# ── Units ────────────────────────────────────────────────────────────────────
# "4g" / "512mb" / "40G" -> bytes. Accepts what both docker and humans write.
to_bytes() {
    local v="${1,,}" n unit
    v="${v// /}"
    [ -n "$v" ] || { printf '0'; return; }
    n="${v//[^0-9.]/}"
    unit="${v//[0-9.]/}"
    [ -n "$n" ] || { printf '0'; return; }
    case "$unit" in
        k|kb) awk -v n="$n" 'BEGIN{printf "%d", n*1024}' ;;
        m|mb) awk -v n="$n" 'BEGIN{printf "%d", n*1024*1024}' ;;
        g|gb) awk -v n="$n" 'BEGIN{printf "%d", n*1024*1024*1024}' ;;
        t|tb) awk -v n="$n" 'BEGIN{printf "%d", n*1024*1024*1024*1024}' ;;
        *)    awk -v n="$n" 'BEGIN{printf "%d", n}' ;;
    esac
}

human() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB PB", u, " "); i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
}

# Size of a tree, in bytes.
#
# `du -sk`, not `du -sb`: -b is GNU-only and the same helper has to work inside
# the alpine images, whose busybox du has no -b. -k is everywhere, and blocks
# are arguably the more honest number for a disk budget anyway.
#
# The `|| true` is load-bearing. du exits non-zero when it cannot descend into
# a subdirectory — PGDATA is 0700 — and under `set -o pipefail` that failure
# propagates, so the naive `du | awk || printf 0` emits BOTH the real number
# and a fallback 0, and the caller's arithmetic then dies on "0\n0".
tree_bytes() {
    local out
    [ -d "$1" ] || { printf '0'; return; }
    out="$(du -sk "$1" 2>/dev/null | awk 'NR==1{print $1}')" || true
    printf '%s' "$(( ${out:-0} * 1024 ))"
}

# A tree only root can read, measured from inside the container that owns it.
#
# data/postgres is 0700 uid 70 and data/redis is 0700 uid 999, so a plain `du`
# as your own user reports ZERO for both — which would quietly make the storage
# budget blind to the two things most worth watching, and make `make prune`'s
# "the data survived" proof vacuous: 0 before, 0 after, no shrink detected.
#
# Order: the running container (free, exact), then passwordless sudo, then the
# host reading what it can. The last case is reported as an underestimate by
# the caller rather than passed off as a measurement.
svc_tree_bytes() {   # <service> <path in container> <path on host>
    local svc="$1" cpath="$2" hpath="$3" out
    if svc_running "$svc"; then
        out="$(dc exec -T "$svc" du -sk "$cpath" 2>/dev/null | awk 'NR==1{print $1}')" || true
        [ -n "${out:-}" ] && { printf '%s' "$(( out * 1024 ))"; return; }
    fi
    if sudo -n true 2>/dev/null; then
        out="$(sudo -n du -sk "$hpath" 2>/dev/null | awk 'NR==1{print $1}')" || true
        [ -n "${out:-}" ] && { printf '%s' "$(( out * 1024 ))"; return; }
    fi
    tree_bytes "$hpath"
}

# ── Misc ─────────────────────────────────────────────────────────────────────
need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is not installed." "${2:-}"
}

stamp()     { date +%Y%m%d-%H%M%S; }
iso()       { date +%Y-%m-%dT%H:%M:%S%z; }

# Serialise anything that touches the datastores. Two backups on one database,
# or a backup racing a restore, is how an artifact ends up half written and
# passes every check until the day it is needed.
#
# A lock is NOT a timeout: a hung run holds it and every later cron run exits
# "already running", forever, quietly. That is why --wait is short and the
# caller reports the skip rather than swallowing it.
with_lock() {
    local name="$1"; shift
    local var="OTC_LOCK_${name^^}"

    # RE-ENTRANT within one process tree, and it has to be: restore.sh takes
    # this lock and then calls backup.sh for its safety copy. Without this the
    # child blocks on a lock its own parent holds — flock gives up after the
    # timeout, backup.sh returns "already running", and restore.sh correctly
    # refuses to continue without a way back. The restore that never happens
    # is the safe outcome, but it is not the right one.
    if [ -n "${!var:-}" ]; then "$@"; return; fi

    local lockfile="/tmp/otc-ctl-${name}.lock"
    exec {lock_fd}>"$lockfile" || die "cannot open lock file $lockfile"
    if ! flock -w 10 "$lock_fd"; then
        c_warn "another '$name' is already running (lock: $lockfile) — skipping"
        return 75   # EX_TEMPFAIL: a cron can tell this from a real failure
    fi
    export "$var=$$"
    "$@"
}

# BACKUP_NOTIFY_CMD ok|fail "message". Never allowed to fail the caller: a
# broken webhook must not turn a good backup into a failed one.
notify() {
    local status="$1" message="$2" cmd
    cmd="$(cfg BACKUP_NOTIFY_CMD)"
    [ -n "$cmd" ] || return 0
    "$cmd" "$status" "$message" >/dev/null 2>&1 \
        || c_warn "BACKUP_NOTIFY_CMD failed (the backup itself was $status)"
    return 0
}

# Append one line to the operations log. This is what `make cron-status` reads
# to answer the only question that matters about a backup cron: did it last
# actually succeed, and when.
LOG_FILE="$REPO_ROOT/backups/operations.log"
log_line() {
    local status="$1"; shift
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$(iso)" "$status" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# A preflight every script runs, so the failure names the missing file instead
# of surfacing as a compose interpolation error forty lines later.
assert_configured() {
    [ -f "$ENV_FILE" ] || die ".env does not exist." \
        "cp .env.example .env   # then edit APP_IMAGE, APP_TAG and the paths" \
        "or:  make init"
    local app; app="$(app_env_path)"
    [ -f "$app" ] || die "$app does not exist." \
        "cp config/app.env.example config/app.env   # then fill APP_KEY, DB_PASSWORD, REDIS_PASSWORD" \
        "or:  make init"
}
