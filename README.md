# OTC stack — docker control plane

Runs the published application package on a server. **Builds nothing.**

```
elsewhere:   build  →  push  →  ghcr.io/<owner>/<package>:sha-<short>
here:        make deploy      →  pull, restart, migrate, verify, or roll back
```

Six containers: `postgres`, `redis`, `octane`, `scheduler`, and two queue lanes.
A machine needs docker and nothing else. nginx is **not** here — it runs
natively on the host and proxies to the loopback port `octane` publishes.

---

## First run

```bash
make init                       # env files, directories, ownership
$EDITOR .env                    # APP_IMAGE, APP_TAG, HOST_GID
$EDITOR config/app.env          # APP_KEY, DB_PASSWORD, REDIS_PASSWORD
make login                      # private packages only
make deploy TAG=sha-1a79309
make cron-install               # nightly backups
make health
```

`make help` lists every command.

## Every day

| | |
|---|---|
| `make deploy TAG=…` | pull, restart, migrate, verify |
| `make rollback` | put the previous image back |
| `make health` | containers, postgres, redis, the app, backups, disk |
| `make logs` | follow everything |
| `make backup` | all four targets, now |
| `make restore TARGET=db CONFIRM=yes` | pick an artifact from a list |
| `make storage` | every tree against its budget |
| `make cron-status` | **when each backup job last actually succeeded** |

---

## Two env files, and compose reads both

`.env` configures **docker** — image, tag, ports, limits, paths, schedules.
`config/app.env` configures the **application** — `APP_KEY`, `DB_*`, `REDIS_*`.

Both are passed to compose, in that order:

```
docker compose --env-file .env --env-file config/app.env -f compose.yml …
```

That is what lets `postgres` be *created* with exactly the credentials the
application later logs in with. One secret, one file. Removing the second
`--env-file` breaks every command with an interpolation error on
`${DB_PASSWORD:?…}`; copying `DB_*` into `.env` to avoid that gives you two
copies of one secret, free to drift.

Neither file is committed. `config/app.env` is owned by uid 33 with your group,
mode 0660 — the containers run as uid 33 and cannot read a file owned by you,
and `make preflight` re-applies this on every run because editors *replace*
files rather than writing through them.

## Where the data lives

Every stateful path is a **bind mount** inside this repository:

```
data/postgres     the database          uid 70,  0700
data/redis        AOF + RDB             uid 999, 0700
data/storage      uploads, logs, cache  uid 33,  setgid, group-writable
backups/          artifacts             uid 33,  setgid, group-writable
```

`docker volume prune`, `docker system prune --volumes` and `make prune` all
operate on *volumes*. A bind mount is an ordinary host directory and is outside
their reach. `make prune` measures all four trees before and after and **fails
if any shrank** — measuring the two 0700 trees from inside their own containers,
because a plain `du` as your user reports zero for them and would make the proof
vacuous.

Point them at a mounted disk with an absolute path in `.env` if the root
filesystem is small.

## Backups

Four targets, taken from the host, written outside the containers:

| target | what | restores with |
|---|---|---|
| `db` | `pg_dump -Fc` of the whole database | `pg_restore` |
| `redis` | a live RDB pulled over the wire | stop, swap, rebuild AOF |
| `files` | the application storage tree | `tar -x` |
| `config` | `.env`, `config/app.env`, `compose.yml` | **by hand, on purpose** |

Every artifact is written `.part` and renamed (atomic), checksummed, and *read
back* — the dump's table of contents is listed, the RDB's magic is checked, the
tar is walked. A backup that has never been read is a hypothesis.

Schedules live in `.env` as `BACKUP_CRON_*`; `make cron-install` renders them
into your crontab between managed markers.

**Retention has three dials, not one.** "Delete backups older than N days"
destroys everything you have the first time the cron sits broken for N+1 days —
the exact morning you need one. An artifact is deleted only when it is older
than `BACKUP_RETENTION_DAYS` **and** is not among the newest
`BACKUP_RETENTION_MIN` of its target. **The newest artifact of each target is
never deleted, at any age, under any disk pressure.**

`make backup-sync` copies artifacts off the host. A backup on the same disk as
the database survives a bad migration and nothing else.

## Restoring

```bash
make backup-list
make restore TARGET=db CONFIRM=yes          # pick from a list
make restore TARGET=db LATEST=1 CONFIRM=yes # newest, no prompt
```

Every path verifies the checksum first, takes a **safety backup**, stops the
writers, and names what it did.

`db` **replaces** by default: it drops the public schema and restores into an
empty one. `MERGE=1` keeps objects the dump does not contain — right when rows
were deleted and the schema is fine, wrong after a bad migration, whose new
tables would otherwise survive a restore of the `migrations` table that does not
list them.

`redis` handles the trap that makes naive RDB restores silently do nothing: with
`appendonly yes`, redis loads the **AOF** and ignores `dump.rdb`. The old AOF is
moved aside (kept, not deleted), the snapshot is loaded with appendonly off, and
the AOF is rebuilt from it.

`config` never overwrites anything — it unpacks to a staging directory and
diffs. Overwriting a live `.env` changes credentials the datastores were
*created* with, and postgres does not re-read them on an existing cluster.

## Budgets

`STACK_MEM_LIMIT=4g` is enforced by `make preflight`, which adds the six
per-service limits and **refuses to start** if they exceed it. Docker has no
cross-service limit, so this is the only place the number is real; without it
the kernel enforces it by OOM-killing postgres mid-write.

`STACK_STORAGE_LIMIT=40g` is a **budget, not a wall**, and
`docs/operations.md` explains exactly why: docker cannot cap the size of a bind
mount on an ordinary overlay2/ext4 host. `scripts/disk-guard.sh` measures every
tree against its sub-budget on a cron, runs backup retention under pressure, and
alerts if it is still over. **It never deletes anything outside `backups/`.** A
full disk is an outage; deleting the database to avoid one is worse.

## Redis

The full production configuration is `config/redis/redis.conf`, mounted
read-only and reviewable in git, with per-host values passed as command-line
overrides. Two settings are load-bearing and commented as such:

- `appendonly yes` — database 0 holds queued jobs and the slow lane runs
  `--tries=1`, so a job lost in a restart is *gone*.
- `maxmemory-policy volatile-lru` — evicts only keys with a TTL. Queued jobs
  carry none; cache entries all do. Any `allkeys-*` policy starts deleting
  queued work when memory fills, silently.

---

## Documentation

- `docs/operations.md` — budgets, the storage cap, day-to-day runbooks
- `docs/disaster-recovery.md` — rebuilding this stack from nothing
