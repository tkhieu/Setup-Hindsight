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
    # Dump to a STAGING key outside db/ first, and never promote anything
    # from staging to db/6h/ (the "final" prefix.sql.gz below) without an
    # explicit, checked success of the whole pg_dump|gzip|rcat pipeline —
    # relying on `set -o pipefail` to abort the script via `set -e` alone
    # would still leave a half-uploaded object sitting in staging/ (not
    # harmful on its own: r2:latest resolution only ever reads db/<tier>/,
    # never staging/, and the lifecycle rule expires it in a day — but
    # "never upload/promote a failed dump" should hold without relying on
    # that lifecycle rule as the actual safety net).
    #
    # Promotion is `rclone copyto` (copy, not move): this script never
    # deletes anything, including its own staging objects — that would break
    # the moment R2 Bucket Lock is turned on for db/. The redundant staging
    # copy is left for an R2 lifecycle rule to expire (docs/PLAYBOOK.md §5:
    # staging/ -> 1 day).
    staging="staging/db/$STAMP.sql.gz"
    final="db/6h/$STAMP.sql.gz"
    log "dump -> $staging (staging)"
    if ! "$HS" exec -T db pg_dump -U "$DB_USER" "$DB_NAME" \
        | gzip \
        | "$RCLONE" rcat "$DEST/$staging"; then
      echo "ERROR: pg_dump|gzip|rcat failed — nothing promoted to $final" >&2
      exit 1
    fi

    # Verify by reading the size back from R2 — catches an empty dump that
    # would otherwise exit 0.
    sz="$("$RCLONE" size "$DEST/$staging" --json 2>/dev/null \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')"
    log "staged: $sz bytes"
    if [ "${sz:-0}" -lt "${HINDSIGHT_BACKUP_MIN_BYTES:-2048}" ]; then
      echo "ERROR: only $sz bytes, treating as failed (left at $staging for inspection)" >&2
      exit 1
    fi

    log "copy $staging -> $final  (server-side)"
    "$RCLONE" copyto "$DEST/$staging" "$DEST/$final"
    log "done"
    ;;

  daily)   promote daily   ;;
  weekly)  promote weekly  ;;
  monthly) promote monthly ;;

  *) echo "invalid mode: $MODE" >&2; exit 1 ;;
esac
