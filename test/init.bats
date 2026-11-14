#!/usr/bin/env bats
# Tests for `wpstack init` and configuration validation.

load helpers/common

setup() { setup_stack; }

@test "init creates .env with mode 600 and all secrets" {
  run "$WPSTACK" init
  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/.env" ]
  [ "$(file_mode "$TEST_ROOT/.env")" = "600" ]
  [ "$(file_mode "$TEST_ROOT/secrets")" = "700" ]
  for s in db_password db_root_password redis_password wp_auth_key wp_nonce_salt; do
    [ -s "$TEST_ROOT/secrets/$s" ]
    [ "$(file_mode "$TEST_ROOT/secrets/$s")" = "644" ]
  done
  [ "$(find "$TEST_ROOT/secrets" -type f | wc -l | tr -d ' ')" -eq 11 ]
}

@test "generated secrets have the right length and alphabet" {
  init_stack
  pw="$(cat "$TEST_ROOT/secrets/db_password")"
  salt="$(cat "$TEST_ROOT/secrets/wp_auth_key")"
  [ "${#pw}" -eq 32 ]
  [ "${#salt}" -eq 64 ]
  [[ "$pw" =~ ^[A-Za-z0-9]+$ ]]
  [[ "$salt" =~ ^[A-Za-z0-9]+$ ]]
}

@test "secrets are unique" {
  init_stack
  dupes="$(cat "$TEST_ROOT"/secrets/* | sort | uniq -d | wc -l | tr -d ' ')"
  [ "$dupes" -eq 0 ]
}

@test "init is idempotent and never regenerates secrets" {
  init_stack
  before="$(cat "$TEST_ROOT/secrets/db_password")"
  run "$WPSTACK" init
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping existing"* ]]
  [[ "$output" == *"not regenerated"* ]]
  [ "$(cat "$TEST_ROOT/secrets/db_password")" = "$before" ]
}

@test "init fills a missing secret only" {
  init_stack
  before="$(cat "$TEST_ROOT/secrets/db_password")"
  rm "$TEST_ROOT/secrets/redis_password"
  run "$WPSTACK" init
  [ "$status" -eq 0 ]
  [[ "$output" == *"generated 1 secret"* ]]
  [ -s "$TEST_ROOT/secrets/redis_password" ]
  [ "$(cat "$TEST_ROOT/secrets/db_password")" = "$before" ]
}

@test "init --domain sets DOMAIN and an https WP_URL" {
  run "$WPSTACK" init --domain blog.example.com --email ops@example.com
  [ "$status" -eq 0 ]
  grep -qx 'DOMAIN=blog.example.com' "$TEST_ROOT/.env"
  grep -qx 'WP_URL=https://blog.example.com' "$TEST_ROOT/.env"
  grep -qx 'ACME_EMAIL=ops@example.com' "$TEST_ROOT/.env"
}

@test "init --domain=localhost keeps an http URL with the port" {
  run "$WPSTACK" init --domain=localhost
  [ "$status" -eq 0 ]
  grep -qx 'WP_URL=http://localhost:8080' "$TEST_ROOT/.env"
}

@test "init rejects an invalid domain" {
  run "$WPSTACK" init --domain 'bad domain!'
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a valid domain"* ]]
  [ ! -f "$TEST_ROOT/.env" ]
}

@test "init rejects unknown options" {
  run "$WPSTACK" init --bogus
  [ "$status" -eq 2 ]
}

@test "config validation catches bad values" {
  init_stack
  sed -i.bak -e 's/^HTTP_PORT=.*/HTTP_PORT=99999/' -e 's/^BACKUP_TIME=.*/BACKUP_TIME=25:00/' \
    -e 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=caddy,traefik/' -e 's/^BACKUP_KEEP=.*/BACKUP_KEEP=0/' \
    "$TEST_ROOT/.env"
  run "$WPSTACK" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP_PORT '99999'"* ]]
  [[ "$output" == *"BACKUP_TIME '25:00'"* ]]
  [[ "$output" == *"COMPOSE_PROFILES must be"* ]]
  [[ "$output" == *"BACKUP_KEEP '0'"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "TLS profiles need a public domain and an ACME email" {
  init_stack
  sed -i.bak 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=caddy/' "$TEST_ROOT/.env"
  run "$WPSTACK" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs a public DOMAIN"* ]]
  [[ "$output" == *"needs ACME_EMAIL"* ]]
}

@test "s3 off-site backups need bucket and keys" {
  init_stack
  sed -i.bak 's/^BACKUP_OFFSITE=.*/BACKUP_OFFSITE=s3/' "$TEST_ROOT/.env"
  run "$WPSTACK" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs S3_BUCKET"* ]]
  [[ "$output" == *"needs S3_SECRET_ACCESS_KEY"* ]]
}

@test "missing secrets are reported" {
  init_stack
  rm "$TEST_ROOT/secrets/wp_nonce_salt"
  run "$WPSTACK" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"wp_nonce_salt is missing"* ]]
}

@test "config runs docker compose config when valid" {
  init_stack
  run "$WPSTACK" config
  [ "$status" -eq 0 ]
  grep -q 'compose --project-directory .* config --quiet' "$STUB_LOG"
}
