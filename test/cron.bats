#!/usr/bin/env bats
# Tests for docker/php/bin/wp-cron-loop and php-fpm-healthcheck.

load helpers/common

setup() {
  LOOP="$REPO_ROOT/docker/php/bin/wp-cron-loop"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$STUB_LOG"
  export WP_DIR="$BATS_TEST_TMPDIR/html"
  export WP_CRON_HEARTBEAT="$BATS_TEST_TMPDIR/hb"
  export WP_CRON_ONCE=1
  mkdir -p "$WP_DIR"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/wp" <<'STUB'
#!/usr/bin/env bash
printf 'wp %s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *"core is-installed"*) [ "${STUB_INSTALLED:-1}" = "1" ] ;;
  *"cron event run"*) [ "${STUB_CRON_FAIL:-0}" = "0" ] ;;
esac
STUB
  chmod +x "$STUB_BIN/wp"
  export WP_BIN="$STUB_BIN/wp"
}

@test "runs due events when WordPress is installed" {
  echo "<?php" > "$WP_DIR/wp-config.php"
  run "$LOOP"
  [ "$status" -eq 0 ]
  grep -q "wp --path=$WP_DIR cron event run --due-now --quiet" "$STUB_LOG"
  [ -s "$WP_CRON_HEARTBEAT" ]
}

@test "skips cron before wp-config.php exists" {
  run "$LOOP"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [ -s "$WP_CRON_HEARTBEAT" ]
}

@test "skips cron when WordPress is not installed yet" {
  echo "<?php" > "$WP_DIR/wp-config.php"
  STUB_INSTALLED=0 run "$LOOP"
  [ "$status" -eq 0 ]
  run grep -c "cron event run" "$STUB_LOG"
  [ "$output" = "0" ]
}

@test "a failing cron run is logged but does not stop the loop" {
  echo "<?php" > "$WP_DIR/wp-config.php"
  STUB_CRON_FAIL=1 run "$LOOP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed"* ]]
  [ -s "$WP_CRON_HEARTBEAT" ]
}

@test "health reports missing, fresh and stale heartbeats" {
  run "$LOOP" --health
  [ "$status" -eq 1 ]
  date +%s > "$WP_CRON_HEARTBEAT"
  run "$LOOP" --health
  [ "$status" -eq 0 ]
  echo $(( $(date +%s) - 10000 )) > "$WP_CRON_HEARTBEAT"
  run "$LOOP" --health
  [ "$status" -eq 1 ]
  [[ "$output" == *"old"* ]]
}

@test "rejects a bad interval" {
  WP_CRON_INTERVAL=abc run "$LOOP"
  [ "$status" -eq 2 ]
  WP_CRON_INTERVAL=0 run "$LOOP"
  [ "$status" -eq 2 ]
}

@test "php-fpm healthcheck succeeds only on pong" {
  cat > "$STUB_BIN/cgi-fcgi" <<'STUB'
#!/usr/bin/env bash
printf 'cgi-fcgi %s %s\n' "$*" "$SCRIPT_NAME" >> "$STUB_LOG"
printf 'Content-type: text/plain\r\n\r\n%s' "${STUB_FPM_REPLY:-pong}"
STUB
  chmod +x "$STUB_BIN/cgi-fcgi"
  PATH="$STUB_BIN:$PATH" run "$REPO_ROOT/docker/php/bin/php-fpm-healthcheck"
  [ "$status" -eq 0 ]
  grep -q "cgi-fcgi -bind -connect 127.0.0.1:9000 /fpm-ping" "$STUB_LOG"
  STUB_FPM_REPLY=nope PATH="$STUB_BIN:$PATH" run "$REPO_ROOT/docker/php/bin/php-fpm-healthcheck"
  [ "$status" -eq 1 ]
}
