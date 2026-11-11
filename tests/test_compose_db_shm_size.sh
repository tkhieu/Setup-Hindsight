#!/bin/sh
# Docker's default /dev/shm (64MiB) is NOT enough for the db service: a
# restore (both --drill and the real restore run the identical `psql -f -`
# import into this same container) needs parallel-worker DSM segments
# backed by /dev/shm (dynamic_shared_memory_type=posix), and
# max_parallel_maintenance_workers=2 means a single large CREATE INDEX can
# want ~2x64MB at once — confirmed on the server (2026-11-11): a --drill
# import failed with repeated `could not resize shared memory segment ...
# No space left on device` (docker logs hindsight-db-1) before shm_size was
# set. This locks in that compose.yaml's db service keeps an explicit
# shm_size strictly above the 64MiB default, so a future edit that drops
# it (e.g. a careless merge) is caught here instead of on the next real
# restore. Static parse only — does not invoke docker.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
COMPOSE="$SS/compose.yaml"

# Isolate the `db:` service block: from the "  db:" line up to (not
# including) the next line at the same (2-space) service-name indent.
db_block="$(awk '
  /^  db:$/ { grab=1; print; next }
  grab && /^  [a-zA-Z0-9_-]+:$/ { exit }
  grab { print }
' "$COMPOSE")"

[ -n "$db_block" ] || { echo "could not find a 'db:' service block in $COMPOSE"; exit 1; }

# Exactly 4-space indent only: compose.yaml's "  db:" is 2-space, so a
# direct key of the db service (image/restart/shm_size/...) is 4-space —
# anything deeper (6-space, e.g. a key under db's own `environment:`) is a
# NESTED key, not db's own shm_size, and must not match here.
shm_line="$(printf '%s\n' "$db_block" | grep -E '^    shm_size:' || true)"
[ -n "$shm_line" ] || { echo "db service in compose.yaml has no shm_size as a direct key (Docker's 64MiB default caused a real restore-drill failure — see docs/PLAYBOOK.md §6)"; exit 1; }

# Extract the numeric value and unit, e.g. shm_size: "256m" -> 256 / m.
value="$(printf '%s' "$shm_line" | sed -E 's/^[[:space:]]*shm_size:[[:space:]]*"?([0-9]+)([a-zA-Z]*)"?[[:space:]]*$/\1/')"
unit="$(printf '%s' "$shm_line" | sed -E 's/^[[:space:]]*shm_size:[[:space:]]*"?([0-9]+)([a-zA-Z]*)"?[[:space:]]*$/\2/' | tr '[:upper:]' '[:lower:]')"
[ -n "$value" ] || { echo "could not parse shm_size value from: $shm_line"; exit 1; }

case "$unit" in
  m | mb) bytes=$((value * 1024 * 1024)) ;;
  g | gb) bytes=$((value * 1024 * 1024 * 1024)) ;;
  k | kb) bytes=$((value * 1024)) ;;
  "") bytes="$value" ;;
  *) echo "unrecognized shm_size unit: $unit (from: $shm_line)"; exit 1 ;;
esac

DOCKER_DEFAULT=$((64 * 1024 * 1024))
[ "$bytes" -gt "$DOCKER_DEFAULT" ] || { echo "db shm_size ($bytes bytes) is not above Docker's 64MiB default — this is the exact size that failed a real restore drill"; exit 1; }

# Sanity ceiling, not a hard product requirement: the host has ~5.4GiB RAM
# shared with other services (docs/RUNBOOK.md §0 notes an OOM there) —
# /dev/shm is tmpfs and only costs real memory while filled, but a value
# this large would almost certainly be a typo (e.g. "256g" for "256m").
SANITY_CEILING=$((2 * 1024 * 1024 * 1024))
[ "$bytes" -le "$SANITY_CEILING" ] || { echo "db shm_size ($bytes bytes) looks like a typo — host only has ~5.4GiB RAM"; exit 1; }

echo "ok: db shm_size = $bytes bytes"
