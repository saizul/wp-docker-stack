#!/usr/bin/env bash
# wp-docker-stack backup tool.
#
#   backup.sh daemon            run a backup every day at BACKUP_TIME (UTC)
#   backup.sh run               take one backup now
#   backup.sh list              list local backups, newest first
#   backup.sh verify <name>     check SHA256SUMS of a backup
#   backup.sh restore <name|latest> [--db-only|--files-only]
#   backup.sh health            healthcheck for the daemon
#
# A backup is a directory /backups/<UTC timestamp>/ containing:
#   db.sql.gz          mariadb-dump of DB_NAME
#   files.tar.gz       /var/www/html (without caches)
#   manifest.txt       metadata
#   SHA256SUMS         checksums of the files above
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
WP_DIR="${WP_DIR:-/var/www/html}"
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_BACKUP_USER:-root}"
DB_ROOT_PASSWORD_FILE="${DB_ROOT_PASSWORD_FILE:-/run/secrets/db_root_password}"
BACKUP_TIME="${BACKUP_TIME:-03:30}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
BACKUP_OFFSITE="${BACKUP_OFFSITE:-none}"
BACKUP_HEARTBEAT="${BACKUP_HEARTBEAT:-/tmp/backup-heartbeat}"
BACKUP_TMP="${BACKUP_TMP:-/tmp}"
NAME_RE='^[0-9]{8}T[0-9]{6}Z$'

log() { printf '%s backup: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# seconds_until HH:MM NOW_EPOCH -> seconds until the next HH:MM (UTC), 1..86400
seconds_until() {
  local hhmm="$1" now="$2" h m target sod diff
  [[ "$hhmm" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { echo "invalid time '$hhmm' (expected HH:MM)" >&2; return 2; }
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  target=$((h * 3600 + m * 60))
  sod=$((now % 86400))
  diff=$(((target - sod + 86400) % 86400))
  [ "$diff" -eq 0 ] && diff=86400
  echo "$diff"
}

valid_name() { [[ "$1" =~ $NAME_RE ]]; }

# list_backups -> names, newest first
list_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  local d
  for d in "$BACKUP_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    d="${d##*/}"
    if valid_name "$d" && [ -f "$BACKUP_DIR/$d/SHA256SUMS" ]; then
      echo "$d"
    fi
  done | sort -r
}

latest_backup() { list_backups | head -n 1; }

resolve_name() {
  local name="${1:-}"
  [ -n "$name" ] || die "backup name required (or 'latest')"
  if [ "$name" = "latest" ]; then
    name="$(latest_backup)"
    [ -n "$name" ] || die "no backups found in $BACKUP_DIR"
  fi
  valid_name "$name" || die "invalid backup name '$name'"
  [ -d "$BACKUP_DIR/$name" ] || die "backup '$name' not found"
  echo "$name"
}

# prune_backups KEEP -> delete all but the newest KEEP backups
prune_backups() {
  local keep="$1" i=0 name
  [[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -ge 1 ] || die "BACKUP_KEEP must be a positive integer"
  while IFS= read -r name; do
    i=$((i + 1))
    if [ "$i" -gt "$keep" ]; then
      log "pruning old backup $name"
      rm -rf -- "${BACKUP_DIR:?}/$name"
    fi
  done < <(list_backups)
}

# Write a client defaults file so the password never appears on a command line.
mysql_defaults() {
  [ -r "$DB_ROOT_PASSWORD_FILE" ] || die "cannot read $DB_ROOT_PASSWORD_FILE"
  local f="$BACKUP_TMP/.wpstack-my.cnf"
  (
    umask 077
    {
      echo "[client]"
      echo "host=$DB_HOST"
      echo "port=$DB_PORT"
      echo "user=$DB_USER"
      printf 'password="%s"\n' "$(tr -d '\r\n' < "$DB_ROOT_PASSWORD_FILE")"
    } > "$f"
  )
  echo "$f"
}

wp_version() {
  local v
  v="$(sed -n "s/^\$wp_version = '\(.*\)';/\1/p" "$WP_DIR/wp-includes/version.php" 2>/dev/null || true)"
  echo "${v:-unknown}"
}

acquire_lock() {
  local lock="$BACKUP_DIR/.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    # Stale lock older than 6 hours?
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +360 2>/dev/null)" ]; then
      log "removing stale lock"
      rmdir "$lock" 2>/dev/null || rm -rf "$lock"
      mkdir "$lock" || die "cannot acquire lock"
    else
      die "another backup is running"
    fi
  fi
  LOCK_DIR="$lock"
}

release_lock() { [ -n "${LOCK_DIR:-}" ] && rmdir "$LOCK_DIR" 2>/dev/null; LOCK_DIR=""; }

offsite_copy() {
  local name="$1"
  case "$BACKUP_OFFSITE" in
    none|"") return 0 ;;
    s3) ;;
    *) die "unknown BACKUP_OFFSITE '$BACKUP_OFFSITE' (none|s3)" ;;
  esac
  [ -n "${S3_BUCKET:-}" ] || die "BACKUP_OFFSITE=s3 needs S3_BUCKET"
  [ -n "${S3_ACCESS_KEY_ID:-}" ] && [ -n "${S3_SECRET_ACCESS_KEY:-}" ] || die "BACKUP_OFFSITE=s3 needs S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY"
  # rclone reads remotes from RCLONE_CONFIG_<NAME>_<OPTION> environment variables.
  export RCLONE_CONFIG_OFFSITE_TYPE=s3
  export RCLONE_CONFIG_OFFSITE_PROVIDER="${S3_PROVIDER:-Other}"
  export RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
  export RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_OFFSITE_REGION="${S3_REGION:-auto}"
  [ -n "${S3_ENDPOINT:-}" ] && export RCLONE_CONFIG_OFFSITE_ENDPOINT="$S3_ENDPOINT"
  export RCLONE_CONFIG_OFFSITE_NO_CHECK_BUCKET=true
  local dest="offsite:${S3_BUCKET}/${S3_PREFIX:+${S3_PREFIX%/}/}${name}"
  log "copying $name to $dest"
  rclone copy --config /dev/null "$BACKUP_DIR/$name" "$dest" --s3-no-check-bucket --retries 3
}

# Globals so the EXIT trap can clean up after the function returns.
BK_TMP=""
BK_DEFAULTS=""

run_backup() {
  local name start
  start="$(date +%s)"
  mkdir -p "$BACKUP_DIR"
  acquire_lock
  trap 'release_lock; rm -rf "${BK_TMP:-}" "${BK_DEFAULTS:-}"' EXIT
  name="${BACKUP_NAME:-$(date -u +%Y%m%dT%H%M%SZ)}"
  valid_name "$name" || die "invalid backup name '$name'"
  [ -e "$BACKUP_DIR/$name" ] && die "backup $name already exists"
  BK_TMP="$BACKUP_DIR/.tmp-$name"
  local tmp="$BK_TMP"
  mkdir -p "$tmp"

  BK_DEFAULTS="$(mysql_defaults)"
  local defaults="$BK_DEFAULTS"
  log "dumping database $DB_NAME"
  mariadb-dump --defaults-extra-file="$defaults" \
    --single-transaction --quick --routines --triggers --events \
    --default-character-set=utf8mb4 --hex-blob --no-tablespaces \
    "$DB_NAME" | gzip -6 > "$tmp/db.sql.gz"
  gzip -t "$tmp/db.sql.gz"

  log "archiving $WP_DIR"
  tar -C "$WP_DIR" \
    --exclude='./wp-content/cache' \
    --exclude='./wp-content/upgrade' \
    --exclude='./wp-content/upgrade-temp-backup' \
    --exclude='./.wpstack-restore' \
    -czf "$tmp/files.tar.gz" .

  {
    echo "name=$name"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "database=$DB_NAME"
    echo "wordpress=$(wp_version)"
    echo "db_bytes=$(wc -c < "$tmp/db.sql.gz" | tr -d ' ')"
    echo "files_bytes=$(wc -c < "$tmp/files.tar.gz" | tr -d ' ')"
    echo "duration_seconds=$(($(date +%s) - start))"
  } > "$tmp/manifest.txt"
  (cd "$tmp" && sha256 db.sql.gz files.tar.gz manifest.txt > SHA256SUMS)

  mv "$tmp" "$BACKUP_DIR/$name"
  BK_TMP=""
  rm -f "$defaults"
  BK_DEFAULTS=""
  log "backup $name complete"
  prune_backups "$BACKUP_KEEP"
  offsite_copy "$name"
  release_lock
  echo "$name"
}

verify_backup() {
  local name
  name="$(resolve_name "${1:-}")"
  (cd "$BACKUP_DIR/$name" && sha256 -c SHA256SUMS >/dev/null) || die "checksum mismatch in $name"
  gzip -t "$BACKUP_DIR/$name/db.sql.gz" || die "db.sql.gz in $name is corrupt"
  log "backup $name verified"
}

restore_db() {
  local name="$1" defaults
  defaults="$(mysql_defaults)"
  log "restoring database $DB_NAME from $name"
  gzip -dc "$BACKUP_DIR/$name/db.sql.gz" | mariadb --defaults-extra-file="$defaults" "$DB_NAME"
  rm -f "$defaults"
}

restore_files() {
  local name="$1" stage="$WP_DIR/.wpstack-restore"
  log "restoring files into $WP_DIR from $name"
  rm -rf "$stage"
  mkdir -p "$stage"
  tar -C "$stage" -xzf "$BACKUP_DIR/$name/files.tar.gz"
  [ -e "$stage/wp-config.php" ] || [ -d "$stage/wp-content" ] || die "archive does not look like a WordPress tree"
  # Replace the current tree only after the archive extracted cleanly.
  find "$WP_DIR" -mindepth 1 -maxdepth 1 ! -name '.wpstack-restore' -exec rm -rf {} +
  find "$stage" -mindepth 1 -maxdepth 1 -exec mv {} "$WP_DIR"/ \;
  rmdir "$stage"
}

restore_backup() {
  local name="" mode="all" arg
  for arg in "$@"; do
    case "$arg" in
      --db-only) mode="db" ;;
      --files-only) mode="files" ;;
      -*) die "unknown option $arg" ;;
      *) name="$arg" ;;
    esac
  done
  name="$(resolve_name "$name")"
  verify_backup "$name"
  case "$mode" in
    all) restore_db "$name"; restore_files "$name" ;;
    db) restore_db "$name" ;;
    files) restore_files "$name" ;;
  esac
  log "restore of $name ($mode) complete"
}

health() {
  [ -s "$BACKUP_HEARTBEAT" ] || { echo "no heartbeat" >&2; return 1; }
  local last now
  last="$(cat "$BACKUP_HEARTBEAT")"
  now="$(date +%s)"
  [ $((now - last)) -le 300 ] || { echo "heartbeat stale ($((now - last))s)" >&2; return 1; }
}

# Run a backup in a fresh process so `set -e` stays in force inside it
# (errexit is ignored in functions called from an `||` list).
run_child() { bash "${BACKUP_SELF:-$0}" run; }

daemon() {
  local wait_s
  seconds_until "$BACKUP_TIME" 0 >/dev/null || exit 2
  trap 'log "stopping"; exit 0' TERM INT
  date +%s > "$BACKUP_HEARTBEAT"
  if [ "${BACKUP_ON_START:-false}" = "true" ]; then
    run_child || log "startup backup failed"
  fi
  while :; do
    wait_s="$(seconds_until "$BACKUP_TIME" "$(date +%s)")"
    log "next backup in ${wait_s}s (at $BACKUP_TIME UTC)"
    while [ "$wait_s" -gt 0 ]; do
      date +%s > "$BACKUP_HEARTBEAT"
      local step=$((wait_s < 60 ? wait_s : 60))
      sleep "$step" &
      wait $! || true
      wait_s=$((wait_s - step))
    done
    date +%s > "$BACKUP_HEARTBEAT"
    run_child || log "scheduled backup failed"
    [ "${BACKUP_DAEMON_ONCE:-0}" = "1" ] && return 0
  done
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    daemon) daemon ;;
    run) run_backup ;;
    list) list_backups ;;
    verify) verify_backup "$@" ;;
    restore) restore_backup "$@" ;;
    health) health ;;
    ""|-h|--help|help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

if [ "${BACKUP_SH_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
