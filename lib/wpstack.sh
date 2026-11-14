#!/usr/bin/env bash
# shellcheck shell=bash
# wp-docker-stack command library. Sourced by bin/wpstack and by the bats tests.

WPSTACK_VERSION="0.1.0"

# Secret files that `init` creates: name:length
WPSTACK_SECRETS=(
  db_password:32
  db_root_password:32
  redis_password:32
  wp_auth_key:64
  wp_secure_auth_key:64
  wp_logged_in_key:64
  wp_nonce_key:64
  wp_auth_salt:64
  wp_secure_auth_salt:64
  wp_logged_in_salt:64
  wp_nonce_salt:64
)

# Services that must be running (and healthy, when they define a healthcheck).
WPSTACK_CORE_SERVICES=(nginx php cron db redis backup)

wpstack_root() {
  if [ -n "${WPSTACK_ROOT:-}" ]; then
    printf '%s\n' "$WPSTACK_ROOT"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
}

ROOT="$(wpstack_root)"
ENV_FILE="${WPSTACK_ENV_FILE:-$ROOT/.env}"
SECRETS_DIR="${WPSTACK_SECRETS_DIR:-$ROOT/secrets}"
DOCKER="${DOCKER:-docker}"
CURL="${CURL:-curl}"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi

info() { printf '%s\n' "$*" >&2; }
ok() { printf '%sOK%s   %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit "${2:-1}"; }

# gen_secret LENGTH -> random [A-Za-z0-9] string
gen_secret() {
  local len="${1:-32}" out=""
  [[ "$len" =~ ^[0-9]+$ ]] && [ "$len" -ge 16 ] || die "gen_secret: length must be >= 16"
  while [ "${#out}" -lt "$len" ]; do
    out+="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$len" || true)"
  done
  printf '%s' "${out:0:$len}"
}

# env_get KEY [FILE] -> value of KEY in a dotenv file (last definition wins)
env_get() {
  local key="$1" file="${2:-$ENV_FILE}" line val=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        val="${line#*=}"
        val="${val%$'\r'}"
        if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
        ;;
    esac
  done < "$file"
  printf '%s' "$val"
}

# env_set KEY VALUE [FILE] -> replace or append KEY=VALUE
env_set() {
  local key="$1" value="$2" file="${3:-$ENV_FILE}" tmp found=0 line
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "env_set: invalid key '$key'"
  [[ "$value" != *$'\n'* ]] || die "env_set: value for $key contains a newline"
  tmp="$(mktemp "${file}.XXXXXX")"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" == "$key="* ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
        found=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$file"
  fi
  [ "$found" -eq 1 ] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

valid_domain() {
  [[ "$1" == "localhost" ]] || [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# validate_env -> prints problems, returns 1 if any
validate_env() {
  local errors=0 v
  [ -f "$ENV_FILE" ] || { fail "$ENV_FILE not found (run: make init)"; return 1; }

  v="$(env_get DOMAIN)"
  if [ -z "$v" ] || ! valid_domain "$v"; then fail "DOMAIN '$v' is not a valid hostname"; errors=$((errors + 1)); fi

  v="$(env_get WP_URL)"
  if [ -n "$v" ] && ! [[ "$v" =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]]; then
    fail "WP_URL '$v' must be an http(s) URL"; errors=$((errors + 1))
  fi
  if [[ "$v" == */ ]]; then fail "WP_URL must not end with '/'"; errors=$((errors + 1)); fi

  v="$(env_get HTTP_PORT)"
  if [ -n "$v" ] && ! valid_port "$v"; then fail "HTTP_PORT '$v' is not a port"; errors=$((errors + 1)); fi

  v="$(env_get HTTP_BIND)"
  if [ -n "$v" ] && ! [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    fail "HTTP_BIND '$v' must be an IPv4 address"; errors=$((errors + 1))
  fi

  v="$(env_get COMPOSE_PROFILES)"
  case "$v" in
    ""|caddy|traefik) ;;
    *) fail "COMPOSE_PROFILES must be empty, 'caddy' or 'traefik' (got '$v')"; errors=$((errors + 1)) ;;
  esac
  if [ "$v" = "caddy" ] || [ "$v" = "traefik" ]; then
    if [ "$(env_get DOMAIN)" = "localhost" ]; then fail "the $v profile needs a public DOMAIN"; errors=$((errors + 1)); fi
    if ! [[ "$(env_get ACME_EMAIL)" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
      fail "the $v profile needs ACME_EMAIL"; errors=$((errors + 1))
    fi
  fi

  v="$(env_get BACKUP_TIME)"
  if [ -n "$v" ] && ! [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then fail "BACKUP_TIME '$v' must be HH:MM"; errors=$((errors + 1)); fi
  v="$(env_get BACKUP_KEEP)"
  if [ -n "$v" ] && ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then fail "BACKUP_KEEP '$v' must be a positive integer"; errors=$((errors + 1)); fi

  v="$(env_get BACKUP_OFFSITE)"
  case "$v" in
    ""|none) ;;
    s3)
      local k
      for k in S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
        [ -n "$(env_get "$k")" ] || { fail "BACKUP_OFFSITE=s3 needs $k"; errors=$((errors + 1)); }
      done
      ;;
    *) fail "BACKUP_OFFSITE must be none or s3 (got '$v')"; errors=$((errors + 1)) ;;
  esac

  v="$(env_get COMPOSE_PROJECT_NAME)"
  if [ -n "$v" ] && ! [[ "$v" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    fail "COMPOSE_PROJECT_NAME '$v' must be lowercase letters, digits, '-' or '_'"; errors=$((errors + 1))
  fi

  local entry name
  for entry in "${WPSTACK_SECRETS[@]}"; do
    name="${entry%%:*}"
    [ -s "$SECRETS_DIR/$name" ] || { fail "secret $SECRETS_DIR/$name is missing (run: make init)"; errors=$((errors + 1)); }
  done

  [ "$errors" -eq 0 ]
}

compose() {
  "$DOCKER" compose --project-directory "$ROOT" --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" "$@"
}

require_env() {
  validate_env || die "configuration is invalid; fix .env or run: make init"
}

tty_flags() {
  if [ -t 0 ] && [ -t 1 ]; then return 0; fi
  printf '%s\n' "-T"
}

confirm() {
  local prompt="$1" answer
  if [ "${WPSTACK_ASSUME_YES:-0}" = "1" ]; then return 0; fi
  [ -t 0 ] || die "refusing to continue without confirmation (pass --yes)"
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------- commands ---

cmd_init() {
  local domain="" email="" force_env=0 arg
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --domain) domain="${2:-}"; shift ;;
      --domain=*) domain="${arg#*=}" ;;
      --email) email="${2:-}"; shift ;;
      --email=*) email="${arg#*=}" ;;
      --force-env) force_env=1 ;;
      *) die "init: unknown option '$arg'" 2 ;;
    esac
    shift
  done
  if [ -n "$domain" ] && ! valid_domain "$domain"; then die "init: '$domain' is not a valid domain" 2; fi

  umask 077
  if [ ! -f "$ENV_FILE" ] || [ "$force_env" -eq 1 ]; then
    [ -f "$ROOT/.env.example" ] || die "init: $ROOT/.env.example is missing"
    cp "$ROOT/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "created $ENV_FILE"
  else
    info "keeping existing $ENV_FILE"
  fi
  if [ -n "$domain" ]; then
    env_set DOMAIN "$domain"
    if [ "$domain" = "localhost" ]; then
      local port
      port="$(env_get HTTP_PORT || true)"
      env_set WP_URL "http://localhost:${port:-8080}"
    else
      env_set WP_URL "https://$domain"
    fi
    ok "DOMAIN=$domain"
  fi
  [ -n "$email" ] && env_set ACME_EMAIL "$email"

  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
  local entry name len created=0
  for entry in "${WPSTACK_SECRETS[@]}"; do
    name="${entry%%:*}"
    len="${entry##*:}"
    if [ -s "$SECRETS_DIR/$name" ]; then continue; fi
    gen_secret "$len" > "$SECRETS_DIR/$name"
    created=$((created + 1))
  done
  # Containers run as different users (mysql, redis, www-data) and read the
  # files through bind mounts: the files are world-readable, the directory is not.
  chmod 644 "$SECRETS_DIR"/*
  if [ "$created" -gt 0 ]; then ok "generated $created secret(s) in $SECRETS_DIR"; else info "all secrets already exist (not regenerated)"; fi

  validate_env || die "init finished but the configuration has problems (see above)"
  ok "configuration is valid"
  info ""
  info "Next: make up && make healthcheck"
}

cmd_up() { require_env; compose up -d --build --remove-orphans "$@"; }
cmd_down() { compose down "$@"; }
cmd_restart() { require_env; compose restart "$@"; }
cmd_ps() { compose ps "$@"; }
cmd_logs() { compose logs -f --tail="${TAIL:-200}" "$@"; }
cmd_config() { require_env; compose config --quiet && ok "docker compose configuration is valid"; }

cmd_wp() {
  [ $# -gt 0 ] || die "usage: wpstack wp <wp-cli arguments>" 2
  local flags
  flags="$(tty_flags)"
  # shellcheck disable=SC2086
  compose exec $flags php wp "$@"
}

cmd_backup() {
  require_env
  compose exec -T backup backup.sh run
}

cmd_backups() {
  compose exec -T backup backup.sh list
}

cmd_restore() {
  local name="" assume=0 mode="" arg
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) assume=1 ;;
      --db-only|--files-only) mode="$arg" ;;
      -*) die "restore: unknown option '$arg'" 2 ;;
      *) name="$arg" ;;
    esac
  done
  [ -n "$name" ] || die "usage: wpstack restore <backup-name|latest> [--db-only|--files-only] [--yes]" 2
  if [ "$name" != "latest" ] && ! [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    die "restore: invalid backup name '$name'" 2
  fi
  require_env
  [ "$assume" -eq 1 ] && WPSTACK_ASSUME_YES=1
  confirm "Restore backup '$name'? This overwrites the current site${mode:+ ($mode)}." || die "aborted"

  info "stopping php and cron"
  compose stop cron php
  local status=0
  # shellcheck disable=SC2086
  compose --profile tools run --rm --no-deps restore restore "$name" $mode || status=$?
  info "starting services"
  compose up -d php cron nginx
  if [ "$status" -ne 0 ]; then die "restore failed (exit $status); services restarted with whatever state remains"; fi
  compose exec -T php wp cache flush >/dev/null 2>&1 || true
  compose restart nginx
  ok "restored $name"
}

cmd_update() {
  local backup=1 images_only=0 arg
  for arg in "$@"; do
    case "$arg" in
      --no-backup) backup=0 ;;
      --images-only) images_only=1 ;;
      *) die "update: unknown option '$arg'" 2 ;;
    esac
  done
  require_env
  if [ "$backup" -eq 1 ]; then
    info "taking a backup before updating"
    cmd_backup
  fi
  compose pull --ignore-buildable
  compose build --pull
  compose up -d --remove-orphans
  if [ "$images_only" -eq 0 ]; then
    local wp=(compose exec -T php wp)
    if "${wp[@]}" core is-installed >/dev/null 2>&1; then
      "${wp[@]}" core update || warn "core update failed"
      "${wp[@]}" core update-db || warn "database update failed"
      "${wp[@]}" plugin update --all || warn "plugin updates failed"
      "${wp[@]}" theme update --all || warn "theme updates failed"
      "${wp[@]}" language core update || warn "language updates failed"
    else
      warn "WordPress is not installed yet; skipping core/plugin/theme updates"
    fi
  fi
  compose restart nginx
  ok "update finished"
}

# check_services: reads "service<TAB>state<TAB>health" lines on stdin
check_services() {
  local line svc state health problems=0 seen=" " want
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r svc state health <<< "$line"
    seen+="$svc "
    if [ "$state" != "running" ]; then
      fail "$svc is $state"; problems=$((problems + 1))
    elif [ -n "$health" ] && [ "$health" != "healthy" ]; then
      fail "$svc is $health"; problems=$((problems + 1))
    else
      ok "$svc ${health:-running}"
    fi
  done
  for want in "${WPSTACK_CORE_SERVICES[@]}"; do
    case "$seen" in
      *" $want "*) ;;
      *) fail "$want is not running"; problems=$((problems + 1)) ;;
    esac
  done
  [ "$problems" -eq 0 ]
}

cmd_healthcheck() {
  local problems=0 port host url code
  validate_env || problems=$((problems + 1))
  if ! compose ps --all --format '{{.Service}}{{"\t"}}{{.State}}{{"\t"}}{{.Health}}' | check_services; then
    problems=$((problems + 1))
  fi
  port="$(env_get HTTP_PORT || true)"
  port="${port:-8080}"
  host="$(env_get DOMAIN || true)"
  url="http://127.0.0.1:${port}/"
  code="$("$CURL" -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: ${host:-localhost}" "$url" || true)"
  case "$code" in
    200|301|302) ok "HTTP $code from $url" ;;
    *) fail "HTTP ${code:-no response} from $url"; problems=$((problems + 1)) ;;
  esac
  if [ "$problems" -eq 0 ]; then ok "stack is healthy"; else fail "$problems check(s) failed"; return 1; fi
}

usage() {
  cat <<EOF
wpstack $WPSTACK_VERSION: manage the wp-docker-stack WordPress stack

Usage: bin/wpstack <command> [args]

  init [--domain example.com] [--email you@example.com] [--force-env]
                         create .env and random secrets (never overwrites secrets)
  up [service...]        build and start the stack
  down [args]            stop the stack (add -v to delete volumes: destroys data)
  restart [service...]   restart services
  ps                     list services
  logs [service...]      follow logs (TAIL=200)
  config                 validate .env and docker compose configuration
  wp <args>              run wp-cli in the php container
  backup                 take a backup now
  backups                list backups
  restore <name|latest> [--db-only|--files-only] [--yes]
                         restore a backup (stops php and cron while restoring)
  update [--no-backup] [--images-only]
                         backup, pull/rebuild images, update core/plugins/themes
  healthcheck            check containers and HTTP
  version                print version
EOF
}

main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    init) cmd_init "$@" ;;
    up) cmd_up "$@" ;;
    down) cmd_down "$@" ;;
    restart) cmd_restart "$@" ;;
    ps) cmd_ps "$@" ;;
    logs) cmd_logs "$@" ;;
    config) cmd_config "$@" ;;
    wp) cmd_wp "$@" ;;
    backup) cmd_backup "$@" ;;
    backups) cmd_backups "$@" ;;
    restore) cmd_restore "$@" ;;
    update) cmd_update "$@" ;;
    healthcheck) cmd_healthcheck "$@" ;;
    version|--version|-v) echo "$WPSTACK_VERSION" ;;
    help|--help|-h) usage ;;
    *) usage >&2; die "unknown command '$cmd'" 2 ;;
  esac
}
