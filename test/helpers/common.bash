# shellcheck shell=bash
# Shared setup for the bats suites.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup_stack() {
  TEST_ROOT="$BATS_TEST_TMPDIR/stack"
  mkdir -p "$TEST_ROOT"
  cp "$REPO_ROOT/.env.example" "$TEST_ROOT/.env.example"
  cp "$REPO_ROOT/docker-compose.yml" "$TEST_ROOT/docker-compose.yml"
  export WPSTACK_ROOT="$TEST_ROOT"
  export WPSTACK_ENV_FILE="$TEST_ROOT/.env"
  export WPSTACK_SECRETS_DIR="$TEST_ROOT/secrets"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$STUB_LOG"
  export DOCKER="$REPO_ROOT/test/stubs/docker"
  export CURL="$REPO_ROOT/test/stubs/curl"
  export NO_COLOR=1
  WPSTACK="$REPO_ROOT/bin/wpstack"
}

# Run init quietly so commands that need a valid config can be tested.
init_stack() {
  "$WPSTACK" init "$@" >/dev/null 2>&1
}

calls() { cat "$STUB_LOG"; }

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}
