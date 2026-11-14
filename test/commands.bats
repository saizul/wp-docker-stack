#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for the docker-facing commands, using the docker stub in test/stubs.

load helpers/common

setup() {
  setup_stack
  init_stack
}

@test "help and version" {
  run "$WPSTACK" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: bin/wpstack"* ]]
  run "$WPSTACK" version
  [ "$output" = "0.1.0" ]
}

@test "unknown command exits 2" {
  run "$WPSTACK" frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "up builds and starts detached with the project env file" {
  run "$WPSTACK" up
  [ "$status" -eq 0 ]
  grep -q -- "compose --project-directory $TEST_ROOT --env-file $TEST_ROOT/.env -f $TEST_ROOT/docker-compose.yml up -d --build --remove-orphans" "$STUB_LOG"
}

@test "up refuses an invalid configuration" {
  rm "$TEST_ROOT/secrets/db_password"
  run "$WPSTACK" up
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_LOG" ]
}

@test "down, ps, restart and logs pass arguments through" {
  "$WPSTACK" down -v
  "$WPSTACK" ps
  "$WPSTACK" restart nginx
  TAIL=50 "$WPSTACK" logs php
  run calls
  [[ "$output" == *"docker-compose.yml down -v"* ]]
  [[ "$output" == *"docker-compose.yml ps"* ]]
  [[ "$output" == *"docker-compose.yml restart nginx"* ]]
  [[ "$output" == *"docker-compose.yml logs -f --tail=50 php"* ]]
}

@test "wp passes arguments to wp-cli in the php container" {
  run "$WPSTACK" wp plugin list --status=active
  [ "$status" -eq 0 ]
  grep -q -- "exec -T php wp plugin list --status=active" "$STUB_LOG"
}

@test "wp without arguments is a usage error" {
  run "$WPSTACK" wp
  [ "$status" -eq 2 ]
}

@test "backup runs backup.sh in the backup container" {
  run "$WPSTACK" backup
  [ "$status" -eq 0 ]
  grep -q -- "exec -T backup backup.sh run" "$STUB_LOG"
  [[ "$output" == *"20260101T033000Z"* ]]
}

@test "backups lists backups" {
  run "$WPSTACK" backups
  [ "$status" -eq 0 ]
  [[ "$output" == *"20260102T033000Z"* ]]
}

@test "restore requires a name and validates it" {
  run "$WPSTACK" restore
  [ "$status" -eq 2 ]
  run "$WPSTACK" restore '../etc' --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid backup name"* ]]
}

@test "restore refuses to run without confirmation when not interactive" {
  run "$WPSTACK" restore latest < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"--yes"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "restore stops php and cron, restores, then restarts" {
  run "$WPSTACK" restore 20260101T033000Z --db-only --yes
  [ "$status" -eq 0 ]
  run calls
  [[ "${lines[0]}" == *"stop cron php" ]]
  [[ "${lines[1]}" == *"--profile tools run --rm --no-deps restore restore 20260101T033000Z --db-only" ]]
  [[ "${lines[2]}" == *"up -d php cron nginx" ]]
  [[ "$output" == *"exec -T php wp cache flush"* ]]
  [[ "$output" == *"restart nginx"* ]]
}

@test "restore failure still restarts services and exits non-zero" {
  export STUB_FAIL_MATCH="run --rm --no-deps restore"
  run "$WPSTACK" restore latest --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"restore failed"* ]]
  grep -q "up -d php cron nginx" "$STUB_LOG"
}

@test "update backs up, pulls, rebuilds and updates WordPress" {
  run "$WPSTACK" update
  [ "$status" -eq 0 ]
  run calls
  [[ "${lines[0]}" == *"exec -T backup backup.sh run" ]]
  [[ "${lines[1]}" == *"pull --ignore-buildable" ]]
  [[ "${lines[2]}" == *"build --pull" ]]
  [[ "${lines[3]}" == *"up -d --remove-orphans" ]]
  [[ "$output" == *"exec -T php wp core update"* ]]
  [[ "$output" == *"exec -T php wp core update-db"* ]]
  [[ "$output" == *"exec -T php wp plugin update --all"* ]]
  [[ "$output" == *"exec -T php wp theme update --all"* ]]
  [[ "${lines[${#lines[@]}-1]}" == *"restart nginx" ]]
}

@test "update --no-backup --images-only skips backup and wp-cli" {
  run "$WPSTACK" update --no-backup --images-only
  [ "$status" -eq 0 ]
  run ! grep -q "backup.sh run" "$STUB_LOG"
  run ! grep -q "php wp" "$STUB_LOG"
}

@test "update aborts when the pre-update backup fails" {
  export STUB_FAIL_MATCH="backup.sh run"
  run "$WPSTACK" update
  [ "$status" -ne 0 ]
  run ! grep -q "pull" "$STUB_LOG"
}

@test "update skips wp-cli updates when WordPress is not installed" {
  export STUB_FAIL_MATCH="core is-installed"
  run "$WPSTACK" update --no-backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed yet"* ]]
  run ! grep -q "plugin update" "$STUB_LOG"
}

@test "healthcheck passes with healthy services and HTTP 302" {
  printf 'nginx\trunning\thealthy\nphp\trunning\thealthy\ncron\trunning\thealthy\ndb\trunning\thealthy\nredis\trunning\thealthy\nbackup\trunning\thealthy\n' > "$BATS_TEST_TMPDIR/ps"
  export STUB_PS_FILE="$BATS_TEST_TMPDIR/ps" STUB_HTTP_CODE=302
  run "$WPSTACK" healthcheck
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTP 302"* ]]
  [[ "$output" == *"stack is healthy"* ]]
  grep -q "curl .*-H Host: localhost http://127.0.0.1:8080/" "$STUB_LOG"
}

@test "healthcheck fails on HTTP 502" {
  printf 'nginx\trunning\thealthy\nphp\trunning\thealthy\ncron\trunning\thealthy\ndb\trunning\thealthy\nredis\trunning\thealthy\nbackup\trunning\thealthy\n' > "$BATS_TEST_TMPDIR/ps"
  export STUB_PS_FILE="$BATS_TEST_TMPDIR/ps" STUB_HTTP_CODE=502
  run "$WPSTACK" healthcheck
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 502"* ]]
}

@test "healthcheck fails when a service is unhealthy" {
  printf 'nginx\trunning\thealthy\nphp\trunning\tunhealthy\ncron\trunning\thealthy\ndb\trunning\thealthy\nredis\trunning\thealthy\nbackup\trunning\thealthy\n' > "$BATS_TEST_TMPDIR/ps"
  export STUB_PS_FILE="$BATS_TEST_TMPDIR/ps" STUB_HTTP_CODE=200
  run "$WPSTACK" healthcheck
  [ "$status" -eq 1 ]
  [[ "$output" == *"php is unhealthy"* ]]
  [[ "$output" == *"1 check(s) failed"* ]]
}

@test "healthcheck uses the configured port and domain" {
  sed -i.bak -e 's/^HTTP_PORT=.*/HTTP_PORT=9090/' -e 's/^DOMAIN=.*/DOMAIN=shop.example.com/' "$TEST_ROOT/.env"
  : > "$BATS_TEST_TMPDIR/ps"
  export STUB_PS_FILE="$BATS_TEST_TMPDIR/ps"
  run "$WPSTACK" healthcheck
  grep -q "curl .*-H Host: shop.example.com http://127.0.0.1:9090/" "$STUB_LOG"
}
