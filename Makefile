SHELL := /bin/bash
ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

COMPOSE ?= docker compose
COMPOSE_FILES := \
	-f compose/docker-compose.infra.yml \
	-f compose/docker-compose.commons.yml \
	-f compose/docker-compose.pbms.yml \
	-f compose/docker-compose.registry.yml \
	-f compose/docker-compose.bridge.yml \
	-f compose/docker-compose.spar.yml

COMPOSE_PROFILES := --profile infra --profile with-redis --profile commons --profile pbms --profile farmer-registry --profile nsr-registry --profile farmer-registry-seed --profile nsr-registry-seed --profile bridge --profile spar --profile full

.DEFAULT_GOAL := help

.PHONY: help setup clone generate generate-docker sync-images install-odoo install-iam install-awe install-master-data install-registry-extension install-registry-ui install-registry-db-seed install-pbms-bg-tasks install-bridge install-spar \
	infra-ensure infra-up keycloak-init infra-down up down status logs clean \
	pbms-setup pbms-full-setup pbms-init init-pbms-bg-tasks init-bridge init-spar seed-spar-farmer-links \
	pbms-run pbms-stop free-native-stack free-spar-ports \
	start-pbms-bg-tasks start-spar start-bridge \
	verify-native-stack verify-pbms verify-registry verify-bridge verify-spar retry-bridge-fa staff-client staff-client-serve \
	farmer-registry-run nsr-registry-run bridge-run spar-run iam-run awe-run \
	farmer-setup farmer-registry-init farmer-registry-migrate farmer-registry-seed farmer-registry-fix-seed-enums farmer-registry-validate-seed \
	nsr-setup nsr-registry-init nsr-registry-migrate nsr-registry-seed seed-registry iam-init awe-init master-data-init master-data-seed \
	extension-package extension-setup extension-run extension-init extension-migrate extension-seed clone-profiles \
	up-infra up-pbms up-farmer-registry up-nsr-registry up-farmer-registry-seed up-nsr-registry-seed up-bridge up-spar up-full \
	docker-farmer-up docker-nsr-up docker-registry-up docker-registry-init \
	docker-farmer-continue docker-nsr-continue docker-down docker-all-up docker-clean

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

setup: clone generate ## Clone repos (PROFILE=registry) and generate local configs
	@echo "Setup complete (profile: $(or $(PROFILE),registry)). Next: make infra-up"

clone: ## Clone product repos for a profile (PROFILE=registry|national-social-registry|farmer-registry|pbms|bridge|spar|full)
	@bash scripts/clone-repos.sh "$(or $(PROFILE),registry)"

clone-profiles: ## List available clone/setup profiles
	@bash -c 'source scripts/lib/clone-profiles.sh; clone_profile_list'

generate: ## Generate Odoo conf and service env files from templates
	@bash scripts/generate-config.sh

generate-docker: ## Generate Docker-network env files under generated/**/docker/
	@bash scripts/generate-docker-config.sh

sync-images: ## Sync versions.yaml image pins into .env / .env.example
	@bash scripts/sync-image-env.sh

install-odoo: ## Install Odoo 17 Python dependencies into a venv
	@bash scripts/install-odoo-deps.sh

install-pbms-bg-tasks: ## Install PBMS staff portal API and Celery Python dependencies
	@bash scripts/install-pbms-bg-tasks.sh

install-bridge: ## Install G2P Bridge partner API, Celery, and example bank Python dependencies
	@bash scripts/install-bridge.sh

install-spar: ## Install SPAR mapper and bene portal API Python dependencies
	@bash scripts/install-spar.sh

install-registry-extension: ## Install domain extension (VARIANT=farmer-registry|national-social-registry)
	@bash scripts/install-registry-extension.sh $(VARIANT)

install-registry-ui: ## Install npm deps for Gen2 staff UI (registry-platform/ui/staff-ui)
	@bash scripts/install-registry-ui.sh

install-registry-db-seed: ## Install db-seed Python deps (VARIANT=farmer-registry|national-social-registry|custom)
	@test -n "$(VARIANT)" || (echo "Set VARIANT to your registry slug (e.g. disability-registry)" >&2; exit 1)
	@bash scripts/install-registry-db-seed.sh $(VARIANT)

install-iam: ## Install IAM staff portal API Python dependencies
	@bash scripts/install-iam.sh

install-awe: ## Install Approval Workflow Engine (AWE) Python dependencies
	@bash scripts/install-awe.sh

install-master-data: ## Install Master Data API + db-seed Python dependencies
	@bash scripts/install-master-data.sh

iam-init: generate ## Migrate IAM schema, seed login providers, and sync variant registry applications
	@bash scripts/init-iam.sh

awe-init: generate ## Initialise AWE schema and registry webhook callback secret
	@bash scripts/init-awe.sh

master-data-init: generate ## Migrate Master Data schema for a variant (VARIANT=farmer-registry|national-social-registry)
	@VARIANT=$(or $(VARIANT),farmer-registry) bash scripts/init-master-data.sh $(or $(VARIANT),farmer-registry)

master-data-seed: generate ## Seed Master Data geo/codelists (VARIANT=..., MASTER_DATA_COUNTRY_PACK=XKM)
	@VARIANT=$(or $(VARIANT),farmer-registry) bash scripts/seed-master-data.sh $(or $(VARIANT),farmer-registry)

iam-run: generate ## Run IAM staff portal API natively
	@bash scripts/run-iam.sh

awe-run: generate ## Run AWE API natively
	@bash scripts/run-awe.sh

farmer-registry-init: generate ## Migrate schema and seed Farmer Registry configuration
	@VARIANT=farmer-registry bash scripts/init-registry-variant.sh farmer-registry

farmer-registry-migrate: generate ## Migrate Farmer Registry schema only
	@VARIANT=farmer-registry bash scripts/migrate-registry-db.sh farmer-registry

farmer-registry-seed: generate ## Seed Farmer Registry configuration and optional sample data
	@VARIANT=farmer-registry bash scripts/seed-registry-db.sh farmer-registry

farmer-registry-fix-seed-enums: ## Fix legacy farmer seed enums + backfill register history
	@bash scripts/farmer-post-seed.sh

farmer-registry-validate-seed: ## Validate farmer seed/DB data against extension schemas
	@bash scripts/validate-farmer-registry-seed.sh

farmer-setup: generate infra-up ## One-time Farmer Registry bootstrap: IAM, AWE, migrate, and seed (honours LOAD_SAMPLE_DATA in .env)
	@bash scripts/farmer-setup.sh

nsr-setup: generate infra-up ## One-time NSR bootstrap: IAM, AWE, migrate, and seed (honours LOAD_SAMPLE_DATA in .env)
	@bash scripts/nsr-setup.sh

nsr-registry-init: generate ## Migrate schema and seed NSR configuration
	@VARIANT=national-social-registry bash scripts/init-registry-variant.sh national-social-registry

nsr-registry-migrate: generate ## Migrate NSR schema only
	@VARIANT=national-social-registry bash scripts/migrate-registry-db.sh national-social-registry

nsr-registry-seed: generate ## Seed NSR configuration and optional sample data
	@VARIANT=national-social-registry bash scripts/seed-registry-db.sh national-social-registry

seed-registry: generate ## Seed a registry variant (VARIANT=farmer-registry|national-social-registry|custom)
	@test -n "$(VARIANT)" || (echo "Set VARIANT to your registry slug" >&2; exit 1)
	@VARIANT=$(VARIANT) bash scripts/seed-registry-db.sh $(VARIANT)

extension-package: ## Bootstrap empty extension product (NAME=disability-registry, optional REPO_URL=, SETUP=1)
	@bash scripts/bootstrap-extension-package.sh "$(NAME)" "$(REPO_URL)"

extension-setup: generate infra-up ## One-time setup for custom extension (NAME=disability-registry)
	@test -n "$(NAME)" || (echo "Set NAME=your-extension-slug (same as extension-package)" >&2; exit 1)
	@bash scripts/registry-setup.sh "$(NAME)"

extension-init: generate ## Migrate + seed custom extension configuration (NAME=disability-registry)
	@test -n "$(NAME)" || (echo "Set NAME=your-extension-slug" >&2; exit 1)
	@VARIANT=$(NAME) bash scripts/init-registry-variant.sh "$(NAME)"

extension-migrate: generate ## Migrate custom extension schema only (NAME=disability-registry)
	@test -n "$(NAME)" || (echo "Set NAME=your-extension-slug" >&2; exit 1)
	@VARIANT=$(NAME) bash scripts/migrate-registry-db.sh "$(NAME)"

extension-seed: generate ## Seed custom extension configuration (NAME=disability-registry)
	@test -n "$(NAME)" || (echo "Set NAME=your-extension-slug" >&2; exit 1)
	@VARIANT=$(NAME) bash scripts/seed-registry-db.sh "$(NAME)"

extension-run: generate ## Run custom extension natively (NAME=disability-registry)
	@test -n "$(NAME)" || (echo "Set NAME=your-extension-slug" >&2; exit 1)
	@bash scripts/run-registry-variant.sh "$(NAME)"

infra-ensure: ## Start infra containers if stopped (no Keycloak provisioning)
	@test -f .env || cp .env.example .env
	@bash -c 'set -a; source .env; set +a; \
		profiles=(--profile infra); \
		if [[ "$${USE_EXTERNAL_REDIS:-false}" != "true" ]]; then profiles+=(--profile with-redis); fi; \
		$(COMPOSE) $(COMPOSE_FILES) "$${profiles[@]}" up -d'

keycloak-init: infra-ensure ## Provision Keycloak staff realm and OIDC clients
	@bash -c 'set -a; source .env; set +a; $(COMPOSE) -f compose/docker-compose.infra.yml --profile infra up keycloak-init --abort-on-container-exit' || true

infra-up: infra-ensure keycloak-init ## Start shared infrastructure (Postgres, Redis, MinIO, Keycloak)
	@bash -c 'set -a; source .env; set +a; \
		echo "Infrastructure started."; \
		echo "  Postgres: localhost:$${POSTGRES_PORT:-5432}"; \
		if [[ "$${USE_EXTERNAL_REDIS:-false}" == "true" ]]; then \
			echo "  Redis:    external ($${REDIS_HOST:-localhost}:$${REDIS_PORT:-6379})"; \
		else \
			echo "  Redis:    localhost:$${REDIS_PORT:-6379} (Docker)"; \
		fi; \
		echo "  MinIO:    http://localhost:9000 (console :9001)"; \
		echo "  Keycloak: http://localhost:8080 (admin/admin by default)"; \
		echo "  Staff realm + OIDC clients are provisioned automatically (see keycloak/README.md)"; \
		echo "  Dev SSO user: staff / staff (override in .env)"; \
		echo "  Re-provision Keycloak only: make keycloak-init"'

infra-down: ## Stop shared infrastructure
	@$(COMPOSE) $(COMPOSE_FILES) --profile infra down

up: infra-up ## Alias for infra-up

down: ## Stop all compose services
	@$(COMPOSE) $(COMPOSE_FILES) $(COMPOSE_PROFILES) down

status: ## Show compose service status
	@$(COMPOSE) $(COMPOSE_FILES) ps

logs: ## Tail infrastructure logs
	@$(COMPOSE) $(COMPOSE_FILES) --profile infra logs -f

clean: ## Stop services and remove volumes (destructive)
	@$(COMPOSE) $(COMPOSE_FILES) $(COMPOSE_PROFILES) down -v

up-infra: infra-up ## Start only shared infrastructure

up-pbms: infra-up ## Start infra + containerized PBMS image
	@$(COMPOSE) $(COMPOSE_FILES) --profile pbms up -d

up-farmer-registry: docker-farmer-up ## Docker Farmer only: infra + IAM + AWE + Farmer + seed (no NSR)

up-nsr-registry: docker-nsr-up ## Docker NSR only: infra + IAM + AWE + NSR + seed (no Farmer)

up-farmer-registry-seed: generate-docker infra-up ## Run Farmer Registry db-seed container (after migrate)
	@bash -c 'set -a; source .env; set +a; export USE_EXTERNAL_REDIS=false; \
		$(COMPOSE) $(COMPOSE_FILES) --profile farmer-registry-seed run --rm --no-deps farmer-registry-db-seed'

up-nsr-registry-seed: generate-docker infra-up ## Run NSR db-seed container (after migrate)
	@bash -c 'set -a; source .env; set +a; export USE_EXTERNAL_REDIS=false; \
		$(COMPOSE) $(COMPOSE_FILES) --profile nsr-registry-seed run --rm --no-deps nsr-registry-db-seed'

up-bridge: generate infra-up ## Start infra + containerized G2P Bridge (if images exist)
	@$(COMPOSE) $(COMPOSE_FILES) --profile bridge up -d

up-spar: infra-up ## Start infra for SPAR native development
	@echo "SPAR runs natively. Use: make spar-run"

up-full: generate-docker infra-up ## Start infra + all container profiles
	@bash -c 'set -a; source .env; set +a; export USE_EXTERNAL_REDIS=false; \
		$(COMPOSE) $(COMPOSE_FILES) --profile with-redis --profile commons --profile full up -d'

docker-farmer-up: ## Docker Farmer only: Keycloak+IAM+AWE+MasterData+Farmer + seed (full recreate)
	@bash scripts/docker-farmer-up.sh

docker-nsr-up: ## Docker NSR only: Keycloak+IAM+AWE+MasterData+NSR + seed (full recreate)
	@bash scripts/docker-nsr-up.sh

docker-farmer-continue: ## Resume Farmer after a failed up (no teardown); RESET_DBS=1 to remigrate
	@bash scripts/docker-farmer-continue.sh

docker-nsr-continue: ## Resume NSR after a failed up (no teardown); RESET_DBS=1 to remigrate
	@bash scripts/docker-nsr-continue.sh

docker-all-up: docker-registry-up ## Docker all: Farmer then NSR (full recreate each)

docker-down: ## Stop all OpenG2P Docker services (infra/commons/farmer/nsr/pbms/bridge/spar)
	@bash scripts/docker-down.sh

docker-clean: ## Stop all OpenG2P Docker services and remove volumes (destructive)
	@bash -c 'set -a; source .env 2>/dev/null; set +a; export USE_EXTERNAL_REDIS=false; \
		$(COMPOSE) $(COMPOSE_FILES) $(COMPOSE_PROFILES) down -v --remove-orphans'

docker-registry-up: ## Docker both Farmer then NSR (prefer docker-farmer-up / docker-nsr-up)
	@bash scripts/docker-registry-up.sh

docker-registry-init: ## Deprecated alias — use docker-farmer-up / docker-nsr-up (includes seed)
	@bash scripts/docker-registry-init.sh

pbms-setup: ## One-time PBMS bootstrap (infra, deps, registry, Odoo + bg-task DBs)
	@bash scripts/pbms-setup.sh

pbms-full-setup: ## One-time PBMS + SPAR + Bridge bootstrap (disbursement-ready)
	@bash scripts/pbms-full-setup.sh

pbms-init: generate ## Bootstrap pbmsdb with Odoo base modules (first-time only)
	@bash scripts/init-pbms.sh

init-pbms-bg-tasks: generate ## Migrate bgtaskdb schema for PBMS background tasks
	@bash scripts/init-pbms-bg-tasks.sh

init-bridge: generate ## Migrate g2pbridgedb and examplebankdb for G2P Bridge
	@bash scripts/init-bridge.sh

init-spar: generate ## Migrate spardb and seed SPAR strategies
	@bash scripts/init-spar.sh

seed-spar-farmer-links: ## Link farmer registry internal_record_id → bank account in SPAR
	@bash scripts/seed-spar-farmer-links.sh

pbms-run: ## Run PBMS + registry + Odoo (does not start SPAR or Bridge)
	@bash scripts/run-pbms.sh

start-pbms-bg-tasks: generate ## Start PBMS staff API + Celery only
	@bash scripts/start-pbms-bg-tasks.sh

start-bridge: generate ## Start G2P Bridge only (run start-spar first for FA resolution)
	@bash scripts/run-bridge.sh

free-spar-ports: ## Stop SPAR processes only (leave PBMS/Bridge running)
	@bash scripts/free-spar-ports.sh

free-native-stack: ## Stop all native PBMS/registry/bridge/spar processes (clean restart)
	@bash scripts/free-native-stack.sh

pbms-stop: free-native-stack ## Stop full native stack (Celery, APIs, Odoo) — does not stop Docker infra

verify-native-stack: ## Verify pbms+registry (pass COMPONENTS=spar bridge pbms registry)
	@bash scripts/verify-native-stack.sh $(COMPONENTS)

verify-pbms: ## Verify PBMS Celery only
	@bash scripts/verify-native-stack.sh pbms

verify-registry: ## Verify registry Celery only
	@bash scripts/verify-native-stack.sh registry

verify-bridge: ## Verify Bridge Celery only
	@bash scripts/verify-native-stack.sh bridge

verify-spar: ## Verify SPAR mapper API only
	@bash scripts/verify-native-stack.sh spar

retry-bridge-fa: ## Reset FA ERROR batches to PENDING (requires SPAR running)
	@bash scripts/retry-bridge-fa.sh

farmer-registry-run: generate ## Run Farmer Registry Gen2 natively
	@bash scripts/run-registry-variant.sh farmer-registry

nsr-registry-run: generate ## Run National Social Registry Gen2 natively
	@bash scripts/run-registry-variant.sh national-social-registry

bridge-run: generate ## Alias for start-bridge
	@bash scripts/run-bridge.sh

start-spar: ## Start SPAR (no config regen)
	@bash scripts/run-spar.sh

spar-run: generate start-spar ## Regenerate config then start SPAR

staff-client: ## Test standalone JS staff client against IAM and Registry APIs (follows docs/ routes)
	@node scripts/staff-client.mjs

staff-client-serve: ## Run interactive JS staff client web UI on http://localhost:3005
	@node scripts/staff-client.mjs --serve
