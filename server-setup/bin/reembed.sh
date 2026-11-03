#!/usr/bin/env bash
# One-time v1.1.0 migration: whole-bank export/import regenerates embeddings.
# Usage: bin/reembed.sh [--yes] (default is a read-only plan).
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
HS="$CONFIG_DIR/bin/hs"
YES=0
case "${1:-}" in
  '') ;;
  --yes) YES=1 ;;
  *) echo "usage: bin/reembed.sh [--yes]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: bin/reembed.sh [--yes]" >&2; exit 2; }

DB_USER="$(env_get "$CONFIG_DIR/base.env" HINDSIGHT_DB_USER)"
DB_NAME="$(env_get "$CONFIG_DIR/base.env" HINDSIGHT_DB_NAME)"
DB_USER="${DB_USER:-hindsight_user}"
DB_NAME="${DB_NAME:-hindsight_db}"
[[ "$DB_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ && "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] \
  || { echo "reembed: database name/user must be simple SQL identifiers" >&2; exit 1; }
[ "$(env_get "$CONFIG_DIR/base.env" HINDSIGHT_API_EMBEDDINGS_PROVIDER)" = openai ] \
  || { echo "reembed: base.env must select openai embeddings" >&2; exit 1; }
[ "$(env_get "$CONFIG_DIR/base.env" HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL)" = text-embedding-3-small ] \
  || { echo "reembed: this script verifies text-embedding-3-small (1536 dimensions) only" >&2; exit 1; }
if [ "$YES" = 0 ]; then
  cat <<TXT
DRY RUN — no state changes. bin/reembed.sh --yes will:
  1. Run bin/backup.sh pre-embeddings before any database write.
  2. Stop hindsight; export each bank to a temporary archive.
  3. Rename $DB_NAME to a retained pre-switch database; create a fresh $DB_NAME.
  4. Import every bank (regenerating embeddings), verify each bank's unit count
     and 1536-dimensional embeddings, then start hindsight.
  5. Keep the old database and pre-switch dump for rollback.
Requires the db container already running, the slim image pulled, and the
separate embeddings key present in secrets.env. Do not accept new writes during migration.
TXT
  exit 0
fi

[ -f "$CONFIG_DIR/secrets.env" ] || { echo "reembed: secrets.env missing" >&2; exit 1; }
env_is_blank "$CONFIG_DIR/secrets.env" HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY \
  && { echo "reembed: add HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY to secrets.env" >&2; exit 1; }
db_id="$("$HS" ps -q db)"
[ -n "$db_id" ] || { echo "reembed: db container must already be running" >&2; exit 1; }

# A successful rerun is a no-op; retain the old database for manual rollback.
current_dim="$("$HS" exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At -c \
  "SELECT atttypmod FROM pg_attribute WHERE attrelid='public.memory_units'::regclass AND attname='embedding'")"
if [ "$current_dim" = 1536 ]; then
  echo "reembed: current memory_units already use 1536 dimensions; no changes"
  exit 0
fi

echo "reembed: backing up before any write"
backup_output="$("$CONFIG_DIR/bin/backup.sh" pre-embeddings)"
backup_path="$(printf '%s\n' "$backup_output" | sed -n 's/^BACKUP_PREFIX=//p' | tail -1)-db.sql.gz"
[ -f "$backup_path" ] || { echo "reembed: backup did not produce a dump" >&2; exit 1; }
echo "reembed: backup ready at $backup_path"

STAMP="$(TZ=Asia/Saigon date +%Y%m%d_%H%M%S)"
OLD_DB="${DB_NAME}_pre_embeddings_${STAMP}"
WORK="$(mktemp -d "$CONFIG_DIR/backups/reembed.XXXXXX")"
chmod 700 "$WORK"
renamed=0
verified=0
cleanup() {
  local code=$?
  trap - EXIT
  if [ "$code" -ne 0 ] && [ "$renamed" = 1 ] && [ "$verified" = 0 ]; then
    echo "reembed: import failed; restoring original database name" >&2
    "$HS" stop hindsight || true
    "$HS" exec -T db dropdb -U "$DB_USER" --force --if-exists "$DB_NAME" || true
    "$HS" exec -T db psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
      -c "ALTER DATABASE \"$OLD_DB\" RENAME TO \"$DB_NAME\"" || true
  fi
  if [ "$code" -ne 0 ]; then
    echo "reembed: archives retained at $WORK; dump at $backup_path. Keep hindsight stopped until checked." >&2
  fi
  exit "$code"
}
trap cleanup EXIT

"$HS" stop hindsight
"$HS" exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At \
  -c 'SELECT bank_id FROM public.banks ORDER BY bank_id' > "$WORK/banks"
mapfile -t banks < "$WORK/banks"
: > "$WORK/counts"
index=0
for bank in "${banks[@]}"; do
  index=$((index + 1))
  archive="/transfer/bank-${index}.zip"
  echo "reembed: exporting bank $index/${#banks[@]}: $bank"
  "$HS" run --rm -T --no-deps -v "$WORK:/transfer" hindsight \
    hindsight-admin export-bank --bank "$bank" --output "$archive" --include-history
  [ -s "$WORK/bank-${index}.zip" ] || { echo "reembed: export missing for $bank" >&2; exit 1; }
done

# Counts are compared after import; the old DB remains intact throughout.
"$HS" exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At -F $'\t' \
  -c 'SELECT bank_id, count(*) FROM public.memory_units GROUP BY bank_id ORDER BY bank_id' > "$WORK/counts"
"$HS" exec -T db psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
  -c "ALTER DATABASE \"$DB_NAME\" RENAME TO \"$OLD_DB\""
renamed=1
"$HS" exec -T db createdb -U "$DB_USER" -O "$DB_USER" "$DB_NAME"
if [ "${#banks[@]}" -eq 0 ]; then
  "$HS" up -d
  "$HS" ready
  bank_count="$("$HS" exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At -c 'SELECT count(*) FROM public.banks')"
  [ "$bank_count" = 0 ] || { echo "reembed: expected an empty bank list" >&2; exit 1; }
  verified=1
  rm -rf "$WORK"
  echo "reembed: empty database migrated. Old DB: $OLD_DB; dump: $backup_path"
  exit 0
fi

index=0
for bank in "${banks[@]}"; do
  index=$((index + 1))
  echo "reembed: importing bank $index/${#banks[@]}: $bank"
  "$HS" run --rm -T --no-deps -v "$WORK:/transfer" hindsight \
    hindsight-admin import-bank --archive "/transfer/bank-${index}.zip" --include-history
done

"$HS" exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At -F $'\t' \
  -c 'SELECT bank_id, count(*) FROM public.memory_units GROUP BY bank_id ORDER BY bank_id' > "$WORK/new-counts"
cmp -s "$WORK/counts" "$WORK/new-counts" \
  || { echo "reembed: bank/unit counts differ; original DB retained" >&2; exit 1; }
bank_count="$("$HS" exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At -c 'SELECT count(*) FROM public.banks')"
[ "$bank_count" = "${#banks[@]}" ] \
  || { echo "reembed: bank count differs; original DB retained" >&2; exit 1; }
bad_vectors="$("$HS" exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At -c \
  'SELECT count(*) FROM public.memory_units WHERE embedding IS NULL OR vector_dims(embedding) <> 1536')"
[ "$bad_vectors" = 0 ] || { echo "reembed: $bad_vectors missing/wrong-dimension embeddings" >&2; exit 1; }
verified=1
"$HS" up -d
"$HS" ready
rm -rf "$WORK"
echo "reembed: verified ${#banks[@]} bank(s), 1536-dimensional embeddings. Old DB: $OLD_DB; dump: $backup_path"
