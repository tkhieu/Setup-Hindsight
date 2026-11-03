#!/usr/bin/env bash
# Local backup: Postgres dump, kept on disk. This is the only backup Hindsight
# needs — attachments use the "native" file storage backend (PostgreSQL
# BYTEA, confirmed as the default in hindsight_api/config.py), so there is no
# separate uploads/artifacts volume to back up. The hf_cache volume holds
# only re-downloadable model weights and is never backed up either.
#
# Usage: bin/backup.sh [label]
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
HS="$CONFIG_DIR/bin/hs"
BACKUP_DIR="${HINDSIGHT_BACKUP_DIR:-$CONFIG_DIR/backups}"
LABEL="${1:-manual}"
[[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid label: $LABEL (must match ^[A-Za-z0-9._-]+\$)" >&2; exit 1; }
STAMP="$(TZ=Asia/Saigon date +%Y%m%d-%H%M%S)"
PREFIX="$BACKUP_DIR/${STAMP}-${LABEL}"

set -a
# shellcheck disable=SC1091
. "$CONFIG_DIR/base.env"
set +a

# An empty/truncated dump that still exits 0 is the worst case: it looks
# like a backup but isn't.
MIN_BYTES="${HINDSIGHT_BACKUP_MIN_BYTES:-2048}"
KEEP="${HINDSIGHT_BACKUP_KEEP:-14}"
DB_USER="${HINDSIGHT_DB_USER:-hindsight_user}"
DB_NAME="${HINDSIGHT_DB_NAME:-hindsight_db}"

mkdir -p "$BACKUP_DIR"

echo "==> pg_dump -> ${PREFIX}-db.sql.gz"
# pipefail makes a failing pg_dump abort instead of being swallowed by gzip.
"$HS" exec -T db pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "${PREFIX}-db.sql.gz"

size=$(stat -c%s "${PREFIX}-db.sql.gz")
if [ "$size" -lt "$MIN_BYTES" ]; then
  echo "ERROR: dump is only $size bytes (< $MIN_BYTES). Treating as failed." >&2
  rm -f "${PREFIX}-db.sql.gz"
  exit 1
fi
echo "    ok, $size bytes"

echo "==> keeping last $KEEP"
# Filenames sort correctly by name (STAMP is zero-padded YYYYMMDD-HHMMSS).
find "$BACKUP_DIR" -maxdepth 1 -name '*-db.sql.gz' -printf '%f\n' 2>/dev/null \
  | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
  echo "    removing $old"
  rm -f "$BACKUP_DIR/$old"
done

echo
echo "Backup done: ${PREFIX}-db.sql.gz"
echo "Restore: bin/restore-db.sh ${PREFIX}-db.sql.gz"
# Machine-readable line for callers (bin/upgrade.sh, bin/restore-db.sh) that
# need the exact path of the dump this run produced, without guessing via glob.
echo "BACKUP_PREFIX=$PREFIX"
