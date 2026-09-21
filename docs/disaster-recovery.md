# Disaster recovery

Rebuilding this stack on a machine that has nothing.

**What you need to have kept somewhere other than the dead host:**

| | |
|---|---|
| a `config-*.tar.gz` artifact | or `APP_KEY` and both passwords from a password manager |
| a `db-*.dump` artifact | the database |
| a `redis-*.rdb.*` artifact | optional — see below |
| a `files-*.tar.*` artifact | uploads and generated files |
| this repository | git |
| the image tag that was running | it is in `.deployed`, which is in the config artifact |

If `BACKUP_SYNC_TARGET` was never set, all of those were on the machine that
died. That is the failure this section cannot help with, and the reason
`make backup-sync` exists.

---

## 1. The host

Docker, and nothing else.

```bash
git clone <this repo> /srv/otc-control && cd /srv/otc-control
make init
```

## 2. Configuration

Unpack the config artifact somewhere private and copy from it:

```bash
mkdir -p /tmp/rec && chmod 700 /tmp/rec
tar -C /tmp/rec -xzf config-20260921-020000.tar.gz
cp /tmp/rec/.env .env
cp /tmp/rec/config/app.env config/app.env
```

Then **review `.env` before starting anything** — the paths, ports and
`HOST_GID` came from the dead machine:

- `HOST_GID` → `id -g` on *this* host
- `DATA_*` / `BACKUP_DIR` → wherever the disk is here
- `APP_TAG` → the tag that was running

`APP_KEY` must be the one the data was encrypted with. A new key leaves every
encrypted column unreadable, and nothing will tell you except the data looking
like noise.

```bash
rm -rf /tmp/rec
```

## 3. Start empty, then restore

```bash
make login            # private package
make preflight        # directories, ownership, budgets
make up               # postgres initdb runs here, creating an empty database
```

Wait for postgres and redis to report healthy. `octane` will be unhealthy —
`/up` 404s on an empty database, because `ResolveTenant` is global middleware
and no tenant row matches. That is expected at this point.

```bash
cp db-20260921-020000.dump backups/
cp files-20260921-020000.tar.zst backups/
make restore TARGET=db    FILE=db-20260921-020000.dump    CONFIRM=yes SKIP_SAFETY=1
make restore TARGET=files FILE=files-20260921-020000.tar.zst CONFIRM=yes SKIP_SAFETY=1
```

`SKIP_SAFETY=1` because there is nothing yet worth backing up, and the safety
backup would otherwise capture the empty database over your only good artifact
if retention is tight.

The db restore drops the public schema and restores into it. On a fresh cluster
that is a no-op followed by a normal restore.

## 4. Redis: usually skip it

Redis holds queues, sessions and cache. After a disaster:

- **cache** — regenerates
- **sessions** — everyone logs in again, which they are doing anyway
- **queued jobs** — the only thing worth recovering, and the snapshot is from
  up to 24h ago, so replaying it re-runs work that already completed *and*
  misses everything since

Restoring an old RDB is usually worse than starting empty. Restore it only if
you know the queue held something irreplaceable:

```bash
make restore TARGET=redis FILE=redis-20260921-020000.rdb.zst CONFIRM=yes
```

## 5. Verify, then reconnect

```bash
make health
```

Everything green, `/up` HTTP 200, and the tag in `image tag` matching what you
expect. Then point DNS or the load balancer at this host, install nginx, and:

```bash
make cron-install     # the backups do not exist until this is done
make backup           # prove the new host can take one
make backup-sync      # and that it reaches off-site
```

**`make cron-install` is the step people forget.** A recovered host with no
backup cron is one incident away from this document again, and nothing on the
host will mention it.

---

## Partial failures

### A bad migration

The dump `make deploy` took before migrating is the way back.

```bash
make backup-list                          # the newest db-* is the pre-deploy one
make restore TARGET=db CONFIRM=yes
make rollback                             # the image too, if the schema moved
```

### The image is fine, the data is wrong

Someone deleted rows. The schema is current.

```bash
make restore TARGET=db MERGE=1 CONFIRM=yes
```

`MERGE=1` lays the dump over the current database instead of replacing it,
keeping anything created since. Note that it does *not* delete rows that exist
now and not in the dump — a merge only adds and overwrites.

### The disk filled

```bash
make storage          # which tree, and by how much
make backup-prune     # trim backups to budget
make db-reclaim       # recycle WAL, reclaim deleted rows — no locks
```

If redis has stopped accepting writes, that is
`stop-writes-on-bgsave-error yes` doing its job: it could not save, so it
refuses to accept data it cannot persist. Free space, then:

```bash
make redis-info       # rdb_last_bgsave_status should return to ok
```

### The container host is fine, the data directory is not

Bind mounts mean the data is ordinary directories. Stop the stack, fix or
replace the filesystem, restore into it, start again. Nothing is hidden inside
docker.

```bash
make down             # never with -v
# … repair or remount …
make preflight        # recreates directories with the right owners and modes
make up
```
