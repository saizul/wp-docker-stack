# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-14

### Added

- Docker Compose stack: nginx 1.30 (FastCGI page cache, security headers, hardened locations), PHP-FPM built from `wordpress:7.1-php8.4-fpm-alpine` with phpredis 6.3.0, wp-cli 2.12.0 and tuned OPcache, MariaDB 11.8, Redis 8.8, a wp-cli cron container and a backup container.
- Optional Caddy 2.11 and Traefik v3.7 TLS profiles.
- `.env`-driven configuration with validation, and Compose secrets created by `make init`.
- `bin/wpstack` and `make` targets: init, up, down, restart, ps, logs, config, wp, backup, backups, restore, update, healthcheck.
- Backups: mariadb-dump and file archives with checksums, retention, locking, and an optional rclone copy to Cloudflare R2 / S3.
- Hardening: non-root services, read-only root filesystems, `cap_drop: ALL`, `no-new-privileges`, an internal network for DB and Redis, resource and PID limits, healthchecks everywhere.
- Tests: bats suites with a docker stub, shellcheck, hadolint, `docker compose config` validation and an end-to-end smoke test in CI.

[0.1.0]: https://github.com/saizul/wp-docker-stack/releases/tag/v0.1.0
