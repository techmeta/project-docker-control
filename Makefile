# =============================================================================
#  OTC stack — docker control plane
# -----------------------------------------------------------------------------
#  This repository RUNS a published package. It builds nothing: there is no
#  `build` target and no Dockerfile, deliberately. The image is built and
#  reviewed elsewhere, published to a registry, and pulled here by an immutable
#  tag.
#
#      make login        authenticate to the registry (private packages only)
#      make init         first-time setup on a new host
#      make deploy       pull the tag, restart, migrate, verify
#      make rollback     put the previous image back
#
#  Six containers: postgres, redis, octane, scheduler and two queue lanes.
#  nginx is NOT here — it runs natively on the host and proxies to the loopback
#  port octane publishes.
#
#  TWO --env-file, and the order matters. See COMPOSE_ENV below.
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# The application env file, as .env names it. Read here rather than hardcoded
# so a host that keeps secrets outside the checkout only edits one line.
APP_ENV_FILE := $(shell sed -n 's/^APP_ENV_FILE=//p' .env 2>/dev/null | head -1)
APP_ENV_FILE := $(if $(APP_ENV_FILE),$(APP_ENV_FILE),./config/app.env)

# TWO --env-file, in this order, and the order matters.
#
#   .env             configures DOCKER: image, tag, ports, limits, paths.
#   config/app.env   configures the APPLICATION: APP_KEY, DB_*, REDIS_*.
#
# compose reads both for interpolation, which is what lets the postgres service
# be CREATED with exactly the credentials the application later logs in with.
# One secret, one file.
#
# Removing the second --env-file breaks every target here with an
# interpolation error on $${DB_PASSWORD:?...}. Copying DB_* into .env to avoid
# that gives you two copies of one secret, free to drift — and a drift between
# them presents as an authentication failure against a file that looks correct.
# Do not "simplify" this.
COMPOSE_ENV := --env-file .env --env-file $(APP_ENV_FILE)
COMPOSE     := docker compose $(COMPOSE_ENV) -f compose.yml

APP      := octane
SERVICES := postgres redis octane scheduler queue-important queue-default
APP_SVCS := octane scheduler queue-important queue-default
QUEUES   := queue-important queue-default

# Read from .env so nothing here is hardcoded to one deployment.
STACK       := $(shell sed -n 's/^STACK_NAME=//p' .env 2>/dev/null | head -1)
STACK       := $(if $(STACK),$(STACK),otc)
APP_IMAGE   := $(shell sed -n 's/^APP_IMAGE=//p' .env 2>/dev/null | head -1)
APP_TAG     := $(shell sed -n 's/^APP_TAG=//p' .env 2>/dev/null | head -1)
REGISTRY    := $(shell sed -n 's/^REGISTRY=//p' .env 2>/dev/null | head -1)
REGISTRY    := $(if $(REGISTRY),$(REGISTRY),ghcr.io)
BACKUP_DIR  := $(shell sed -n 's/^BACKUP_DIR=//p' .env 2>/dev/null | head -1)
BACKUP_DIR  := $(if $(BACKUP_DIR),$(BACKUP_DIR),./backups)
DB_NAME     := $(shell sed -n 's/^DB_DATABASE=//p' $(APP_ENV_FILE) 2>/dev/null | head -1)
DB_USER     := $(shell sed -n 's/^DB_USERNAME=//p' $(APP_ENV_FILE) 2>/dev/null | head -1)

# How to run a one-off artisan command. `exec` into the running container when
# the stack is up, a throwaway container otherwise — and evaluated per-recipe
# (=, not :=) so it reflects what is running NOW rather than at parse time.
#
# The throwaway form carries --no-deps, so `make artisan` on a stopped stack
# does not quietly start postgres and redis as a side effect.
ARTISAN = $(shell $(COMPOSE) ps -q octane 2>/dev/null | grep -q . \
            && echo "$(COMPOSE) exec -T octane php artisan" \
            || echo "$(COMPOSE) run --rm --no-deps octane php artisan")

.PHONY: help init preflight up down stop restart status ps logs logs-octane \
        logs-queue logs-scheduler logs-postgres logs-redis login pull deploy \
        rollback image-info artisan migrate migrate-status tinker shell \
        cache-clear cache-warm queue-restart queue-failed queue-retry \
        db-shell db-usage db-reclaim db-password redis-shell redis-info \
        redis-slowlog backup backup-list backup-verify backup-prune \
        backup-sync restore cron-install cron-uninstall cron-status cron-show \
        health storage doctor prune version

# ─────────────────────────────────────────────────────────────────────────────
help: ## Show this help
	@printf '\n  \033[36m%s\033[0m — docker control plane\n' "$(STACK)"
	@printf '  \033[2mimage: %s:%s\033[0m\n\n' "$(APP_IMAGE)" "$(APP_TAG)"
	@awk 'BEGIN {FS = ":.*##"} \
		/^# ── / { sub(/^# ── /, ""); sub(/ ─*$$/, ""); printf "\n  \033[1m%s\033[0m\n", $$0 } \
		/^[a-zA-Z0-9_-]+:.*?##/ { printf "    \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\n  \033[2mMost flags are in .env; most secrets are in %s\033[0m\n\n' "$(APP_ENV_FILE)"

# ── Setup ───────────────────────────────────────────────────────────────────

init: ## First-time setup on a new host: env files, directories, ownership
	@if [ ! -f .env ]; then cp .env.example .env; \
		printf '  \033[32m✓\033[0m created .env — set APP_IMAGE, APP_TAG and HOST_GID (%s)\n' "$$(id -g)"; \
	else printf '  \033[32m✓\033[0m .env exists\n'; fi
	@if [ ! -f $(APP_ENV_FILE) ]; then cp config/app.env.example $(APP_ENV_FILE); chmod 0640 $(APP_ENV_FILE); \
		printf '  \033[32m✓\033[0m created %s — set APP_KEY, DB_PASSWORD, REDIS_PASSWORD\n' "$(APP_ENV_FILE)"; \
	else printf '  \033[32m✓\033[0m %s exists\n' "$(APP_ENV_FILE)"; fi
	@./scripts/preflight.sh --dirs-only
	@printf '\n  Next:\n    1. edit .env               (APP_IMAGE, APP_TAG, HOST_GID)\n    2. edit %s   (APP_KEY, DB_PASSWORD, REDIS_PASSWORD)\n    3. make login              (private packages only)\n    4. make deploy TAG=sha-…\n\n' "$(APP_ENV_FILE)"

preflight: ## Check env, directories, ownership and the resource budget
	@./scripts/preflight.sh

# ── Lifecycle ───────────────────────────────────────────────────────────────

up: preflight ## Start the stack (pulls the tag in .env if it is not local)
	@$(COMPOSE) up -d --remove-orphans
	@printf '\n  Waiting for health…\n'
	@$(COMPOSE) ps

down: ## Stop and remove the containers. Data and .env are untouched
	@# NEVER add -v/--volumes here. The data is in bind mounts so -v would not
	@# reach it today, and a named volume added later must not become
	@# silently deletable by a routine `make down`.
	@$(COMPOSE) down --remove-orphans

stop: ## Stop the containers without removing them
	@$(COMPOSE) stop

restart: ## Restart the application containers (not the datastores)
	@$(COMPOSE) restart $(APP_SVCS)

status: ps ## Alias for ps
ps: ## Show container status
	@$(COMPOSE) ps

logs: ## Follow logs from every service
	@$(COMPOSE) logs -f --tail=100
logs-octane: ## Follow the HTTP server's logs
	@$(COMPOSE) logs -f --tail=100 octane
logs-queue: ## Follow both queue lanes
	@$(COMPOSE) logs -f --tail=100 $(QUEUES)
logs-scheduler: ## Follow the scheduler's logs
	@$(COMPOSE) logs -f --tail=100 scheduler
logs-postgres: ## Follow the database's logs
	@$(COMPOSE) logs -f --tail=100 postgres
logs-redis: ## Follow redis's logs
	@$(COMPOSE) logs -f --tail=100 redis

# ── The package ─────────────────────────────────────────────────────────────

login: ## Log in to the registry. Needs REGISTRY_USERNAME + REGISTRY_TOKEN
	@set -euo pipefail; \
	user=$$(sed -n 's/^REGISTRY_USERNAME=//p' .env | head -1); \
	token=$${REGISTRY_TOKEN:-$$(sed -n 's/^REGISTRY_TOKEN=//p' .env | head -1)}; \
	if [ -z "$$user" ] || [ -z "$$token" ]; then \
		printf '\n\033[31mFATAL\033[0m  REGISTRY_USERNAME or REGISTRY_TOKEN is empty.\n'; \
		printf '       ghcr.io wants a classic PAT with the read:packages scope.\n'; \
		printf '       A public package needs no login at all.\n\n'; exit 1; fi; \
	printf '%s' "$$token" | docker login $(REGISTRY) -u "$$user" --password-stdin
	@printf '  \033[32m✓\033[0m logged in to $(REGISTRY)\n'

pull: ## Pull the tag in .env without restarting anything
	@set -euo pipefail; \
	printf '  \033[36m→\033[0m docker pull $(APP_IMAGE):$(APP_TAG)\n'; \
	docker pull $(APP_IMAGE):$(APP_TAG); \
	docker image inspect --format '  \033[32m✓\033[0m {{index .RepoDigests 0}}' $(APP_IMAGE):$(APP_TAG) 2>/dev/null || true

deploy: ## Pull, restart, migrate and verify.  TAG=sha-1a79309
	@./scripts/deploy.sh $(TAG)

rollback: ## Put the previously deployed image back (does NOT undo migrations)
	@./scripts/deploy.sh --rollback

image-info: ## What is running, what .env says, and the digest of each
	@set -euo pipefail; \
	printf '\n  .env      %s:%s\n' "$(APP_IMAGE)" "$(APP_TAG)"; \
	printf '  deployed  %s\n' "$$(cat .deployed 2>/dev/null || echo '—')"; \
	printf '  previous  %s   (make rollback)\n' "$$(cat .deployed.prev 2>/dev/null || echo '—')"; \
	cid=$$($(COMPOSE) ps -q octane 2>/dev/null || true); \
	if [ -n "$$cid" ]; then \
		printf '  running   %s\n' "$$(docker inspect --format '{{.Config.Image}}' $$cid)"; \
		printf '  digest    %s\n' "$$(docker inspect --format '{{index .Image}}' $$cid)"; \
		printf '  started   %s\n' "$$(docker inspect --format '{{.State.StartedAt}}' $$cid)"; \
	else printf '  running   — (nothing up)\n'; fi; \
	printf '  size      %s\n\n' "$$(docker image inspect --format '{{.Size}}' $(APP_IMAGE):$(APP_TAG) 2>/dev/null | numfmt --to=iec 2>/dev/null || echo '—')"

# ── Application ─────────────────────────────────────────────────────────────

artisan: ## Run an artisan command.  ARGS="route:list"
	@$(ARTISAN) $(ARGS)

migrate: ## Run pending migrations
	@$(ARTISAN) migrate --force

migrate-status: ## Show migration status
	@$(ARTISAN) migrate:status

tinker: ## Open a tinker shell
	@$(COMPOSE) exec $(APP) php artisan tinker

shell: ## Open a shell inside the running application container
	@$(COMPOSE) exec $(APP) bash

cache-clear: ## Clear compiled config, routes, events and views
	@$(ARTISAN) optimize:clear

cache-warm: ## Compile config, routes and events
	@$(ARTISAN) optimize

queue-restart: ## Tell the workers to finish the current job and exit
	@$(ARTISAN) queue:restart
	@printf '  \033[32m✓\033[0m workers will exit after the current job; the restart policy brings them back\n'

queue-failed: ## List failed jobs
	@$(ARTISAN) queue:failed

queue-retry: ## Retry failed jobs.  ID=all  or  ID=<uuid>
	@$(ARTISAN) queue:retry $(or $(ID),all)

# ── Data ────────────────────────────────────────────────────────────────────

db-shell: ## Open a psql shell as the application's role
	@$(COMPOSE) exec postgres psql -U $(DB_USER) -d $(DB_NAME)

db-usage: ## What the database is spending disk on
	@$(COMPOSE) exec -T postgres psql -U $(DB_USER) -d $(DB_NAME) -c "\
		SELECT relname AS table, \
		       pg_size_pretty(pg_total_relation_size(c.oid)) AS total, \
		       pg_size_pretty(pg_relation_size(c.oid))       AS data, \
		       pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid)) AS indexes, \
		       n_live_tup AS rows \
		  FROM pg_class c \
		  JOIN pg_namespace n ON n.oid = c.relnamespace \
		  LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid \
		 WHERE n.nspname = 'public' AND c.relkind = 'r' \
		 ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 20;"

db-reclaim: ## Give disk back now: recycle WAL and reclaim deleted rows
	@printf '  \033[36m→\033[0m VACUUM (ANALYZE) — this does NOT lock the tables\n'
	@$(COMPOSE) exec -T postgres psql -U $(DB_USER) -d $(DB_NAME) -c 'VACUUM (ANALYZE, VERBOSE);' 2>&1 | tail -5
	@$(COMPOSE) exec -T postgres psql -U $(DB_USER) -d $(DB_NAME) -c 'CHECKPOINT;'
	@printf '  \033[2mVACUUM FULL would return more, and needs an exclusive lock and 2x the disk.\033[0m\n'

db-password: ## Apply DB_PASSWORD from the app env to an EXISTING cluster
	@# initdb reads POSTGRES_PASSWORD only when the data directory is empty, so
	@# editing the env file does not change the role on a cluster that already
	@# exists. Without this the app fails to authenticate against a file that
	@# looks correct — one of the hardest failures in this stack to see.
	@set -euo pipefail; \
	pw=$$(sed -n 's/^DB_PASSWORD=//p' $(APP_ENV_FILE) | head -1); \
	[ -n "$$pw" ] || { printf '\n\033[31mFATAL\033[0m  DB_PASSWORD is empty in %s\n\n' "$(APP_ENV_FILE)"; exit 1; }; \
	$(COMPOSE) exec -T postgres psql -U $(DB_USER) -d $(DB_NAME) -v pw="$$pw" \
		-c "ALTER ROLE $(DB_USER) WITH PASSWORD :'pw';"; \
	printf '  \033[32m✓\033[0m role %s now matches %s\n' "$(DB_USER)" "$(APP_ENV_FILE)"; \
	printf '  \033[2mRestart the app so pooled connections pick it up: make restart\033[0m\n'

redis-shell: ## Open a redis-cli shell (authenticated from the app env)
	@$(COMPOSE) exec redis redis-cli

redis-info: ## Memory, persistence and keyspace at a glance
	@$(COMPOSE) exec -T redis redis-cli info memory     | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'
	@$(COMPOSE) exec -T redis redis-cli info persistence | grep -E 'aof_enabled|aof_last_write_status|rdb_last_bgsave_status|rdb_changes_since_last_save'
	@$(COMPOSE) exec -T redis redis-cli info keyspace
	@$(COMPOSE) exec -T redis redis-cli config get maxmemory-policy

redis-slowlog: ## Commands that took over 10ms
	@$(COMPOSE) exec -T redis redis-cli slowlog get 25

# ── Backup and restore ──────────────────────────────────────────────────────

backup: ## Back up.  TARGET=db|redis|files|config|all  (default: all)
	@./scripts/backup.sh $(or $(TARGET),all)

backup-list: ## List artifacts with sizes, ages and the tag they came from
	@set -euo pipefail; \
	printf '\n  %-40s %9s %-17s %s\n' "ARTIFACT" "SIZE" "TAKEN" "FROM TAG"; \
	found=0; \
	while IFS= read -r f; do \
		[ -n "$$f" ] || continue; found=1; \
		tag=$$(sed -n 's/.*"app_tag": *"\([^"]*\)".*/\1/p' "$$f.json" 2>/dev/null || echo '—'); \
		printf '  %-40s %9s %-17s %s\n' "$$(basename $$f)" \
		^^"$$(numfmt --to=iec < <(stat -c '%s' $$f))" \
		^^"$$(date -d @$$(stat -c '%Y' $$f) '+%Y-%m-%d %H:%M')" "$${tag:-—}"; \
	done < <(find $(BACKUP_DIR) -maxdepth 1 -type f ! -name '*.sha256' ! -name '*.json' ! -name '*.log' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-); \
	[ "$$found" = 1 ] || printf '  \033[33m!\033[0m no artifacts in %s\n' "$(BACKUP_DIR)"; \
	printf '\n  total %s in %s\n\n' "$$(du -sh $(BACKUP_DIR) 2>/dev/null | cut -f1)" "$(BACKUP_DIR)"

backup-verify: ## Re-check every artifact against its recorded checksum
	@set -euo pipefail; bad=0; n=0; \
	for s in $(BACKUP_DIR)/*.sha256; do \
		[ -e "$$s" ] || continue; n=$$((n+1)); \
		if (cd $(BACKUP_DIR) && sha256sum -c --status "$$(basename $$s)"); then \
		^^printf '  \033[32m✓\033[0m %s\n' "$$(basename $${s%.sha256})"; \
		else printf '  \033[31m✗\033[0m %s  CORRUPT\n' "$$(basename $${s%.sha256})"; bad=$$((bad+1)); fi; \
	done; \
	printf '\n  %d checked, %d corrupt\n\n' "$$n" "$$bad"; [ "$$bad" = 0 ]

backup-prune: ## Apply the retention policy now.  DRY=1 to preview
	@./scripts/retention.sh $(if $(DRY),--dry-run,)

backup-sync: ## Copy artifacts off this host (BACKUP_SYNC_TARGET)
	@./scripts/sync.sh

restore: ## Restore.  TARGET=db|redis|files|config [FILE=…] CONFIRM=yes
	@./scripts/restore.sh $(or $(TARGET),) $(or $(FILE),)

# ── Scheduled backups ───────────────────────────────────────────────────────

cron-install: ## Install the BACKUP_CRON_* schedules into this user's crontab
	@./scripts/cron.sh install

cron-uninstall: ## Remove them
	@./scripts/cron.sh uninstall

cron-status: ## What is scheduled, and when each job LAST SUCCEEDED
	@./scripts/cron.sh status

cron-show: ## Print what would be installed, without installing it
	@./scripts/cron.sh show

# ── Operations ──────────────────────────────────────────────────────────────

health: ## Containers, postgres, redis, the app, backups and disk
	@./scripts/health.sh

storage: ## Every tree against its budget
	@./scripts/disk-guard.sh --report

doctor: ## preflight + health + cron status, in one pass
	@./scripts/preflight.sh || true
	@./scripts/health.sh || true
	@./scripts/cron.sh status || true

prune: ## Reclaim images, containers and cache — and prove the data survived
	@./scripts/prune.sh

version: ## Versions of everything involved
	@printf '\n  stack      %s\n' "$(STACK)"
	@printf '  image      %s:%s\n' "$(APP_IMAGE)" "$(APP_TAG)"
	@docker --version | sed 's/^/  docker     /'
	@docker compose version --short | sed 's/^/  compose    /'
	@$(COMPOSE) exec -T postgres postgres --version 2>/dev/null | sed 's/^/  /' || true
	@$(COMPOSE) exec -T redis redis-server --version 2>/dev/null | cut -d' ' -f1-3 | sed 's/^/  /' || true
	@printf '\n'
