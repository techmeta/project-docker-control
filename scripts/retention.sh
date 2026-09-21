#!/usr/bin/env bash
# =============================================================================
#  Backup retention.        scripts/retention.sh [--dry-run]
# -----------------------------------------------------------------------------
#  THREE DIALS, NOT ONE, and the reason is a specific failure mode.
#
#  "Delete backups older than N days" is the obvious policy and it destroys
#  everything you have the first time the backup cron sits broken for N+1 days
#  — which is precisely the morning you need a backup. The age rule deletes on
#  a schedule; it has no idea whether anything replaced what it is deleting.
#
#  So an artifact is deleted only when BOTH are true:
#      • it is older than BACKUP_RETENTION_DAYS, and
#      • it is not among the newest BACKUP_RETENTION_MIN of its target
#
#  and on top of that:
#      • THE NEWEST ARTIFACT OF EACH TARGET IS NEVER DELETED. Not at any age,
#        not under disk pressure, not with --force. If the disk is full the
#        right outcome is a loud failure, not a stack with no way back.
#
#  The size ceiling (BACKUP_STORAGE_BUDGET) trims oldest-first when the tree
#  outgrows its budget, under the same protection. If it cannot get under
#  budget without breaking that rule, it says so and exits non-zero — the disk
#  guard escalates from there.
#
#  This script NEVER touches data/. It operates on the backups directory and
#  nothing else.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

assert_configured

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

BACKUPS="$(abs "$(cfg BACKUP_DIR ./backups)")"
DAYS="$(cfg BACKUP_RETENTION_DAYS 14)"
MIN="$(cfg BACKUP_RETENTION_MIN 7)"
BUDGET="$(to_bytes "$(cfg BACKUP_STORAGE_BUDGET 6g)")"

[ -d "$BACKUPS" ] || { c_warn "no backup directory at $BACKUPS"; exit 0; }

deleted=0
freed=0

# Remove an artifact and its sidecars as one unit. A .dump whose .sha256
# outlives it is a manifest for a file that does not exist, and `make
# backup-list` then reports a backup you do not have.
drop() {
    local f="$1" reason="$2" size
    size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    if [ "$DRY" = 1 ]; then
        printf '  %swould delete%s %s  (%s, %s)\n' "$C_YLW" "$C_OFF" \
            "$(basename "$f")" "$(human "$size")" "$reason"
    else
        rm -f "$f" "$f.sha256" "$f.json"
        c_info "deleted $(basename "$f")  ($(human "$size"), $reason)"
    fi
    deleted=$((deleted + 1))
    freed=$((freed + size))
}

# Artifacts of one target, newest first. `-printf '%T@ %p'` sorts by mtime
# numerically, which is right even when two artifacts share a second and the
# filename stamp does not disambiguate them.
list_target() {
    find "$BACKUPS" -maxdepth 1 -type f -name "$1-*" \
        ! -name '*.sha256' ! -name '*.json' ! -name '*.part' \
        -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-
}

c_head "Retention — keep $MIN newest per target, then delete past $DAYS days"

# ─── 1. age, with a floor ───────────────────────────────────────────────────
cutoff=$(( $(date +%s) - DAYS * 86400 ))
for target in db redis files config; do
    n=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        # The newest MIN survive regardless of age. n==1 is additionally
        # protected below, but the floor already covers it whenever MIN >= 1.
        [ "$n" -le "$MIN" ] && continue
        mtime="$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
        [ "$mtime" -lt "$cutoff" ] && drop "$f" "older than ${DAYS}d, #$n of $target"
    done < <(list_target "$target")
done

# ─── 2. the size ceiling ────────────────────────────────────────────────────
#  Oldest-first across ALL targets, still never taking the newest of any.
total="$(tree_bytes "$BACKUPS")"
if [ "$total" -gt "$BUDGET" ]; then
    c_warn "backups are $(human "$total"), over BACKUP_STORAGE_BUDGET=$(human "$BUDGET")"

    # The protected set: the newest artifact of each target.
    protected=""
    for target in db redis files config; do
        newest="$(list_target "$target" | head -n1)"
        [ -n "$newest" ] && protected="$protected$newest"$'\n'
    done

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$total" -gt "$BUDGET" ] || break
        case "$protected" in *"$f"$'\n'*) continue ;; esac
        size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
        drop "$f" "over budget"
        total=$((total - size))
    done < <(find "$BACKUPS" -maxdepth 1 -type f \
                ! -name '*.sha256' ! -name '*.json' ! -name '*.part' \
                -printf '%T@\t%p\n' 2>/dev/null | sort -n | cut -f2-)

    if [ "$total" -gt "$BUDGET" ]; then
        # Deliberately a failure. The only things left are the newest artifact
        # of each target, and deleting one of those to satisfy a disk budget
        # would trade a warning for having no way back.
        c_warn "still $(human "$total") after trimming — only the newest of each target remains"
        c_info "raise BACKUP_STORAGE_BUDGET, move older artifacts off-host (make backup-sync),"
        c_info "or exclude more from the files backup (BACKUP_FILES_EXCLUDE)"
        log_line FAIL "retention could not reach budget: $(human "$total") > $(human "$BUDGET")"
        notify fail "[$(cfg STACK_NAME otc)] backups over budget: $(human "$total") > $(human "$BUDGET")"
        exit 1
    fi
fi

# ─── 3. wreckage ────────────────────────────────────────────────────────────
#  .part files are interrupted backups. A day's grace so a running backup is
#  never swept out from under itself — the lock makes that nearly impossible
#  and "nearly" is not a basis for deleting someone's only good dump.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    drop "$f" "interrupted backup"
done < <(find "$BACKUPS" -maxdepth 1 -type f -name '*.part' -mtime +1 2>/dev/null)

# Sidecars whose artifact is gone.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f%.sha256}"; base="${base%.json}"
    [ -f "$base" ] || { [ "$DRY" = 1 ] && printf '  %swould delete%s %s (orphan)\n' "$C_YLW" "$C_OFF" "$(basename "$f")" || rm -f "$f"; }
done < <(find "$BACKUPS" -maxdepth 1 -type f \( -name '*.sha256' -o -name '*.json' \) 2>/dev/null)

final="$(tree_bytes "$BACKUPS")"
if [ "$deleted" -gt 0 ]; then
    c_ok "$deleted artifact(s) $([ "$DRY" = 1 ] && echo 'would be removed' || echo removed), $(human "$freed") $([ "$DRY" = 1 ] && echo 'would be freed' || echo freed)"
else
    c_ok "nothing to remove"
fi
c_ok "backups now $(human "$final") of $(human "$BUDGET")"
[ "$DRY" = 1 ] || log_line OK "retention: removed $deleted, freed $(human "$freed"), now $(human "$final")"
