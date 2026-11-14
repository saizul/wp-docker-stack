#!/usr/bin/env bash
# Example host cron job: alert when the newest local backup is older than 26 hours.
#   15 * * * * /opt/wp-docker-stack/examples/host-cron-offsite-check.sh || mail -s "backup stale" ops@example.com
set -euo pipefail
cd "$(dirname "$0")/.."
latest="$(./bin/wpstack backups 2>/dev/null | head -n 1)"
[ -n "$latest" ] || { echo "no backups found" >&2; exit 1; }
# Name format: YYYYmmddTHHMMSSZ
ts="${latest:0:4}-${latest:4:2}-${latest:6:2}T${latest:9:2}:${latest:11:2}:${latest:13:2}Z"
if date -u -d "$ts" +%s >/dev/null 2>&1; then
  then_s="$(date -u -d "$ts" +%s)"
else
  then_s="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s)"
fi
age=$(( $(date -u +%s) - then_s ))
if [ "$age" -gt $((26 * 3600)) ]; then
  echo "newest backup $latest is $((age / 3600))h old" >&2
  exit 1
fi
echo "newest backup $latest is $((age / 3600))h old: OK"
