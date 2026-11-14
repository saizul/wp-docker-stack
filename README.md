# wp-docker-stack

[![CI](https://github.com/saizul/wp-docker-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/saizul/wp-docker-stack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A production-ready **WordPress stack on Docker Compose**, configured from one `.env` file:

- **nginx** with a FastCGI page cache and security headers
- **PHP-FPM**: the official WordPress image plus the `redis` extension, tuned OPcache and wp-cli
- **MariaDB** 11.8 LTS and **Redis** 8 for the object cache
- a **cron** container that runs WP-Cron through wp-cli instead of on page loads
- a **backup** container: nightly `mariadb-dump` and file archives to a local volume, with an optional rclone copy to **Cloudflare R2 / S3**
- optional **Caddy** or **Traefik** for automatic TLS

The `make` targets and the `bin/wpstack` script handle init (random secrets), up/down, logs, backup,
restore, wp-cli, updates and health checks. CI runs shellcheck, hadolint, bats and `docker compose config`,
plus a **real `docker compose up` smoke test** that checks the installer, installs WordPress and
exercises caching, backup and restore.

---

## Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [Configuration](#configuration)
- [TLS: Caddy, Traefik or your own proxy](#tls-caddy-traefik-or-your-own-proxy)
- [Backups and restore](#backups-and-restore)
- [Updates](#updates)
- [Examples](#examples)
- [Testing](#testing)
- [Security notes](#security-notes)
- [Limitations](#limitations)
- [License](#license)

## Architecture

```
            :80/:443 (profile caddy | traefik)
                 │
   edge net ─────┼───────────────────────────────
                 ▼
             ┌────────┐   127.0.0.1:8080 (HTTP_BIND:HTTP_PORT)
             │ nginx  │◄──────────────────────────
             └───┬────┘   fastcgi cache, headers, static files (wordpress volume :ro)
   app net (internal, no internet) ───────────────
        ┌────────┼──────────┬──────────┬─────────┐
        ▼        ▼          ▼          ▼         ▼
     ┌─────┐  ┌──────┐  ┌───────┐  ┌───────┐  ┌────────┐
     │ php │  │ cron │  │  db   │  │ redis │  │ backup │──► rclone ► R2/S3
     └─────┘  └──────┘  └───────┘  └───────┘  └────────┘
   php, cron and backup also join "egress" for updates and off-site copies.
```

| Service | Image (pinned in `.env`) | Runs as | Root FS | Healthcheck |
|---------|--------------------------|---------|---------|-------------|
| nginx   | `nginx:1.30-alpine` | master root, workers `nginx`, caps dropped | read-only | `/nginx-health` |
| php     | built `FROM wordpress:7.1-php8.4-fpm-alpine` | `www-data` (82) | read-only | FPM ping over FastCGI |
| cron    | same image as php | `www-data` | read-only | heartbeat file |
| db      | `mariadb:11.8` | `mysql` | writable (data volume) | `healthcheck.sh --connect --innodb_initialized` |
| redis   | `redis:8.8-alpine` | `redis` | read-only | `redis-cli ping` |
| backup  | built `FROM alpine:3.24` | `www-data` | read-only | heartbeat file |
| caddy   | `caddy:2.11-alpine` (profile) | root, `NET_BIND_SERVICE` only | default | admin API |
| traefik | `traefik:v3.7` (profile) | root, `NET_BIND_SERVICE` only | default | `traefik healthcheck --ping` |

The PHP image adds these to the official WordPress image (which already ships bcmath, exif, gd with AVIF and WebP, intl, mysqli, zip, imagick and opcache):

- the **phpredis 6.3.0** extension
- **wp-cli 2.12.0**, verified against its published SHA-512
- `mariadb-client`, so `wp db export` and `wp db import` work
- a tuned `php.ini`, `opcache.ini` and FPM pool, all driven by environment variables
- healthcheck helpers

## Requirements

- Docker Engine 24 or newer, with the Compose v2 plugin (`docker compose`)
- GNU Make, Bash and OpenSSL (or `/dev/urandom`) on the host
- About 1.5 GB of RAM for the default limits

## Install

```bash
git clone https://github.com/saizul/wp-docker-stack.git
cd wp-docker-stack

make init                        # .env + random secrets in ./secrets/
make up                          # build and start
make healthcheck                 # containers + HTTP check
open http://localhost:8080       # WordPress installer
```

For a public site with automatic HTTPS:

```bash
make init DOMAIN=blog.example.com EMAIL=ops@example.com
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=caddy/' .env
make up
```

`make init` never overwrites existing secrets. It only creates the ones that are missing, so it is safe to run again.

## Usage

| Command | What it does |
|---------|--------------|
| `make init [DOMAIN=… EMAIL=…]` | Create `.env` from `.env.example` and generate 11 random secrets (DB, root, Redis, 8 WordPress salts) |
| `make up` | Validate the config, build images and start everything (`docker compose up -d --build`) |
| `make down` | Stop the stack. `make down ARGS=-v` also **deletes all volumes** |
| `make restart ARGS=nginx` | Restart services |
| `make ps` / `make logs ARGS="php nginx"` | Status and logs (`TAIL=500 make logs`) |
| `make config` | Validate `.env`, secrets and `docker compose config` |
| `make wp ARGS="plugin list"` | wp-cli passthrough in the php container |
| `make backup` / `make backups` | Take a backup now, or list backups |
| `make restore NAME=latest ARGS=--yes` | Restore a backup (`--db-only` or `--files-only` are optional) |
| `make update` | Back up, pull and rebuild images, then update core, plugins, themes and languages |
| `make healthcheck` | Check that every service is running and healthy, and that HTTP returns 200/301/302 |

Everything also works without make: `bin/wpstack <command>`, for example `bin/wpstack wp user list`.

After the WordPress install, turn on the Redis object cache:

```bash
make wp ARGS="plugin install redis-cache --activate"
make wp ARGS="redis enable"
```

The connection constants (`WP_REDIS_HOST`, `WP_REDIS_PASSWORD`, `WP_REDIS_PREFIX`) are already in `wp-config.php`.

## Configuration

Everything is set in `.env`. See [`.env.example`](.env.example) for the full list with comments.

| Variable | Default | Notes |
|----------|---------|-------|
| `COMPOSE_PROJECT_NAME` | `wpstack` | Prefix for containers, volumes and networks. Also used as the Redis key prefix |
| `COMPOSE_PROFILES` | (empty) | `caddy`, `traefik` or empty (bring your own proxy) |
| `DOMAIN`, `WP_URL` | `localhost`, `http://localhost:8080` | `WP_URL` sets `WP_HOME` and `WP_SITEURL` |
| `ACME_EMAIL` | (empty) | Required by the TLS profiles |
| `HTTP_BIND`, `HTTP_PORT` | `127.0.0.1`, `8080` | Where nginx is published. Use `0.0.0.0` and `80` to serve plain HTTP directly |
| `*_IMAGE` | pinned minor versions | Change these to move to a new release |
| `DB_NAME`, `DB_USER`, `DB_TABLE_PREFIX` | `wordpress`, `wordpress`, `wp_` | |
| `DB_INNODB_BUFFER_POOL`, `DB_MAX_CONNECTIONS` | `256M`, `100` | |
| `PHP_MEMORY_LIMIT`, `PHP_UPLOAD_MAX`, `PHP_MAX_EXECUTION_TIME` | `256M`, `64M`, `120` | The upload limit also sets nginx `client_max_body_size` |
| `PHP_FPM_MAX_CHILDREN` … `PHP_FPM_MAX_REQUESTS` | `10` … `500` | FPM `pm = dynamic` pool |
| `PHP_OPCACHE_MEMORY` | `192` | MB |
| `WP_DEBUG` | (empty) | Set to `1` to enable `WP_DEBUG` |
| `NGINX_FASTCGI_CACHE` | `on` | `off` disables the page cache |
| `NGINX_CACHE_VALID`, `NGINX_CACHE_MAX_SIZE` | `10m`, `512m` | Cache lifetime for 200/301 responses, and cache size |
| `NGINX_BLOCK_XMLRPC` | `on` | `off` allows `xmlrpc.php` (Jetpack, mobile apps) |
| `NGINX_REAL_IP_FROM` | `172.16.0.0/12` | Trusted proxy CIDR for `X-Forwarded-For` |
| `REDIS_MAXMEMORY` | `256mb` | LRU eviction, no persistence (it is only a cache) |
| `WP_CRON_INTERVAL` | `60` | Seconds between `wp cron event run --due-now` |
| `BACKUP_TIME`, `BACKUP_KEEP`, `BACKUP_ON_START` | `03:30`, `7`, `false` | Daily time in UTC, number of local backups to keep |
| `BACKUP_OFFSITE` + `S3_*` | `none` | `s3` copies every backup with rclone (R2, S3, B2, MinIO and others) |
| `LIMIT_*` | see file | Memory and CPU limits per service |

**Page cache rules.** Anonymous `GET`/`HEAD` requests without a query string are cached. These are never cached:

- logged-in users, password-protected posts, commenters, and WooCommerce/EDD cart sessions (detected by cookie)
- `wp-admin`, `wp-login.php`, `wp-json`, `xmlrpc.php`, feeds, sitemaps, and cart, checkout and account pages
- 302 redirects

Every response carries an `X-Cache-Status` header (`HIT`, `MISS`, `BYPASS`). The cache lives in tmpfs, so `make restart ARGS=nginx` purges it. `restore` and `update` do this automatically.

**nginx also blocks:**

- dotfiles, `wp-config*.php`, `readme.html`, `license.txt`, and `*.sql`/`*.bak`/`*.log`/`*.ini`/`*.sh` files
- PHP execution under `wp-content/uploads`, and direct access to `wp-includes/*.php` (the TinyMCE loader is the exception)
- `xmlrpc.php`, unless you turn the block off

## TLS: Caddy, Traefik or your own proxy

- **Caddy** (`COMPOSE_PROFILES=caddy`): automatic Let's Encrypt certificates for `DOMAIN`, HTTP/3, HSTS. Config: [`docker/caddy/Caddyfile`](docker/caddy/Caddyfile).
- **Traefik** (`COMPOSE_PROFILES=traefik`): TLS-ALPN challenge, an HTTP to HTTPS redirect, and HSTS through labels on the nginx service. It needs read-only access to the Docker socket.
- **Your own proxy** (empty profile): nginx listens on `127.0.0.1:8080`. See [`examples/host-nginx-proxy.conf`](examples/host-nginx-proxy.conf). Send `X-Forwarded-Proto` so WordPress detects HTTPS.

The TLS profiles need ports 80 and 443 free on the host and DNS for `DOMAIN` pointing at the server. `make config` refuses a TLS profile when `DOMAIN` is `localhost` or `ACME_EMAIL` is missing.

## Backups and restore

The backup container wakes up every day at `BACKUP_TIME` (UTC). Each run creates `/backups/<YYYYmmddTHHMMSSZ>/` in the `backups` volume, containing:

| File | Content |
|------|---------|
| `db.sql.gz` | `mariadb-dump --single-transaction --routines --triggers --events` |
| `files.tar.gz` | the whole WordPress tree (`wp-config.php`, core, `wp-content`), without cache and upgrade folders |
| `manifest.txt` | time, WordPress version, sizes, duration |
| `SHA256SUMS` | checksums, verified before every restore |

- The database password reaches `mariadb-dump` through a temporary defaults file with mode 600, never as a command-line argument.
- A lock directory prevents overlapping runs.
- A failed run leaves no partial backup behind.
- Only the newest `BACKUP_KEEP` backups are kept locally.

**Off-site copies to Cloudflare R2** (or any S3-compatible storage): set these in `.env`:

```ini
BACKUP_OFFSITE=s3
S3_PROVIDER=Cloudflare
S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
S3_BUCKET=blog-backups
S3_PREFIX=blog.example.com
S3_ACCESS_KEY_ID=...        # R2 API token: Object Read & Write on this bucket
S3_SECRET_ACCESS_KEY=...
```

rclone is configured entirely through `RCLONE_CONFIG_OFFSITE_*` environment variables, so no rclone.conf file is needed. Remote retention is up to you: use a bucket lifecycle rule (for example, delete after 30 days).

**Restore:**

```bash
make backups                                   # list
make restore NAME=20261114T033000Z ARGS=--yes  # database + files
make restore NAME=latest ARGS="--db-only --yes"
```

A restore goes through these steps:

1. Verify the checksums.
2. Stop `php` and `cron`.
3. Import the dump.
4. Extract the files to a staging directory, then swap them in. The current tree is only replaced after the archive extracts cleanly.
5. Start the services again, flush the object cache and purge the page cache.

To copy a backup off the host by hand:

```bash
docker compose cp backup:/backups/20261114T033000Z ./20261114T033000Z
```

## Updates

`make update` does the following:

1. Take a backup (skip it with `ARGS=--no-backup`).
2. `docker compose pull`, then rebuild the custom images with `--pull`.
3. Recreate the containers.
4. Run `wp core update`, `wp core update-db`, `wp plugin update --all`, `wp theme update --all` and `wp language core update`. Skip this step with `ARGS=--images-only`.
5. Purge the page cache.

To move to a new minor version of a service (for example PHP 8.5 or a new nginx), change the matching `*_IMAGE` variable in `.env` and run `make update`.

## Examples

- [`examples/production-caddy.env.example`](examples/production-caddy.env.example): a production `.env` with Caddy TLS and R2 backups
- [`examples/docker-compose.override.yml.example`](examples/docker-compose.override.yml.example): local development with a mounted theme, no page cache and Mailpit
- [`examples/host-nginx-proxy.conf`](examples/host-nginx-proxy.conf): TLS on a host nginx in front of the stack
- [`examples/host-cron-offsite-check.sh`](examples/host-cron-offsite-check.sh): a host cron alert when backups go stale

## Testing

```bash
make test            # bats suites (docker is stubbed; bats comes from npx if it is not installed)
make shellcheck      # every shell script
make hadolint        # both Dockerfiles (uses the hadolint image when the binary is missing)
make compose-validate
bash test/smoke.sh   # full end-to-end run against real Docker (uses port 8080)
```

- **bats** (`test/*.bats`) covers `init` (secret generation, permissions, idempotency), `.env` validation, every `wpstack` command against a recording `docker` stub, `backup.sh` (dump, archive, checksums, prune, locking, restore, rclone env, health) with stubbed `mariadb-dump`, `mariadb` and `rclone`, and the cron loop and FPM healthcheck.
- **CI** runs shellcheck, hadolint, the bats suites and `docker compose config` for every profile. It then runs `test/smoke.sh` on the GitHub runner, which:
  1. builds and starts the real stack and waits until every service is healthy
  2. checks that `/` returns 302 to `/wp-admin/install.php`, and that the installer returns 200
  3. checks the security headers and blocked paths
  4. installs WordPress with wp-cli
  5. checks for an `X-Cache-Status: HIT`
  6. checks the PHP extensions, OPcache and the Redis object cache
  7. checks the non-root and read-only containers, and that no DB or Redis ports are published
  8. checks the cron heartbeat
  9. takes a backup, changes the site, restores it and confirms the change is gone

## Security notes

- **Secrets** are generated locally by `make init` (`/dev/urandom`, 32 or 64 characters) into `./secrets/`. The directory is mode 700, and the files are 644 so the `mysql`, `redis` and `www-data` users inside the containers can read them through the bind mounts. They reach the containers as Compose secrets (`*_FILE` variables), never as plain environment variables. `.env` and `secrets/` are gitignored.
- **No exposed database or cache.** MariaDB and Redis sit only on an `internal` network with no published ports and no internet access. Redis also requires a password.
- **Least privilege.** Every container runs with `no-new-privileges` and `cap_drop: ALL`; nginx, Caddy and Traefik get back only the few capabilities they need. PHP, cron, backup, Redis and MariaDB run as non-root users. nginx, PHP, cron, Redis and backup have read-only root filesystems with tmpfs scratch space. nginx mounts the WordPress files read-only.
- **Limits.** Every service has memory limits and `pids_limit`, plus CPU limits on PHP and the database. Logs are rotated (`json-file`, 5 × 10 MB).
- **WordPress hardening.** `DISALLOW_FILE_EDIT`, WP-Cron disabled in favour of the cron container, and XML-RPC blocked by default.
- **Supply chain.** Base images are official Docker Hub images pinned to a minor version. wp-cli is checked against its SHA-512.
- The Traefik profile mounts the Docker socket read-only. That still gives read access to the Docker API, so use a socket proxy where that matters.
- Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## Limitations

- Single host. There is no clustering, no shared storage for multiple PHP nodes, and no zero-downtime deploys (a restart of php drops in-flight requests).
- The page cache has no per-URL purge (the official nginx image has no purge module). Pages expire after `NGINX_CACHE_VALID`, and restarting nginx clears everything. Keep `NGINX_CACHE_VALID` short for sites that change often.
- Backups are logical dumps plus full file archives. They suit small and medium sites, but very large media libraries make every backup a full copy (there are no incremental backups). For big sites, consider syncing `wp-content/uploads` to object storage separately.
- Off-site retention is not managed by the stack. Use bucket lifecycle rules.
- `make update` updates plugins and themes in place. Test on staging first if your site depends on specific versions.
- The smoke test runs only in CI or wherever Docker is available. The bats suites run anywhere with Bash.
- Imagick on Alpine is marked as possibly unsupported upstream. WordPress falls back to GD automatically.

## License

[MIT](LICENSE) © 2026 Saizul Amin
