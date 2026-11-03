#!/usr/bin/env bash
# Backup to Cloudflare R2. Called by the hindsight-backup@<mode> systemd
# service (see ../systemd/).
#
#   backup-r2.sh 6h        dump DB -> db/6h/       (every 6h)
#   backup-r2.sh daily     promote newest 6h -> db/daily/
#   backup-r2.sh weekly    promote -> db/weekly/
#   backup-r2.sh monthly   promote -> db/monthly/
#
# This script NEVER deletes. Expiry is R2's job (lifecycle rules), so even a
# compromised server can't erase backup history.
#
# daily/weekly/monthly use `rclone copyto` between two prefixes in the same
# bucket — a server-side operation (no bytes re-downloaded) that also
# guarantees the daily/weekly/monthly copy is a real, consistent snapshot
# rather than a separate dump taken at a slightly different time.
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$CONFIG_DIR"
HS="$CONFIG_DIR/bin/hs"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/dump.sh"
MODE="${1:?usage: backup-r2.sh 6h|daily|weekly|monthly}"

set -a
# shellcheck disable=SC1091
. ./base.env
# shellcheck disable=SC1091
[ -f ./secrets.env ] && . ./secrets.env
set +a

DB_USER="${HINDSIGHT_DB_USER:-hindsight_user}"
DB_NAME="${HINDSIGHT_DB_NAME:-hindsight_db}"

RCLONE="${RCLONE_BIN:-$HOME/.local/bin/rclone}"
[ -x "$RCLONE" ] || { echo "rclone not found at $RCLONE — run bin/install-systemd.sh" >&2; exit 1; }

for v in R2_BUCKET RCLONE_CONFIG_R2_ENDPOINT RCLONE_CONFIG_R2_ACCESS_KEY_ID RCLONE_CONFIG_R2_SECRET_ACCESS_KEY; do
  [ -n "${!v:-}" ] || { echo "missing required var: $v (see secrets.env.example)" >&2; exit 1; }
done
DEST="r2:$R2_BUCKET"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Newest object directly under a prefix (ISO stamp filenames sort correctly).
newest() { "$RCLONE" lsf "$DEST/$1" --files-only --include '*.sql.gz' 2>/dev/null | sort | tail -1; }

promote() {  # promote <dest-prefix>
  local dst="$1" src
  src="$(newest db/6h)"
  [ -n "$src" ] || { echo "no 6h snapshot to promote yet" >&2; exit 1; }
  log "promote db/6h/$src -> db/$dst/$src  (server-side)"
  "$RCLONE" copyto "$DEST/db/6h/$src" "$DEST/db/$dst/$src"
  log "done"
}

case "$MODE" in
  6h)
    # Dump to a LOCAL temp file first and validate it structurally (same
    # check as bin/backup.sh — gzip -t plus the pg_dump completion footer,
    # not a byte-size floor: a freshly-initialized, schema-less database
    # produces a genuinely tiny but complete dump) BEFORE any network
    # upload — not after, via a staging/ prefix and a round-trip read-back
    # of its size. On any failure, nothing is uploaded at all: no object of
    # any kind, in any prefix, not even transiently.
    tmp="$(mktemp)"
    # shellcheck disable=SC2064  # $tmp must expand now — it is fixed above
    trap "rm -f '$tmp'" EXIT

    final="db/6h/$STAMP.sql.gz"
    log "dump -> $tmp (local)"
    if ! "$HS" exec -T db pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$tmp"; then
      echo "ERROR: pg_dump failed — nothing uploaded." >&2
      exit 1
    fi

    assert_valid_pg_dump "$tmp" \
      || { echo "ERROR: dump is corrupt or truncated (missing the pg_dump completion footer) — nothing uploaded." >&2; exit 1; }

    log "upload $tmp -> $final ($(stat -c%s "$tmp") bytes)"
    "$RCLONE" copyto "$tmp" "$DEST/$final"
    log "done"
    ;;

  daily)   promote daily   ;;
  weekly)  promote weekly  ;;
  monthly) promote monthly ;;

  *) echo "invalid mode: $MODE" >&2; exit 1 ;;
esac
