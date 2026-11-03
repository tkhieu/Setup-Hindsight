#!/usr/bin/env bash
# Local backup: Postgres dump, kept on disk. This is the only backup Hindsight
# needs — attachments use the "native" file storage backend (PostgreSQL
# BYTEA, confirmed as the default in hindsight_api/config.py), so there is no
# separate uploads/artifacts volume to back up. The hf_cache volume holds
# only re-downloadable model weights and is never backed up either. The
# chatgpt_credentials volume is excluded from unencrypted backups; re-login
# after server loss (docs/PLAYBOOK.md §4.2).
#
# Usage: bin/backup.sh [label]
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/dump.sh"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/lock.sh"
acquire_ops_lock "$CONFIG_DIR"
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

KEEP="${HINDSIGHT_BACKUP_KEEP:-14}"
DB_USER="${HINDSIGHT_DB_USER:-hindsight_user}"
DB_NAME="${HINDSIGHT_DB_NAME:-hindsight_db}"

mkdir -p "$BACKUP_DIR"

# Write to a .partial name first and only `mv` it into place once pg_dump
# exited 0, gzip -t confirms it isn't corrupt, AND it clears the size
# floor. Without this, `set -e` aborts the script the instant the bare
# pipeline below reports a failure — gzip may already have flushed some
# bytes to the destination by then, and that half-written file would be
# left behind under its FINAL name (never reaching the size check that was
# supposed to catch and remove it), where `keeping last $KEEP` could count
# it as a real backup. The trap below cleans up the partial on ANY exit,
# including that `set -e` abort.
PARTIAL="${PREFIX}-db.sql.gz.partial"
trap 'rm -f "$PARTIAL"' EXIT

echo "==> pg_dump -> ${PREFIX}-db.sql.gz"
if ! "$HS" exec -T db pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$PARTIAL"; then
  echo "ERROR: pg_dump failed — no file left under the final name." >&2
  exit 1
fi

assert_valid_pg_dump "$PARTIAL" \
  || { echo "ERROR: dump is corrupt or truncated (missing the pg_dump completion footer)." >&2; exit 1; }

size=$(stat -c%s "$PARTIAL")
mv -f "$PARTIAL" "${PREFIX}-db.sql.gz"
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
