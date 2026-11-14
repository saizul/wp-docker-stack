#!/usr/bin/env bash
# End-to-end smoke test: start the real stack, check the installer, install
# WordPress, verify caching, hardening, cron, backup and restore.
# Needs Docker with the compose plugin. Used by CI; safe to run locally on a
# machine where port 8080 is free (it uses its own COMPOSE_PROJECT_NAME).
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export WPSTACK_ASSUME_YES=1
export NO_COLOR=1
WPSTACK=./bin/wpstack
PORT="${SMOKE_PORT:-8080}"
BASE="http://127.0.0.1:${PORT}"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'SMOKE FAIL: %s\n' "$*" >&2; exit 1; }

http_code() { curl -s -o /dev/null -w '%{http_code}' -H "Host: localhost:${PORT}" "$@"; }

step "init"
if [ ! -f .env ]; then
  "$WPSTACK" init --domain=localhost
  sed -i.bak "s/^HTTP_PORT=.*/HTTP_PORT=${PORT}/;s#^WP_URL=.*#WP_URL=http://localhost:${PORT}#;s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=wpsmoke/" .env
  rm -f .env.bak
fi
"$WPSTACK" config

step "up"
"$WPSTACK" up

step "wait for healthy stack"
for i in $(seq 1 60); do
  if "$WPSTACK" healthcheck >/dev/null 2>&1; then echo "healthy after ~$((i * 5))s"; break; fi
  [ "$i" -eq 60 ] && { "$WPSTACK" healthcheck || true; fail "stack did not become healthy"; }
  sleep 5
done

step "installer redirect and page"
code="$(http_code "$BASE/")"
[ "$code" = "302" ] || fail "expected 302 from / before install, got $code"
location="$(curl -s -o /dev/null -w '%{redirect_url}' -H "Host: localhost:${PORT}" "$BASE/")"
[[ "$location" == *"/wp-admin/install.php"* ]] || fail "expected redirect to the installer, got '$location'"
body="$(curl -fsS -H "Host: localhost:${PORT}" "$BASE/wp-admin/install.php")"
[[ "$body" == *"WordPress"* ]] || fail "installer page does not mention WordPress"
[ "$(http_code "$BASE/wp-admin/install.php")" = "200" ] || fail "installer did not return 200"

step "security headers and blocked paths"
headers="$(curl -sS -D - -o /dev/null -H "Host: localhost:${PORT}" "$BASE/wp-admin/install.php")"
for h in x-content-type-options x-frame-options referrer-policy permissions-policy; do
  grep -qi "^$h:" <<< "$headers" || fail "missing header $h"
done
grep -qi '^x-powered-by:' <<< "$headers" && fail "X-Powered-By leaked"
grep -qi '^server: nginx/' <<< "$headers" && fail "nginx version leaked"
for path in /wp-config.php /.env /xmlrpc.php /wp-content/uploads/evil.php /readme.html; do
  c="$(http_code "$BASE$path")"
  [ "$c" = "403" ] || [ "$c" = "404" ] || fail "$path returned $c (expected 403/404)"
done

step "install WordPress with wp-cli"
admin_pw="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
"$WPSTACK" wp core install --url="http://localhost:${PORT}" --title="Smoke Test" \
  --admin_user=smoke --admin_password="$admin_pw" --admin_email=smoke@example.com --skip-email
[ "$(http_code "$BASE/")" = "200" ] || fail "front page did not return 200 after install"

step "fastcgi cache"
hit=""
for _ in 1 2 3 4 5; do
  status="$(curl -sS -D - -o /dev/null -H "Host: localhost:${PORT}" "$BASE/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{print $2}')"
  if [ "$status" = "HIT" ]; then hit=1; break; fi
  sleep 1
done
[ -n "$hit" ] || fail "front page never served from the fastcgi cache"
admin_cache="$(curl -sS -D - -o /dev/null -H "Host: localhost:${PORT}" "$BASE/wp-login.php" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache-status"{print $2}')"
[ "$admin_cache" = "BYPASS" ] || fail "wp-login.php cache status was '$admin_cache' (expected BYPASS)"

step "php runtime"
[ "$("$WPSTACK" wp eval 'echo extension_loaded("redis") ? "yes" : "no";')" = "yes" ] || fail "redis extension missing"
[ "$("$WPSTACK" wp eval 'echo (int) ini_get("opcache.enable");')" = "1" ] || fail "opcache disabled"
[ "$("$WPSTACK" wp eval 'echo DISABLE_WP_CRON ? "1" : "0";')" = "1" ] || fail "WP-Cron not disabled"
for ext in gd intl mysqli zip exif imagick; do
  [ "$("$WPSTACK" wp eval "echo extension_loaded('$ext') ? 'yes' : 'no';")" = "yes" ] || fail "extension $ext missing"
done
"$WPSTACK" wp plugin install redis-cache --activate
"$WPSTACK" wp redis enable
"$WPSTACK" wp redis status | grep -qi 'Status: Connected' || fail "redis object cache not connected"

step "hardening"
uid="$(docker compose exec -T php id -u | tr -d '\r')"
[ "$uid" = "82" ] || fail "php runs as uid $uid (expected 82)"
# `docker port` lists only host-published bindings; an internal-only container prints nothing.
db_ports="$(docker port "$(docker compose ps -q db)" 2>/dev/null || true)"
[ -z "$db_ports" ] || fail "database port is published: $db_ports"
if docker compose port redis 6379 >/dev/null 2>&1; then fail "redis port is published"; fi
for svc in nginx php cron redis backup; do
  ro="$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$(docker compose ps -q "$svc")")"
  [ "$ro" = "true" ] || fail "$svc root filesystem is not read-only"
done

step "cron container"
for i in $(seq 1 30); do
  docker compose exec -T cron wp-cron-loop --health && break
  [ "$i" -eq 30 ] && fail "cron heartbeat missing"
  sleep 5
done

step "backup and restore"
name="$("$WPSTACK" backup | tail -n 1)"
[[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "unexpected backup name '$name'"
"$WPSTACK" backups | grep -qx "$name" || fail "backup $name not listed"
"$WPSTACK" wp option update blogname "Changed After Backup"
"$WPSTACK" restore "$name" --yes
for i in $(seq 1 30); do
  "$WPSTACK" healthcheck >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && fail "stack unhealthy after restore"
  sleep 5
done
[ "$("$WPSTACK" wp option get blogname)" = "Smoke Test" ] || fail "restore did not bring back the database"

step "all smoke checks passed"
