# Operations

## The 40 GB is a budget, not a wall

Docker **cannot** cap the size of a bind mount, and every stateful path in this
stack is a bind mount, deliberately.

`storage_opt: size` — the setting people reach for — applies to a container's
*writable layer*, and only on devicemapper, or on overlay2 backed by XFS with
`pquota` enabled at mount time. On the ext4/overlay2 host you are almost
certainly running it is silently ignored or rejected. None of the data here is
in a writable layer anyway.

So `STACK_STORAGE_LIMIT` is enforced by measurement, on a cron:

```
make storage          # report every tree against its sub-budget
./scripts/disk-guard.sh --enforce    # what DISK_GUARD_CRON runs
```

At `STORAGE_WARN_PCT` it warns and runs backup retention. At 100% it runs
retention, re-measures, and alerts if still over. **It never deletes anything
outside `backups/`.** A full disk is an outage; deleting the database to avoid
an outage is a worse one that cannot be undone.

The two 0700 trees are measured from *inside* their own containers. A plain `du`
as your user reports zero for `data/postgres` and `data/redis`, which would make
the budget blind to the two things most worth watching — and would make
`make prune`'s survival proof vacuous, since zero before and zero after looks
exactly like a pass.

### If you want a real hard cap

Give the data its own filesystem, and point `.env` at it.

**LVM** — the straightforward option:

```bash
sudo lvcreate -L 40G -n otc-data vg0
sudo mkfs.ext4 /dev/vg0/otc-data
sudo mkdir -p /srv/otc-data
echo '/dev/vg0/otc-data /srv/otc-data ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo mount /srv/otc-data
```

Then in `.env`:

```
DATA_PG_DIR=/srv/otc-data/postgres
DATA_REDIS_DIR=/srv/otc-data/redis
DATA_STORAGE_DIR=/srv/otc-data/storage
BACKUP_DIR=/srv/otc-data/backups
```

`make preflight` creates them with the right owners. The cap is now the
filesystem's, enforced by the kernel: writes past it fail with ENOSPC, which
postgres handles by refusing writes rather than corrupting anything.

**XFS project quotas** — if the disk is already XFS, mounted with `pquota`:

```bash
sudo xfs_quota -x -c 'project -s -p /srv/otc-data 42' /srv
sudo xfs_quota -x -c 'limit -p bhard=40g 42' /srv
```

Either way, keep the budgets in `.env` in step with the real cap, so
`make storage` still tells you where the space went.

### A note on `stop-writes-on-bgsave-error`

`config/redis/redis.conf` sets it to `yes`. When a background save fails —
usually a full disk — redis **refuses writes** until it succeeds again. This
reads as harsh and is correct: the alternative is redis cheerfully accepting
writes it cannot persist, until a restart loses them. `make health` reports
`last RDB save` for exactly this reason, and the containers stay "healthy"
throughout, so nothing else will tell you.

---

## The RAM budget

`STACK_MEM_LIMIT` is not enforced by docker — docker has no notion of a limit
across services. `make preflight` adds the six per-service limits and refuses to
start if they exceed it:

```
memory  4.0 GB of 4.0 GB budgeted
```

Change one limit and you must change another, or the budget. That is the point:
raising a service's ceiling without deciding where the memory comes from is how
"we have a 4 GB budget" becomes a comment while the kernel enforces the real
number by OOM-killing postgres mid-write.

`REDIS_MAXMEMORY` must stay well below `REDIS_MEM_LIMIT` — preflight refuses if
it is not. `maxmemory` caps the *dataset*; the process also needs client
buffers and the copy-on-write fork during `BGSAVE`, which on a write-heavy
instance can briefly approach the dataset size again. Equal values mean the
kernel kills redis rather than redis evicting a key.

---

## Deploying

```bash
make deploy TAG=sha-1a79309
```

In order: preflight → **database backup** → pull → recreate → wait for health →
migrate → verify → record the tag.

The backup comes before the new image runs, and migrations run *after* the
containers are healthy. A migration that fails therefore has a dump taken
minutes earlier from a schema that matched the code that was running, and a
migration against a container that cannot boot never happens at all.

The deployed tag is written back into `.env` and recorded in `.deployed`; the
one it replaced goes to `.deployed.prev`.

### Rollback is not symmetric

```bash
make rollback
```

restores the previous **image**. It does not un-run a migration. If the deploy
that failed applied one, the old image may not understand the new schema, and
the way back is the dump the deploy took:

```bash
make backup-list
make restore TARGET=db CONFIRM=yes
```

### Floating tags are refused

`latest`, `main`, `master` and `stable` are rejected by both preflight and
deploy. A host running a floating tag cannot tell you what it is running, two
hosts pulling it can legitimately differ, and there is nothing to roll back to.

### ghcr.io

The owner and package must be **lowercase**, always, even when the GitHub
account is capitalised. A mixed-case path fails with a bare `denied`, which
reads like an authentication problem and sends people off to regenerate a
perfectly good token. Preflight checks this.

`make login` needs a *classic* PAT with the `read:packages` scope. Public
packages need no login.

---

## Backups

### What is actually guaranteed

- artifacts are written `.part` and renamed — a rename is atomic, so an
  interrupted backup never leaves a truncated file that looks complete
- every artifact is checksummed, and **read back**: the dump's table of contents
  is listed, the RDB's magic is checked, the tar is walked
- a lock serialises everything that touches the datastores, and is re-entrant
  within one process tree so a restore's safety backup is not blocked by the
  restore that called it
- the newest artifact of each target is never deleted

### What is not

- `files` excludes `framework/cache` and `framework/views` by default
  (`BACKUP_FILES_EXCLUDE`). They are regenerated on first request and can be
  larger than everything worth keeping — but a restore does not bring them back.
- `config` artifacts hold `APP_KEY`, `DB_PASSWORD`, `REDIS_PASSWORD` and the
  registry token **in the clear** unless `BACKUP_CONFIG_GPG_RECIPIENT` is set.
  They are written 0600. Think before syncing them anywhere.
- nothing is off-host until `BACKUP_SYNC_TARGET` is set.

### Checking that it works

```bash
make cron-status
```

This answers the question that matters — not "is a cron installed" but **when
did each job last actually succeed**. A cron that is installed and failing every
night is indistinguishable from a working one by every other means.

Set `BACKUP_NOTIFY_CMD`. It is called with `ok|fail` and a message. Without it a
failing backup is silent, and silence is how a broken backup goes unnoticed for
a month.

### Restoring redis: the trap

With `appendonly yes`, redis loads the **AOF** and ignores `dump.rdb`. Copying a
restored RDB into `data/redis` and restarting therefore appears to work and
restores nothing — the old dataset comes back from the AOF, and the only
evidence is a line in a log nobody reads.

`make restore TARGET=redis` handles it: stop, move the AOF directory aside
(*kept*, as `appendonlydir.pre-restore-<stamp>`), put the RDB in place, start
with `appendonly=no` so the snapshot is actually loaded, `CONFIG SET appendonly
yes` to rebuild the AOF from it, wait for the rewrite to finish, then recreate
the container on the declared configuration.

Delete the `.pre-restore-*` directories once you are satisfied.

---

## Routine

```bash
make health           # the whole picture
make storage          # budgets
make db-usage         # what the database is spending disk on
make db-reclaim       # recycle WAL, reclaim deleted rows (no locks)
make redis-info       # memory, persistence, keyspace
make redis-slowlog    # commands over 10ms
make prune            # reclaim docker's disk, prove the data survived
```

### `/up` returns 404 and everything looks fine

`ResolveTenant` is global middleware. With no tenant row matching the request's
`Host`, **every** route 404s, `/up` included, and octane's healthcheck fails on a
stack that is otherwise perfectly healthy. A fresh or freshly restored-empty
database looks broken when it is merely empty.

```bash
make artisan ARGS="tinker --execute='echo App\\Models\\Tenant::count();'"
```

### Changing DB_PASSWORD

`POSTGRES_PASSWORD` is read by the image's initdb **only when the data directory
is empty**. Editing `config/app.env` on an existing cluster changes what the
application sends and not what postgres expects, and the symptom is an
authentication failure against a file that looks correct.

```bash
make db-password      # applies it to the existing role
make restart          # so pooled connections pick it up
```

### `make down` never takes `-v`

The data is in bind mounts, so `-v` would not reach it today. It stays out
anyway, so that a named volume added later cannot become silently deletable by a
routine `make down`.
