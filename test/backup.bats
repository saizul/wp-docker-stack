#!/usr/bin/env bats
# Tests for docker/backup/backup.sh with stubbed mariadb-dump, mariadb and rclone.

bats_require_minimum_version 1.5.0
load helpers/common

setup() {
  BACKUP_SH="$REPO_ROOT/docker/backup/backup.sh"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$STUB_LOG"
  export BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  export WP_DIR="$BATS_TEST_TMPDIR/html"
  export BACKUP_TMP="$BATS_TEST_TMPDIR/tmp"
  export BACKUP_HEARTBEAT="$BATS_TEST_TMPDIR/heartbeat"
  export DB_ROOT_PASSWORD_FILE="$BATS_TEST_TMPDIR/root_pw"
  export DB_NAME=wordpress BACKUP_KEEP=3 BACKUP_OFFSITE=none
  mkdir -p "$BACKUP_TMP" "$WP_DIR/wp-content/uploads" "$WP_DIR/wp-content/cache" "$WP_DIR/wp-includes"
  printf 'secret-root-pw\n' > "$DB_ROOT_PASSWORD_FILE"
  printf '<?php\n$wp_version = '"'"'7.1.4'"'"';\n' > "$WP_DIR/wp-includes/version.php"
  echo "<?php // config" > "$WP_DIR/wp-config.php"
  echo "image" > "$WP_DIR/wp-content/uploads/a.jpg"
  echo "cached" > "$WP_DIR/wp-content/cache/page.html"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/mariadb-dump" <<'STUB'
#!/usr/bin/env bash
printf 'mariadb-dump %s\n' "$*" >> "$STUB_LOG"
cnf="${1#--defaults-extra-file=}"
cp "$cnf" "$STUB_LOG.cnf"
[ "${STUB_DUMP_FAIL:-0}" = "1" ] && { echo "dump failed" >&2; exit 2; }
echo "-- MariaDB dump"
echo "CREATE TABLE wp_options (option_id int);"
STUB
  cat > "$STUB_BIN/mariadb" <<'STUB'
#!/usr/bin/env bash
printf 'mariadb %s\n' "$*" >> "$STUB_LOG"
cat > "$STUB_LOG.restored.sql"
STUB
  cat > "$STUB_BIN/rclone" <<'STUB'
#!/usr/bin/env bash
printf 'rclone %s\n' "$*" >> "$STUB_LOG"
env | grep '^RCLONE_CONFIG_OFFSITE_' | sort >> "$STUB_LOG"
STUB
  chmod +x "$STUB_BIN"/*
  export PATH="$STUB_BIN:$PATH"
}

src() {
  # shellcheck source=../docker/backup/backup.sh
  BACKUP_SH_SOURCE_ONLY=1 . "$BACKUP_SH"
}

make_backup() {
  BACKUP_NAME="$1" run bash "$BACKUP_SH" run
  [ "$status" -eq 0 ]
}

@test "seconds_until computes the wait to the next HH:MM" {
  src
  # 2026-01-01T03:00:00Z = 1767236400
  [ "$(seconds_until 03:30 1767236400)" -eq 1800 ]
  [ "$(seconds_until 02:00 1767236400)" -eq 82800 ]
  [ "$(seconds_until 03:00 1767236400)" -eq 86400 ]
  [ "$(seconds_until 00:00 1767225599)" -eq 1 ]
  run seconds_until 24:00 0
  [ "$status" -eq 2 ]
  run seconds_until 3:30 0
  [ "$status" -eq 2 ]
}

@test "run creates a complete, verifiable backup" {
  make_backup 20260101T033000Z
  [ "$output" = "20260101T033000Z" ] || [[ "$output" == *"20260101T033000Z" ]]
  d="$BACKUP_DIR/20260101T033000Z"
  [ -f "$d/db.sql.gz" ] && [ -f "$d/files.tar.gz" ] && [ -f "$d/manifest.txt" ] && [ -f "$d/SHA256SUMS" ]
  gzip -dc "$d/db.sql.gz" | grep -q "CREATE TABLE wp_options"
  grep -qx "wordpress=7.1.4" "$d/manifest.txt"
  grep -qx "database=wordpress" "$d/manifest.txt"
  run bash "$BACKUP_SH" verify 20260101T033000Z
  [ "$status" -eq 0 ]
}

@test "the dump uses a private defaults file, never a password argument" {
  make_backup 20260101T033000Z
  grep -q -- "--single-transaction" "$STUB_LOG"
  run ! grep -q "secret-root-pw" "$STUB_LOG"
  grep -q 'password="secret-root-pw"' "$STUB_LOG.cnf"
  grep -qx 'user=root' "$STUB_LOG.cnf"
  [ ! -e "$BACKUP_TMP/.wpstack-my.cnf" ]
}

@test "the files archive skips caches but keeps uploads and config" {
  make_backup 20260101T033000Z
  list="$(tar -tzf "$BACKUP_DIR/20260101T033000Z/files.tar.gz")"
  [[ "$list" == *"wp-content/uploads/a.jpg"* ]]
  [[ "$list" == *"wp-config.php"* ]]
  [[ "$list" != *"wp-content/cache/page.html"* ]]
}

@test "a failed dump leaves no partial backup and releases the lock" {
  export STUB_DUMP_FAIL=1
  BACKUP_NAME=20260101T033000Z run bash "$BACKUP_SH" run
  [ "$status" -ne 0 ]
  [ ! -e "$BACKUP_DIR/20260101T033000Z" ]
  [ ! -e "$BACKUP_DIR/.tmp-20260101T033000Z" ]
  [ ! -e "$BACKUP_DIR/.lock" ]
  [ ! -e "$BACKUP_TMP/.wpstack-my.cnf" ]
}

@test "a held lock blocks a second backup" {
  mkdir -p "$BACKUP_DIR/.lock"
  BACKUP_NAME=20260101T033000Z run bash "$BACKUP_SH" run
  [ "$status" -ne 0 ]
  [[ "$output" == *"another backup is running"* ]]
}

@test "list shows complete backups newest first and ignores junk" {
  make_backup 20260101T033000Z
  make_backup 20260102T033000Z
  mkdir -p "$BACKUP_DIR/not-a-backup" "$BACKUP_DIR/20260103T033000Z"
  run bash "$BACKUP_SH" list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "20260102T033000Z" ]
  [ "${lines[1]}" = "20260101T033000Z" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "list succeeds when the newest directory is not a backup" {
  make_backup 20260101T033000Z
  mkdir -p "$BACKUP_DIR/zzz"
  run bash "$BACKUP_SH" list
  [ "$status" -eq 0 ]
  [ "$output" = "20260101T033000Z" ]
}

@test "old backups are pruned down to BACKUP_KEEP" {
  for d in 20260101T033000Z 20260102T033000Z 20260103T033000Z 20260104T033000Z 20260105T033000Z; do
    make_backup "$d"
  done
  run bash "$BACKUP_SH" list
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[2]}" = "20260103T033000Z" ]
  [ ! -e "$BACKUP_DIR/20260101T033000Z" ]
}

@test "verify detects tampering" {
  make_backup 20260101T033000Z
  echo "x" >> "$BACKUP_DIR/20260101T033000Z/files.tar.gz"
  run bash "$BACKUP_SH" verify 20260101T033000Z
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
}

@test "restore rejects bad names and missing backups" {
  run bash "$BACKUP_SH" restore '../../etc'
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid backup name"* ]]
  run bash "$BACKUP_SH" restore 20991231T000000Z
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  run bash "$BACKUP_SH" restore latest
  [ "$status" -ne 0 ]
  [[ "$output" == *"no backups found"* ]]
}

@test "restore latest brings back database and files" {
  make_backup 20260101T033000Z
  rm -rf "$WP_DIR/wp-content/uploads/a.jpg"
  echo "new" > "$WP_DIR/stray.txt"
  run bash "$BACKUP_SH" restore latest
  [ "$status" -eq 0 ]
  [ -f "$WP_DIR/wp-content/uploads/a.jpg" ]
  [ ! -e "$WP_DIR/stray.txt" ]
  [ ! -e "$WP_DIR/.wpstack-restore" ]
  grep -q "CREATE TABLE wp_options" "$STUB_LOG.restored.sql"
  grep -q "mariadb --defaults-extra-file=.* wordpress" "$STUB_LOG"
}

@test "restore --db-only leaves files alone" {
  make_backup 20260101T033000Z
  echo "keep" > "$WP_DIR/stray.txt"
  run bash "$BACKUP_SH" restore 20260101T033000Z --db-only
  [ "$status" -eq 0 ]
  [ -f "$WP_DIR/stray.txt" ]
  [ -f "$STUB_LOG.restored.sql" ]
}

@test "restore --files-only does not touch the database" {
  make_backup 20260101T033000Z
  : > "$STUB_LOG"
  run bash "$BACKUP_SH" restore 20260101T033000Z --files-only
  [ "$status" -eq 0 ]
  run ! grep -q "^mariadb " "$STUB_LOG"
}

@test "s3 off-site copy configures rclone through environment variables" {
  export BACKUP_OFFSITE=s3 S3_BUCKET=my-bucket S3_PREFIX=site/ S3_ACCESS_KEY_ID=AKIDEXAMPLE \
    S3_SECRET_ACCESS_KEY=example-secret S3_ENDPOINT=https://acct.r2.cloudflarestorage.com S3_PROVIDER=Cloudflare
  make_backup 20260101T033000Z
  grep -q "rclone copy --config /dev/null $BACKUP_DIR/20260101T033000Z offsite:my-bucket/site/20260101T033000Z" "$STUB_LOG"
  grep -qx "RCLONE_CONFIG_OFFSITE_PROVIDER=Cloudflare" "$STUB_LOG"
  grep -qx "RCLONE_CONFIG_OFFSITE_ENDPOINT=https://acct.r2.cloudflarestorage.com" "$STUB_LOG"
  grep -qx "RCLONE_CONFIG_OFFSITE_TYPE=s3" "$STUB_LOG"
}

@test "s3 off-site copy without credentials fails loudly" {
  export BACKUP_OFFSITE=s3 S3_BUCKET=my-bucket
  BACKUP_NAME=20260101T033000Z run bash "$BACKUP_SH" run
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs S3_ACCESS_KEY_ID"* ]]
}

@test "health checks the heartbeat age" {
  run bash "$BACKUP_SH" health
  [ "$status" -ne 0 ]
  date +%s > "$BACKUP_HEARTBEAT"
  run bash "$BACKUP_SH" health
  [ "$status" -eq 0 ]
  echo $(( $(date +%s) - 1000 )) > "$BACKUP_HEARTBEAT"
  run bash "$BACKUP_SH" health
  [ "$status" -ne 0 ]
}

@test "daemon with BACKUP_ON_START runs a backup and writes a heartbeat" {
  export BACKUP_ON_START=true BACKUP_DAEMON_ONCE=1 BACKUP_SELF="$BACKUP_SH"
  # Next run is 1 second away: pick the minute that is current, which waits ~1 day,
  # so instead start the daemon in the background and stop it after the startup backup.
  bash "$BACKUP_SH" daemon 2>"$BATS_TEST_TMPDIR/daemon.err" &
  pid=$!
  for _ in $(seq 1 50); do
    [ -n "$(bash "$BACKUP_SH" list)" ] && break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" || true
  [ -s "$BACKUP_HEARTBEAT" ]
  [ -n "$(bash "$BACKUP_SH" list)" ]
}

@test "daemon rejects an invalid BACKUP_TIME" {
  export BACKUP_TIME=99:99
  run bash "$BACKUP_SH" daemon
  [ "$status" -eq 2 ]
}

@test "unknown commands fail" {
  run bash "$BACKUP_SH" frobnicate
  [ "$status" -ne 0 ]
  run bash "$BACKUP_SH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup.sh daemon"* ]]
}
