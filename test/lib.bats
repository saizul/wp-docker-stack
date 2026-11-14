#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Unit tests for helpers in lib/wpstack.sh.

load helpers/common

setup() {
  setup_stack
  # shellcheck source=../lib/wpstack.sh
  . "$REPO_ROOT/lib/wpstack.sh"
}

@test "gen_secret returns the requested length" {
  run gen_secret 48
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 48 ]
}

@test "gen_secret refuses short secrets" {
  run gen_secret 8
  [ "$status" -ne 0 ]
}

@test "env_get reads plain, quoted and last values" {
  f="$BATS_TEST_TMPDIR/t.env"
  printf 'A=1\nB="two words"\nC='"'"'x'"'"'\nA=3\n# A=4\nEMPTY=\n' > "$f"
  [ "$(env_get A "$f")" = "3" ]
  [ "$(env_get B "$f")" = "two words" ]
  [ "$(env_get C "$f")" = "x" ]
  [ "$(env_get EMPTY "$f")" = "" ]
  [ "$(env_get MISSING "$f")" = "" ]
  run env_get A "$BATS_TEST_TMPDIR/none.env"
  [ "$status" -eq 1 ]
}

@test "env_set replaces in place and appends new keys" {
  f="$BATS_TEST_TMPDIR/t.env"
  printf '# comment\nA=1\nB=2\n' > "$f"
  env_set A 9 "$f"
  env_set NEW value "$f"
  [ "$(cat "$f")" = $'# comment\nA=9\nB=2\nNEW=value' ]
  [ "$(file_mode "$f")" = "600" ]
}

@test "env_set rejects bad keys" {
  run env_set 'bad-key' 1 "$BATS_TEST_TMPDIR/t.env"
  [ "$status" -ne 0 ]
}

@test "valid_domain" {
  valid_domain example.com
  valid_domain a.b-c.example.co.uk
  valid_domain localhost
  run ! valid_domain "exa mple.com"
  run ! valid_domain "-bad.com"
  run ! valid_domain "nodot"
}

@test "valid_port" {
  valid_port 80
  valid_port 65535
  run ! valid_port 0
  run ! valid_port 70000
  run ! valid_port abc
}

@test "check_services passes when everything is running and healthy" {
  input=$'nginx\trunning\thealthy\nphp\trunning\thealthy\ncron\trunning\thealthy\ndb\trunning\thealthy\nredis\trunning\thealthy\nbackup\trunning\thealthy'
  run check_services <<< "$input"
  [ "$status" -eq 0 ]
}

@test "check_services fails on unhealthy, exited and missing services" {
  input=$'nginx\trunning\tunhealthy\nphp\texited\t\ndb\trunning\thealthy'
  run check_services <<< "$input"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nginx is unhealthy"* ]]
  [[ "$output" == *"php is exited"* ]]
  [[ "$output" == *"redis is not running"* ]]
  [[ "$output" == *"backup is not running"* ]]
}

@test "check_services accepts running services without a healthcheck" {
  input=$'nginx\trunning\t\nphp\trunning\t\ncron\trunning\t\ndb\trunning\t\nredis\trunning\t\nbackup\trunning\t\ncaddy\trunning\t'
  run check_services <<< "$input"
  [ "$status" -eq 0 ]
}
