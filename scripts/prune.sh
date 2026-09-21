#!/usr/bin/env bash
# =============================================================================
#  Reclaim docker's disk — and PROVE the data survived.
# -----------------------------------------------------------------------------
#  The claim this repository makes is that `docker prune` cannot touch the
#  database, redis, the storage tree or the backups, because every one of them
#  is a bind mount and prune operates on volumes, images, containers and build
#  cache. The claim is worth nothing unless it is checked, so this measures all
#  four trees before and after and fails if any of them shrank.
#
#  The measurement is the hard part, not the prune. data/postgres is 0700 uid
#  70 and data/redis is 0700 uid 999, so `du` as an ordinary user reports zero
#  for both — before AND after, which "proves" nothing while looking exactly
#  like a pass. They are measured from inside their own containers instead.
#
#  NOT `-a`, and not `--volumes`:
#    -a         removes every image not currently in use — including the
#               PREVIOUS tag, which is the one `make rollback` needs.
#    --volumes  nothing here uses a named volume, so it would be a no-op today
#               and a data-loss bug the first time someone adds one.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

assert_configured
need docker

pg_dir="$(abs "$(cfg DATA_PG_DIR ./data/postgres)")"
redis_dir="$(abs "$(cfg DATA_REDIS_DIR ./data/redis)")"
storage_dir="$(abs "$(cfg DATA_STORAGE_DIR ./data/storage)")"
backup_dir="$(abs "$(cfg BACKUP_DIR ./backups)")"

rows=(
    "database|$pg_dir|postgres:/var/lib/postgresql/data"
    "redis|$redis_dir|redis:/data"
    "app storage|$storage_dir|"
    "backups|$backup_dir|"
)

measure() { if [ -n "$2" ]; then svc_tree_bytes "${2%%:*}" "${2#*:}" "$1"; else tree_bytes "$1"; fi; }

declare -A before
c_head "Before"
for row in "${rows[@]}"; do
    IFS='|' read -r label path via <<<"$row"
    before["$label"]="$(measure "$path" "$via")"
    printf '  %-14s %10s\n' "$label" "$(human "${before[$label]}")"
done

c_head "Pruning"
c_info "docker system prune -f   (no -a: it would delete the rollback image; no --volumes)"
docker system prune -f | tail -3 | sed 's/^/  /'

c_head "After"
rc=0
# A tolerance, because the containers are still running and still writing:
# a live log line makes a tree GROW, and a log rotation can make it shrink by
# a few KB. 1 MiB is comfortably above that and far below anything prune could
# plausibly have destroyed.
TOLERANCE=$((1024 * 1024))
for row in "${rows[@]}"; do
    IFS='|' read -r label path via <<<"$row"
    after="$(measure "$path" "$via")"
    delta=$(( after - ${before[$label]} ))
    if [ "$delta" -lt "-$TOLERANCE" ]; then
        printf '  %s✗ %-12s %10s   SHRANK by %s%s\n' "$C_RED" "$label" \
            "$(human "$after")" "$(human "${delta#-}")" "$C_OFF"
        rc=1
    else
        printf '  %s✓%s %-12s %10s%s\n' "$C_GRN" "$C_OFF" "$label" "$(human "$after")" \
            "$([ "$delta" -gt 0 ] && printf '   (+%s, still being written)' "$(human "$delta")")"
    fi
done

if [ "$rc" != 0 ]; then
    printf '\n'
    die "a data tree shrank during a prune." \
        "Nothing in this repository should be able to do that: every stateful path" \
        "is a bind mount, and prune only reaches volumes, images and build cache." \
        "" \
        "Look for a -v or --volumes on a \`down\` somewhere, and restore before" \
        "anything else:   make backup-list && make restore TARGET=db CONFIRM=yes"
fi

c_head "Data intact"
docker system df 2>/dev/null | sed 's/^/  /' || true
printf '\n'
log_line OK "prune: data intact"
