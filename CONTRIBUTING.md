# Contributing

Thanks for helping improve wp-docker-stack.

## Development setup

You need Bash, Make and Node.js (for `npx bats`). Docker is only needed for `make compose-validate`, `make hadolint` (when hadolint is not installed) and the smoke test.

```bash
git clone https://github.com/saizul/wp-docker-stack.git
cd wp-docker-stack
make test          # bats suites, docker is stubbed
make shellcheck
make hadolint
make compose-validate
bash test/smoke.sh # full end-to-end run (needs Docker, port 8080)
```

## Guidelines

- Shell scripts must pass `shellcheck` with no findings, and must work on Bash 3.2 (macOS) as well as Bash 5.
- Every change to `bin/wpstack`, `lib/wpstack.sh` or `docker/backup/backup.sh` needs bats coverage.
- Keep services non-root, with read-only root filesystems where possible. Explain any capability you add.
- When changing an image version, check that the tag exists on Docker Hub and update `.env.example`, `docker-compose.yml` defaults, the README and the CHANGELOG.
- Never commit `.env`, `secrets/` or real credentials.

## Pull requests

1. Fork and create a branch from `main`.
2. Make the change with tests.
3. Run `make lint test`.
4. Open a pull request that explains the problem and the fix.

By contributing, you agree that your contributions are licensed under the MIT License.
