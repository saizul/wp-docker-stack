# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | yes       |

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

Report privately through GitHub's **Report a vulnerability** button under the repository's Security tab.
Include a description, the impact, steps to reproduce and the affected version or commit. You will get an
acknowledgement within 7 days.

Vulnerabilities in WordPress core, plugins, PHP, nginx, MariaDB or Redis belong with those projects.
Please report issues in how this stack configures or combines them here.

## Operating the stack securely

- Run `make update` regularly to pick up patched images, WordPress core, plugins and themes.
- Keep `HTTP_BIND=127.0.0.1` unless nginx should face the internet directly.
- Keep `./secrets/` at mode 700 and back it up separately from the site backups.
- Use a dedicated R2/S3 API token limited to the backup bucket.
- The Traefik profile reads the Docker socket. Use a socket proxy if that is a concern.
