#!/usr/bin/env bash
# =============================================================================
#  Backups — taken from the HOST, written outside the containers.
# -----------------------------------------------------------------------------
#      scripts/backup.sh [db|redis|files|config|all]      (default: all)
#
#  Nothing here runs inside the application. The scripts talk to postgres and
#  redis through `docker exec` and write to ./backups, a bind mount — so a
#  backup survives the container being removed, the image being re-pulled, and
#  `docker system prune --volumes`. An in-container backup tool that writes to
#  a container path produces artifacts that disappear with the container, which
#  is a backup system that reports success and holds nothing.
#
#  WHAT EACH TARGET TAKES
#    db      pg_dump -Fc of the whole database          restore: pg_restore
#    redis   a live RDB snapshot over the wire          restore: stop, swap, rewrite AOF
#    files   the application storage tree               restore: tar -x
#    config  .env, config/app.env, compose.yml          restore: by hand, on purpose
#
#  EVERY ARTIFACT IS WRITTEN .part AND RENAMED. A rename on one filesystem is
#  atomic, so an interrupted backup leaves a .part file that retention cleans
#  up — never a truncated .dump that looks complete and fails at 3am.
#
#  EVERY ARTIFACT IS VERIFIED (BACKUP_VERIFY=1): the checksum is recorded and
#  the file is actually read back — the dump's table of contents is listed, the
#  RDB's magic is checked, the tar is walked. A backup that has never been read
#  is a hypothesis.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

assert_configured
need docker
need flock "util-linux provides it; it is what stops two backups racing."

TARGET="${1:-$(cfg BACKUP_TARGETS all)}"
RETENTION_AFTER=1
[ "${2:-}" = "--no-retention" ] && RETENTION_AFTER=0
BACKUPS="$(abs "$(cfg BACKUP_DIR ./backups)")"
STAMP="$(stamp)"
VERIFY="$(cfg BACKUP_VERIFY 1)"
TIMEOUT="$(cfg BACKUP_TIMEOUT 3600)"

mkdir -p "$BACKUPS"

# ── Compression ──────────────────────────────────────────────────────────────
# zstd is roughly 3x faster than gzip at a better ratio, and is not installed
# everywhere. `auto` uses it when present and falls back silently, so an
# artifact taken on one host still restores on another — both extensions are
# handled by the restore script.
choose_compressor() {
    local want; want="$(cfg BACKUP_COMPRESSOR auto)"
    if [ "$want" = "auto" ] && command -v zstd >/dev/null 2>&1; then
        printf 'zstd'
    elif [ "$want" = "zstd" ]; then
        command -v zstd >/dev/null 2>&1 || die "BACKUP_COMPRESSOR=zstd but zstd is not installed."
        printf 'zstd'
    else
        printf 'gzip'
    fi
}
COMPRESSOR="$(choose_compressor)"
# DECOMP_CMD is kept beside COMP_CMD rather than derived from the filename at
# verification time, and that is not fussiness. Artifacts are written as
# "<name>.tar.zst.part" and renamed only once they are good — so a decompressor
# chosen by matching *.zst against the in-progress name matches nothing, falls
# through to cat, and hands compressed bytes to tar. The verification then
# reports "the archive lists no entries" for a perfectly good archive.
case "$COMPRESSOR" in
    zstd) COMP_CMD=(zstd -q -T0 -3 -c); DECOMP_CMD=(zstd -dc); COMP_EXT=zst ;;
    gzip) COMP_CMD=(gzip -6 -c);        DECOMP_CMD=(gzip -dc); COMP_EXT=gz  ;;
esac

# ── Bookkeeping around every artifact ────────────────────────────────────────
# A sidecar .json rather than a filename convention: the tag that produced the
# data is the single most useful thing to know during a restore, and it does
# not fit in a filename.
write_manifest() {
    local artifact="$1" target="$2" sum size
    size="$(stat -c '%s' "$artifact")"
    sum="$(sha256sum "$artifact" | awk '{print $1}')"
    printf '%s  %s\n' "$sum" "$(basename "$artifact")" > "$artifact.sha256"
    cat > "$artifact.json" <<JSON
{
  "target":      "$target",
  "file":        "$(basename "$artifact")",
  "created_at":  "$(iso)",
  "size_bytes":  $size,
  "sha256":      "$sum",
  "app_image":   "$(cfg APP_IMAGE)",
  "app_tag":     "$(cfg APP_TAG)",
  "pg_version":  "$(cfg POSTGRES_VERSION)",
  "redis_version": "$(cfg REDIS_VERSION)",
  "database":    "$(app_cfg DB_DATABASE)",
  "stack":       "$(cfg STACK_NAME otc)",
  "host":        "$(hostname -f 2>/dev/null || hostname)",
  "compressor":  "$COMPRESSOR"
}
JSON
    c_ok "$(basename "$artifact")  $(human "$size")"
}

# The rename that makes the whole thing safe. Also fsyncs the directory where
# possible: a rename recorded only in page cache is undone by a power cut,
# which is exactly the failure a backup exists for.
finalise() {
    local part="$1" final="$2"
    mv -f "$part" "$final"
    command -v sync >/dev/null 2>&1 && sync -f "$(dirname "$final")" 2>/dev/null || true
}

fail_target() {
    local target="$1" msg="$2"
    rm -f "$BACKUPS"/"$target"-"$STAMP".*.part 2>/dev/null || true
    log_line FAIL "backup $target: $msg"
    notify fail "[$(cfg STACK_NAME otc)] backup $target FAILED: $msg"
    die "backup of '$target' failed: $msg"
}

# ─────────────────────────────────────────────────────────────────────────────
#  db — pg_dump, custom format
# -----------------------------------------------------------------------------
#  -Fc, not plain SQL, and the difference matters at restore time: the custom
#  format is compressed, can be restored selectively (one table out of a
#  disaster), can restore in parallel, and carries a table of contents that
#  `pg_restore -l` reads — which is what makes verification possible at all.
#
#  -Z0 is NOT used: the format's own zlib compression is what makes the file
#  self-contained, so BACKUP_COMPRESSOR does not apply to this target.
#
#  --no-owner / --no-acl are NOT used here. The dump records them; the restore
#  decides whether to apply them. Discarding information at backup time is not
#  recoverable, discarding it at restore time is a flag.
# ─────────────────────────────────────────────────────────────────────────────
backup_db() {
    require_service postgres
    local db user part final
    db="$(app_cfg DB_DATABASE)"; user="$(app_cfg DB_USERNAME)"
    final="$BACKUPS/db-$STAMP.dump"; part="$final.part"

    c_do "pg_dump $db"
    # Spelled out rather than routed through dc(): `timeout` execs a binary
    # and cannot call a shell function, and a pg_dump that hangs on a lock
    # must not hold the backup lock until the next cron run gives up too.
    if ! timeout "$TIMEOUT" docker compose \
            --env-file "$ENV_FILE" --env-file "$(app_env_path)" \
            -f "$REPO_ROOT/compose.yml" exec -T postgres \
            pg_dump -U "$user" -d "$db" -Fc --no-password > "$part" 2>/tmp/otc-pgdump.err
    then
        c_warn "$(tail -3 /tmp/otc-pgdump.err 2>/dev/null)"
        fail_target db "pg_dump exited non-zero"
    fi
    [ -s "$part" ] || fail_target db "pg_dump produced an empty file"

    if [ "$VERIFY" = "1" ]; then
        # Read the dump back. `pg_restore -l` parses the header and the whole
        # table of contents, so a truncated or corrupt file fails here rather
        # than during the restore you are running because something is on fire.
        #
        # `pg_restore -l`, with NO path argument. Passing /dev/stdin instead
        # looks equivalent and is not: given a path, pg_restore opens and
        # SEEKS it, and a docker exec stdin is a pipe — so it fails with
        # "did not find magic string in file header" on a dump that is
        # perfectly valid. Reading bare stdin is sequential and works.
        local objects
        objects="$(dc exec -T postgres pg_restore -l < "$part" 2>/dev/null | grep -c '^[0-9]' || true)"
        [ "${objects:-0}" -gt 0 ] || fail_target db "the dump has no readable table of contents"
        c_info "verified: $objects objects in the table of contents"
    fi

    finalise "$part" "$final"
    write_manifest "$final" db
}

# ─────────────────────────────────────────────────────────────────────────────
#  redis — a snapshot pulled over the wire
# -----------------------------------------------------------------------------
#  `redis-cli --rdb` asks the server for a fresh snapshot over the replication
#  protocol. The obvious alternative — copying data/redis/dump.rdb from the
#  host — cannot work and fails in a way that is easy to miss: redis writes
#  that file 0600 as uid 999, so the copy either needs root or silently backs
#  up whatever stale snapshot happens to be on disk, which with `save 900 1`
#  can be fifteen minutes old, or hours old on a quiet instance.
# ─────────────────────────────────────────────────────────────────────────────
backup_redis() {
    require_service redis
    local cid part final tmp
    final="$BACKUPS/redis-$STAMP.rdb.$COMP_EXT"; part="$final.part"
    cid="$(dc ps -q redis)"
    tmp="$(mktemp -t otc-redis-XXXXXX.rdb)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    c_do "redis-cli --rdb"
    # REDISCLI_AUTH is already in the container's environment, so the password
    # never appears on a command line where `ps` would show it.
    if ! timeout "$TIMEOUT" docker exec "$cid" \
            sh -c 'redis-cli --no-auth-warning --rdb /tmp/otc-backup.rdb >/dev/null 2>&1'
    then
        docker exec "$cid" rm -f /tmp/otc-backup.rdb 2>/dev/null || true
        fail_target redis "redis-cli --rdb failed"
    fi
    docker cp "$cid:/tmp/otc-backup.rdb" "$tmp" >/dev/null \
        || fail_target redis "could not copy the snapshot out of the container"
    docker exec "$cid" rm -f /tmp/otc-backup.rdb 2>/dev/null || true
    [ -s "$tmp" ] || fail_target redis "the snapshot is empty"

    if [ "$VERIFY" = "1" ]; then
        # Every RDB starts with the five bytes REDIS followed by a version.
        local magic; magic="$(head -c 5 "$tmp")"
        [ "$magic" = "REDIS" ] || fail_target redis "the snapshot is not an RDB (magic: '$magic')"
        c_info "verified: RDB $(head -c 9 "$tmp" | tail -c 4)"
    fi

    "${COMP_CMD[@]}" < "$tmp" > "$part" || fail_target redis "compression failed"
    finalise "$part" "$final"
    write_manifest "$final" redis
}

# ─────────────────────────────────────────────────────────────────────────────
#  files — the application storage tree
# -----------------------------------------------------------------------------
#  Uploads, generated files, logs. BACKUP_FILES_EXCLUDE drops the regenerable
#  subtrees by default: the framework cache and compiled views are rebuilt on
#  first request and can be larger than everything worth keeping. Sessions live
#  in redis, so that directory is empty here.
#
#  Restoring a files backup does NOT restore what was excluded, which is the
#  intent — but it is worth knowing before a disaster rather than during one.
# ─────────────────────────────────────────────────────────────────────────────
backup_files() {
    local src part final excl_args=()
    src="$(abs "$(cfg DATA_STORAGE_DIR ./data/storage)")"
    [ -d "$src" ] || fail_target files "$src does not exist"
    final="$BACKUPS/files-$STAMP.tar.$COMP_EXT"; part="$final.part"

    local excludes; excludes="$(cfg BACKUP_FILES_EXCLUDE 'framework/cache framework/views')"
    for e in $excludes; do excl_args+=(--exclude="./$e"); done

    c_do "tar $src"
    # --ignore-failed-read: a log file rotated away mid-tar is not a reason to
    # fail the whole backup. -p and --numeric-owner keep uid 33 as uid 33 on a
    # host where no such user exists.
    if ! timeout "$TIMEOUT" tar -C "$src" -cf - \
            --numeric-owner -p --ignore-failed-read "${excl_args[@]}" . 2>/dev/null \
            | "${COMP_CMD[@]}" > "$part"
    then
        fail_target files "tar failed"
    fi
    [ -s "$part" ] || fail_target files "the archive is empty"

    if [ "$VERIFY" = "1" ]; then
        local entries
        entries="$("${DECOMP_CMD[@]}" < "$part" 2>/dev/null | tar -tf - 2>/dev/null | wc -l || true)"
        [ "${entries:-0}" -gt 0 ] || fail_target files "the archive lists no entries"
        c_info "verified: $entries entries"
    fi

    finalise "$part" "$final"
    write_manifest "$final" files
}

# ─────────────────────────────────────────────────────────────────────────────
#  config — the files that reproduce this stack
# -----------------------------------------------------------------------------
#  THIS ARTIFACT CONTAINS SECRETS: APP_KEY, DB_PASSWORD, REDIS_PASSWORD and the
#  registry token. It is written 0600 and it must not be synced to an untrusted
#  destination in the clear. Set BACKUP_CONFIG_GPG_RECIPIENT and it is
#  encrypted to that key instead.
#
#  It is also the artifact that makes the others useful: a database dump with
#  no APP_KEY restores a table of ciphertext nothing can read.
# ─────────────────────────────────────────────────────────────────────────────
backup_config() {
    local part final files=()
    final="$BACKUPS/config-$STAMP.tar.gz"; part="$final.part"

    for f in .env config/app.env compose.yml Makefile config/redis/redis.conf; do
        [ -e "$REPO_ROOT/$f" ] && files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || fail_target config "nothing to archive"

    c_do "tar ${#files[@]} configuration files"
    ( umask 077
      tar -C "$REPO_ROOT" -czf "$part" --numeric-owner -p "${files[@]}" 2>/dev/null ) \
        || fail_target config "tar failed"

    local recipient; recipient="$(cfg BACKUP_CONFIG_GPG_RECIPIENT)"
    if [ -n "$recipient" ]; then
        need gpg "BACKUP_CONFIG_GPG_RECIPIENT is set but gpg is not installed."
        c_do "encrypting to $recipient"
        gpg --batch --yes --trust-model always -r "$recipient" \
            --output "$part.gpg" --encrypt "$part" \
            || fail_target config "gpg encryption failed"
        rm -f "$part"; part="$part.gpg"; final="$final.gpg"
    fi

    chmod 0600 "$part"
    finalise "$part" "$final"
    chmod 0600 "$final"
    write_manifest "$final" config
    [ -n "$recipient" ] || c_warn "config-$STAMP.tar.gz holds APP_KEY and both passwords in the clear"
}

# ── Run ──────────────────────────────────────────────────────────────────────
run() {
    local -a wanted
    case "$TARGET" in
        all)    wanted=(db redis files config) ;;
        db|redis|files|config) wanted=("$TARGET") ;;
        *) die "unknown target '$TARGET'." "Use one of: db  redis  files  config  all" ;;
    esac

    c_head "Backup — $(printf '%s ' "${wanted[@]}")($STAMP)"
    local started; started="$(date +%s)"

    # Logged PER TARGET, not as one "backup db redis files config" line.
    # `make cron-status` answers "when did each job last succeed" by matching
    # "backup <target>" in this log, and a combined line matches only the
    # first of them — so config and files would read as "never run" forever
    # while succeeding nightly.
    for t in "${wanted[@]}"; do
        local t0; t0="$(date +%s)"
        "backup_$t"
        log_line OK "backup $t in $(( $(date +%s) - t0 ))s"
    done

    local took=$(( $(date +%s) - started ))
    notify ok "[$(cfg STACK_NAME otc)] backup ok: ${wanted[*]} in ${took}s"

    # Retention runs here as well as on its own cron, so a manual backup on a
    # nearly-full disk cannot be the thing that fills it.
    if [ "$RETENTION_AFTER" = 1 ]; then
        "$REPO_ROOT/scripts/retention.sh" || c_warn "retention reported a problem"
    fi

    c_head "Done in ${took}s"
}

with_lock datastore run
