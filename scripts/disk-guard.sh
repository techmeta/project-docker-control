#!/usr/bin/env bash
# =============================================================================
#  Storage budget.     scripts/disk-guard.sh [--report|--enforce]
# -----------------------------------------------------------------------------
#  READ THIS BEFORE TRUSTING THE 40 GB.
#
#  Docker cannot cap the size of a bind mount. `storage_opt: size` applies to a
#  container's WRITABLE LAYER, and only on devicemapper or on overlay2 backed
#  by XFS with pquota — not on the ext4/overlay2 host you are almost certainly
#  running. Every stateful path in this stack is a bind mount, deliberately, so
#  none of it is inside any layer docker could limit. A hard cap needs a
#  filesystem: an LVM volume or an XFS project quota, both in docs/operations.md.
#
#  So STACK_STORAGE_LIMIT is a BUDGET, enforced here rather than by the kernel:
#
#    --report   measure every tree against its sub-budget and print it
#    --enforce  the same, plus: run backup retention at STORAGE_WARN_PCT,
#               and if still over at 100%, alert. Runs on a cron.
#
#  IT WILL NEVER DELETE ANYTHING OUTSIDE backups/. Not the database, not the
#  storage tree, not at 100%, not at 150%. A full disk is an outage; deleting
#  the data to avoid an outage is a worse outage that cannot be undone. The
#  guard is allowed to fail loudly and is not allowed to fix it.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

assert_configured

MODE="${1:---report}"
WARN_PCT="$(cfg STORAGE_WARN_PCT 80)"
TOTAL_BUDGET="$(to_bytes "$(cfg STACK_STORAGE_LIMIT 40g)")"

pg_dir="$(abs "$(cfg DATA_PG_DIR ./data/postgres)")"
redis_dir="$(abs "$(cfg DATA_REDIS_DIR ./data/redis)")"
storage_dir="$(abs "$(cfg DATA_STORAGE_DIR ./data/storage)")"
backup_dir="$(abs "$(cfg BACKUP_DIR ./backups)")"

# label | host path | budget | how to measure
# The two 0700 trees are measured through their own container; see
# svc_tree_bytes in lib.sh for why a plain du reports zero for them.
rows=(
    "database|$pg_dir|$(cfg PG_STORAGE_BUDGET 20g)|postgres:/var/lib/postgresql/data"
    "app storage|$storage_dir|$(cfg STORAGE_STORAGE_BUDGET 12g)|"
    "backups|$backup_dir|$(cfg BACKUP_STORAGE_BUDGET 6g)|"
    "redis|$redis_dir|$(cfg REDIS_STORAGE_BUDGET 2g)|redis:/data"
)

measure() {   # <host path> <svc:cpath or empty>
    if [ -n "$2" ]; then svc_tree_bytes "${2%%:*}" "${2#*:}" "$1"; else tree_bytes "$1"; fi
}

c_head "Storage — budget $(human "$TOTAL_BUDGET")"
printf '  %-14s %10s %10s %6s\n' "TREE" "USED" "BUDGET" ""

total_used=0
over_any=0
backups_over=0

for row in "${rows[@]}"; do
    IFS='|' read -r label path budget_h via <<<"$row"
    budget="$(to_bytes "$budget_h")"
    used="$(measure "$path" "$via")"
    total_used=$((total_used + used))

    pct=0
    [ "$budget" -gt 0 ] && pct=$(( used * 100 / budget ))

    mark="  "; colour="$C_GRN"
    if [ "$pct" -ge 100 ]; then
        mark="!!"; colour="$C_RED"; over_any=1
        [ "$label" = "backups" ] && backups_over=1
    elif [ "$pct" -ge "$WARN_PCT" ]; then
        mark=" !"; colour="$C_YLW"
        [ "$label" = "backups" ] && backups_over=1
    fi
    printf '  %-14s %10s %10s %s%4d%%%s %s\n' \
        "$label" "$(human "$used")" "$(human "$budget")" "$colour" "$pct" "$C_OFF" "$mark"
done

total_pct=0
[ "$TOTAL_BUDGET" -gt 0 ] && total_pct=$(( total_used * 100 / TOTAL_BUDGET ))
printf '  %-14s %10s %10s %4d%%\n' "TOTAL" "$(human "$total_used")" "$(human "$TOTAL_BUDGET")" "$total_pct"

# The filesystem's own view. A budget that fits is irrelevant if the disk under
# it is full for some other reason — and on a server, "some other reason" is
# usually /var/lib/docker, which is outside every budget above.
if df_line="$(df -Ph "$REPO_ROOT" 2>/dev/null | awk 'NR==2')"; then
    fs_pct="$(awk '{gsub(/%/,"",$5); print $5}' <<<"$df_line")"
    fs_avail="$(awk '{print $4}' <<<"$df_line")"
    printf '\n  filesystem %s used, %s available\n' "${fs_pct}%" "$fs_avail"
    if [ "${fs_pct:-0}" -ge 90 ]; then
        c_warn "the filesystem itself is ${fs_pct}% full — this is an outage in waiting"
        c_info "check /var/lib/docker too: docker system df"
        over_any=1
    fi
fi

# Container logs live under /var/lib/docker, outside every budget above, and
# are the other classic way a server fills up.
#
# The log files are root-owned, so stat'ing them usually fails for an ordinary
# user — and the whole block therefore ends `|| true`. Without it the failing
# xargs (which exits 123) takes the script down under `set -e`, and a storage
# REPORT that exits non-zero is read as "over budget" by the cron that calls it.
log_bytes=0
if command -v docker >/dev/null 2>&1; then
    log_bytes=$( { docker ps -q --filter "label=com.docker.compose.project=$(cfg STACK_NAME otc)" 2>/dev/null \
        | xargs -r -I{} docker inspect --format '{{.LogPath}}' {} 2>/dev/null \
        | xargs -r stat -c '%s' 2>/dev/null; } | awk '{s+=$1} END{print s+0}' ) || log_bytes=0
fi
if [ "${log_bytes:-0}" -gt 0 ]; then
    printf '  container logs %s (capped at %s x %s per service)\n' \
        "$(human "$log_bytes")" "$(cfg LOG_MAX_SIZE 10m)" "$(cfg LOG_MAX_FILE 3)"
fi

[ "$MODE" = "--report" ] && exit 0

# ─── enforce ────────────────────────────────────────────────────────────────
#  The only lever is backup retention. Everything else is reported and left
#  alone, on purpose.
if [ "$backups_over" = 1 ]; then
    c_head "Backups are at or past their budget — running retention"
    "$REPO_ROOT/scripts/retention.sh" || true
    after="$(tree_bytes "$backup_dir")"
    budget="$(to_bytes "$(cfg BACKUP_STORAGE_BUDGET 6g)")"
    if [ "$after" -gt "$budget" ]; then
        msg="backups still $(human "$after") over $(human "$budget") after retention"
        c_warn "$msg"
        log_line FAIL "disk-guard: $msg"
        notify fail "[$(cfg STACK_NAME otc)] $msg"
        exit 1
    fi
    # Recompute the total so the exit status reflects reality after trimming.
    total_used=0
    for row in "${rows[@]}"; do
        IFS='|' read -r _ path _ via <<<"$row"
        total_used=$((total_used + $(measure "$path" "$via")))
    done
fi

if [ "$total_used" -gt "$TOTAL_BUDGET" ] || [ "$over_any" = 1 ]; then
    msg="storage over budget: $(human "$total_used") of $(human "$TOTAL_BUDGET")"
    c_warn "$msg"
    c_info "nothing outside backups/ has been touched, and nothing will be"
    c_info "the levers are: a bigger disk, a bigger budget, or less retained"
    log_line FAIL "disk-guard: $msg"
    notify fail "[$(cfg STACK_NAME otc)] $msg"
    exit 1
fi

c_ok "within budget"
log_line OK "disk-guard: $(human "$total_used") of $(human "$TOTAL_BUDGET")"
