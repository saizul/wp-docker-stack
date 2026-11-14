# wp-docker-stack: thin wrapper around bin/wpstack.
# Usage: make <target> [ARGS="..."]   e.g. make wp ARGS="plugin list"

WPSTACK := ./bin/wpstack
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help init up down restart ps logs config wp backup backups restore update healthcheck \
        lint test test-bats shellcheck hadolint compose-validate

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

init: ## Create .env and random secrets (DOMAIN=example.com EMAIL=you@example.com)
	@$(WPSTACK) init $(if $(DOMAIN),--domain $(DOMAIN)) $(if $(EMAIL),--email $(EMAIL)) $(ARGS)

up: ## Build and start the stack
	@$(WPSTACK) up $(ARGS)

down: ## Stop the stack
	@$(WPSTACK) down $(ARGS)

restart: ## Restart services (ARGS="nginx")
	@$(WPSTACK) restart $(ARGS)

ps: ## List services
	@$(WPSTACK) ps $(ARGS)

logs: ## Follow logs (ARGS="php nginx")
	@$(WPSTACK) logs $(ARGS)

config: ## Validate .env and docker compose configuration
	@$(WPSTACK) config

wp: ## Run wp-cli (ARGS="plugin list")
	@$(WPSTACK) wp $(ARGS)

backup: ## Take a backup now
	@$(WPSTACK) backup

backups: ## List backups
	@$(WPSTACK) backups

restore: ## Restore a backup (NAME=20260101T033000Z or NAME=latest, ARGS="--db-only --yes")
	@$(WPSTACK) restore $(NAME) $(ARGS)

update: ## Backup, update images, WordPress core, plugins and themes
	@$(WPSTACK) update $(ARGS)

healthcheck: ## Check container health and HTTP
	@$(WPSTACK) healthcheck

# --- Development -----------------------------------------------------------------
SHELL_FILES := bin/wpstack lib/wpstack.sh docker/backup/backup.sh docker/php/bin/php-fpm-healthcheck \
               docker/php/bin/wp-cron-loop test/stubs/docker test/stubs/curl test/smoke.sh test/helpers/common.bash examples/host-cron-offsite-check.sh

lint: shellcheck hadolint compose-validate ## Run all linters

shellcheck: ## Lint shell scripts
	shellcheck -x $(SHELL_FILES)

hadolint: ## Lint Dockerfiles (uses the hadolint image when hadolint is not installed)
	@if command -v hadolint >/dev/null; then hadolint docker/php/Dockerfile docker/backup/Dockerfile; \
	else docker run --rm -v "$$PWD:/work:ro" -w /work hadolint/hadolint \
	  hadolint docker/php/Dockerfile docker/backup/Dockerfile; fi

compose-validate: ## Validate docker-compose.yml with every profile (runs init if needed)
	@test -f .env || $(WPSTACK) init
	docker compose config --quiet
	docker compose --profile caddy --profile tools config --quiet
	docker compose --profile traefik config --quiet

test: test-bats ## Run the test suite

test-bats: ## Run bats tests (installs bats via npx when missing)
	@if command -v bats >/dev/null; then bats test; else npx --yes bats@1.13.0 test; fi
