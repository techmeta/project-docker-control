#!/usr/bin/env bash
# =============================================================================
#  Off-site copy.     scripts/sync.sh
# -----------------------------------------------------------------------------
#  A backup on the same disk as the database is not a backup. It survives a bad
#  migration, a dropped table and a fat-fingered DELETE — and nothing else. It
#  does not survive the disk, the filesystem, the VM, the hosting account, or
#  the person who runs `rm -rf` in the wrong directory.
#
#  BACKUP_SYNC_TARGET is empty by default, so this is a no-op until someone
#  decides where off-site is. It says so rather than exiting silently, because
#  a sync job that does nothing quietly is worse than no sync job at all.
#
#  MIRROR, NOT SYNC-AND-DELETE: rclone `copy`, not `sync`. Retention here must
#  not propagate to the remote — the remote is allowed to keep more history
#  than the local disk can afford, and that is usually the point. Set the
#  remote's own lifecycle rules there.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

assert_configured

TARGET="$(cfg BACKUP_SYNC_TARGET)"
TOOL="$(cfg BACKUP_SYNC_CMD rclone)"
BACKUPS="$(abs "$(cfg BACKUP_DIR ./backups)")"

if [ -z "$TARGET" ]; then
    c_warn "BACKUP_SYNC_TARGET is not set — nothing is copied off this host"
    c_info "a backup on the same disk as the database survives a bad migration and nothing else"
    c_info "  BACKUP_SYNC_TARGET=r2:otc-backups/prod        (rclone)"
    c_info "  BACKUP_SYNC_TARGET=backup@10.0.0.9:/srv/otc   (rsync, with BACKUP_SYNC_CMD=rsync)"
    exit 0
fi

c_head "Off-site copy to $TARGET"
started="$(date +%s)"

case "$TOOL" in
    rclone)
        need rclone "https://rclone.org/install/ — then: rclone config"
        # --immutable: an artifact that changed after it was written is a
        # problem worth stopping for, not something to overwrite quietly.
        rclone copy "$BACKUPS" "$TARGET" \
            --immutable \
            --exclude '*.part' \
            --exclude 'cron.log' \
            --exclude 'operations.log' \
            --transfers 4 --checkers 8 \
            --stats-one-line --stats 30s \
            || { log_line FAIL "sync to $TARGET"; notify fail "[$(cfg STACK_NAME otc)] off-site sync FAILED"; die "rclone failed"; }
        ;;
    rsync)
        need rsync
        rsync -az --partial \
            --exclude '*.part' --exclude 'cron.log' --exclude 'operations.log' \
            "$BACKUPS/" "$TARGET/" \
            || { log_line FAIL "sync to $TARGET"; notify fail "[$(cfg STACK_NAME otc)] off-site sync FAILED"; die "rsync failed"; }
        ;;
    *)
        die "BACKUP_SYNC_CMD=$TOOL is not one this script knows." "Use rclone or rsync."
        ;;
esac

took=$(( $(date +%s) - started ))
c_ok "copied in ${took}s"
log_line OK "sync to $TARGET in ${took}s"

# The config artifact carries APP_KEY and both passwords in the clear unless
# BACKUP_CONFIG_GPG_RECIPIENT is set. It has just been copied somewhere else.
if [ -z "$(cfg BACKUP_CONFIG_GPG_RECIPIENT)" ] && ls "$BACKUPS"/config-*.tar.gz >/dev/null 2>&1; then
    c_warn "unencrypted config artifacts were included — they hold APP_KEY and both passwords"
    c_info "set BACKUP_CONFIG_GPG_RECIPIENT in .env to encrypt them at backup time"
fi
