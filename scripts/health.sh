#!/usr/bin/env bash
# =============================================================================
#  Health.     scripts/health.sh
# -----------------------------------------------------------------------------
#  What is actually true about this stack right now, in one screen. It checks
#  the things that fail quietly — a stack where every container is "Up" can
#  still be an outage:
#
#    • redis persisting?  a failed BGSAVE makes redis REFUSE WRITES, and the
#      containers stay healthy while every queued job errors
#    • redis memory?      at maxmemory it evicts, and what it evicts is cache,
#      until the policy is wrong and it evicts jobs
#    • backups recent?    an installed cron proves nothing
#    • tag drift?         .env says one thing, the running container another,
#      which happens whenever someone ran `docker compose up` by hand
#
#  Exit status is 0 only if nothing FAILED. Warnings do not fail it.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

assert_configured

fails=0
warns=0
ok()   { printf '  %s✓%s %-22s %s\n' "$C_GRN" "$C_OFF" "$1" "${2:-}"; }
bad()  { printf '  %s✗%s %-22s %s\n' "$C_RED" "$C_OFF" "$1" "${2:-}"; fails=$((fails + 1)); }
warn() { printf '  %s!%s %-22s %s\n' "$C_YLW" "$C_OFF" "$1" "${2:-}"; warns=$((warns + 1)); }

c_head "Containers"
for svc in postgres redis octane scheduler queue-important queue-default; do
    cid="$(dc ps -q "$svc" 2>/dev/null || true)"
    if [ -z "$cid" ]; then bad "$svc" "not running"; continue; fi
    state="$(docker inspect --format '{{.State.Status}}' "$cid")"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cid")"
    restarts="$(docker inspect --format '{{.RestartCount}}' "$cid")"
    detail="$state${health:+/$health}"
    [ "${restarts:-0}" -gt 0 ] && detail="$detail, $restarts restart(s)"
    case "$health" in
        healthy|-) [ "$state" = running ] && ok "$svc" "$detail" || bad "$svc" "$detail" ;;
        starting)  warn "$svc" "$detail" ;;
        *)         bad "$svc" "$detail" ;;
    esac
done

c_head "PostgreSQL"
if svc_running postgres; then
    db="$(app_cfg DB_DATABASE)"; user="$(app_cfg DB_USERNAME)"
    if dc exec -T postgres pg_isready -q -U "$user" -d "$db" 2>/dev/null; then
        size="$(dc exec -T postgres psql -U "$user" -d "$db" -tAc \
            "SELECT pg_size_pretty(pg_database_size('$db'))" 2>/dev/null | tr -d '\r' || true)"
        conns="$(dc exec -T postgres psql -U "$user" -d "$db" -tAc \
            "SELECT count(*) FROM pg_stat_activity WHERE datname='$db'" 2>/dev/null | tr -d '\r' || true)"
        maxc="$(cfg PG_MAX_CONNECTIONS 100)"
        ok "accepting connections" "$size, ${conns:-?}/$maxc connections"
        # Connection exhaustion is a cliff, not a slope: at max_connections the
        # next request fails outright, including the healthcheck.
        [ -n "$conns" ] && [ "$conns" -gt $((maxc * 80 / 100)) ] \
            && warn "connections" "$conns of $maxc — close to the limit"
    else
        bad "accepting connections" "pg_isready says no"
    fi
else
    bad "postgres" "not running"
fi

c_head "Redis"
if svc_running redis; then
    info="$(dc exec -T redis redis-cli info 2>/dev/null | tr -d '\r' || true)"
    field() { sed -n "s/^$1://p" <<<"$info" | head -n1; }

    used="$(field used_memory)"
    maxm="$(field maxmemory)"
    if [ -n "$used" ]; then
        if [ "${maxm:-0}" -gt 0 ]; then
            pct=$(( used * 100 / maxm ))
            if [ "$pct" -ge 95 ]; then warn "memory" "$(human "$used") of $(human "$maxm") (${pct}%) — evicting"
            else ok "memory" "$(human "$used") of $(human "$maxm") (${pct}%)"; fi
        else
            warn "memory" "$(human "$used"), no maxmemory set — this instance can grow until the kernel kills it"
        fi
    fi

    # The policy is load-bearing on a shared instance: anything allkeys-* can
    # evict queued jobs, which carry no TTL.
    policy="$(dc exec -T redis redis-cli config get maxmemory-policy 2>/dev/null | tr -d '\r' | tail -n1 || true)"
    case "$policy" in
        volatile-*|noeviction) ok "eviction policy" "$policy" ;;
        allkeys-*) bad "eviction policy" "$policy — this can evict QUEUED JOBS, which carry no TTL" ;;
        *) warn "eviction policy" "${policy:-unknown}" ;;
    esac

    # A failed background save makes redis reject writes (see redis.conf,
    # stop-writes-on-bgsave-error). The containers stay healthy throughout.
    [ "$(field rdb_last_bgsave_status)" = ok ] \
        && ok "last RDB save" "$(field rdb_last_bgsave_status)" \
        || bad "last RDB save" "$(field rdb_last_bgsave_status) — redis is refusing writes"

    if [ "$(field aof_enabled)" = 1 ]; then
        [ "$(field aof_last_write_status)" = ok ] \
            && ok "AOF" "enabled, last write ok" \
            || bad "AOF" "last write $(field aof_last_write_status)"
    else
        bad "AOF" "DISABLED — queued jobs are lost on restart (REDIS_APPENDONLY in .env)"
    fi

    # Only meaningful once the dataset is large enough for the allocator's own
    # overhead to be a small share of it. On a near-empty instance the ratio is
    # dominated by redis's fixed overhead and routinely reads above 10, which
    # is noise, not fragmentation.
    frag="$(field mem_fragmentation_ratio)"
    if [ -n "$frag" ] && [ "${used:-0}" -gt $((64 * 1024 * 1024)) ] \
       && awk -v f="$frag" 'BEGIN{exit !(f>1.5)}'; then
        warn "fragmentation" "$frag — consider activedefrag (config/redis/redis.conf)"
    fi
else
    bad "redis" "not running"
fi

c_head "Application"
if svc_running octane; then
    if dc exec -T octane curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8050/up >/tmp/otc-up 2>/dev/null; then
        ok "octane /up" "HTTP $(cat /tmp/otc-up)"
    else
        bad "octane /up" "no answer from inside the container"
    fi

    # Tag drift: .env is the record of what should be running. A container
    # started by hand, or a deploy that failed halfway, breaks that.
    want="$(cfg APP_TAG)"
    running="$(docker inspect --format '{{.Config.Image}}' "$(dc ps -q octane)" 2>/dev/null || true)"
    if [ "${running##*:}" = "$want" ]; then
        ok "image tag" "$want"
    else
        warn "image tag" ".env says $want, the container runs ${running##*:}"
    fi
else
    bad "octane" "not running"
fi

edge="$(cfg HEALTH_EDGE_URL)"
if [ -n "$edge" ]; then
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "$edge" 2>/dev/null || echo 000)"
    [ "$code" = 200 ] && ok "edge (nginx)" "$edge -> $code" || bad "edge (nginx)" "$edge -> $code"
fi

c_head "Backups"
BACKUPS="$(abs "$(cfg BACKUP_DIR ./backups)")"
now="$(date +%s)"
for t in db redis files config; do
    newest="$(find "$BACKUPS" -maxdepth 1 -type f -name "$t-*" \
        ! -name '*.sha256' ! -name '*.json' ! -name '*.part' \
        -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2- || true)"
    if [ -z "$newest" ]; then
        warn "$t" "no backup has ever been taken"
        continue
    fi
    age_h=$(( (now - $(stat -c '%Y' "$newest")) / 3600 ))
    size="$(human "$(stat -c '%s' "$newest")")"
    # files runs weekly by default; the others daily.
    limit=48; [ "$t" = files ] && limit=192
    if [ "$age_h" -gt "$limit" ]; then
        warn "$t" "${age_h}h old, $size — older than the schedule implies"
    else
        ok "$t" "${age_h}h old, $size"
    fi
done

"$REPO_ROOT/scripts/disk-guard.sh" --report | tail -n +2

printf '\n'
if [ "$fails" -gt 0 ]; then
    printf '  %s%d check(s) FAILED%s, %d warning(s)\n\n' "$C_RED" "$fails" "$C_OFF" "$warns"
    exit 1
fi
printf '  %shealthy%s, %d warning(s)\n\n' "$C_GRN" "$C_OFF" "$warns"
