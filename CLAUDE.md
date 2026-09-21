# Docker control plane for the OTC stack

**This repository runs a published package. It builds nothing.** There is no
Dockerfile and no `build:` key, deliberately — the image is built and reviewed
in the application repository, published to a registry, and pulled here by an
immutable tag. Do not add a build step "for convenience": a server that can
build is a server whose running code is not the code that was reviewed.

## Layout

- `compose.yml` — the whole stack, six containers
- `config/app.env` — the APPLICATION's environment (gitignored); `.env` is docker's
- `config/redis/redis.conf` — the full production redis config, mounted read-only
- `scripts/` — everything is a script; the Makefile only dispatches
- `data/`, `backups/` — bind mounts, gitignored. See "Data" below.
- `docs/operations.md`, `docs/disaster-recovery.md`

## Two `.env` files, and compose reads BOTH

```
docker compose --env-file .env --env-file config/app.env -f compose.yml …
```

Load-bearing. It is what lets `postgres` be *created* with exactly the `DB_*`
credentials the application later logs in with. Removing the second
`--env-file` breaks every command with an interpolation error on
`${DB_PASSWORD:?…}`; copying `DB_*` into `.env` to avoid that gives two copies
of one secret, free to drift. Do not "simplify" either of these.

`POSTGRES_*` are read by initdb **only when `data/postgres` is empty**. Changing
`DB_PASSWORD` later does not change the role's password — `make db-password`
does.

## Data

Every stateful path is a bind mount, never a named volume: `data/postgres`
(uid 70, 0700), `data/redis` (uid 999, 0700), `data/storage` (uid 33, setgid,
group-writable), `backups` (uid 33, setgid, group-writable).

That is a safety property: prune operates on volumes, and a bind mount is
outside its reach. `make prune` measures all four trees before and after and
fails if any shrank. **Never add `-v`/`--volumes` to a `down`**, and never
convert these to named volumes.

`config/app.env` is owned by **uid 33 with your group, mode 0660**. Not 0640 as
yourself: the containers run as uid 33 and are not in your host group, so they
restart-loop on `sed: can't read /app/.env: Permission denied`. `preflight.sh`
re-applies this every run because editors replace files rather than writing
through them.

## Traps worth knowing

- **`du` reports zero for `data/postgres` and `data/redis`** as an ordinary
  user — they are 0700. Use `svc_tree_bytes` (lib.sh), which measures from
  inside the owning container. A plain `du` makes the storage budget blind and
  `make prune`'s survival proof vacuous: zero before, zero after, "pass".
- **`pg_restore -l /dev/stdin` fails** on a valid dump — given a path it seeks,
  and a docker exec stdin is a pipe. Use bare `pg_restore -l` reading stdin.
- **A restored RDB does nothing while an AOF exists.** redis loads the AOF and
  ignores `dump.rdb`. `restore.sh` moves the AOF aside, boots with
  `appendonly=no`, then turns it back on to rebuild. A manual copy will not.
- **`--clean --if-exists` is a MERGE**, not a replace: it only drops what the
  dump contains. The default restore drops the public schema first; `MERGE=1`
  opts out.
- **`set -e` and `a && b && c=x` as the last command of a loop body** kills the
  script when `a` is false. This bit `cron.sh`'s status table. Use `if`.
- **`set -o pipefail` + a grep that finds nothing** in a command substitution
  kills the script. `|| true`.
- **Artifacts are written `.part`**, so any decompressor chosen by matching
  `*.zst` against the in-progress name silently falls through to `cat`. Keep
  `DECOMP_CMD` beside `COMP_CMD`.
- **The datastore lock is re-entrant within a process tree** (`OTC_LOCK_*`),
  because restore takes it and then calls backup for its safety copy.
- **`/up` returns 404 with an empty `tenants` table.** `ResolveTenant` is
  global middleware, so every route 404s and octane's healthcheck fails on a
  stack that is otherwise fine. Not a bug in this repository.

## Budgets

`STACK_MEM_LIMIT` is enforced by `preflight.sh`, which sums the six per-service
limits and refuses to start if they exceed it — docker has no cross-service
limit, so that assertion is the only place the number is real.

`STACK_STORAGE_LIMIT` is a **budget, not a wall**: docker cannot cap a bind
mount on overlay2/ext4. `disk-guard.sh` measures and escalates, and **never
deletes anything outside `backups/`**. See `docs/operations.md`.

Retention never deletes the newest artifact of a target, at any age, under any
disk pressure.

`make help` lists every operator command.
