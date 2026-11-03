#!/bin/sh
set -eu
SS="$(cd "$(dirname "$0")/../server-setup" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin/lib" "$TMP/backups"
cp "$SS/bin/reembed.sh" "$TMP/bin/"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/"
cat > "$TMP/base.env" <<'EOF'
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=hindsight_db
HINDSIGHT_API_EMBEDDINGS_PROVIDER=openai
HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL=text-embedding-3-small
EOF
printf 'HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY=sk-private-sentinel\n' > "$TMP/secrets.env"
cat > "$TMP/bin/backup.sh" <<'EOF'
#!/bin/sh
printf 'backup\n' >> "$CALLS"
: > "$BACKUP_PATH-db.sql.gz"
printf 'BACKUP_PREFIX=%s\n' "$BACKUP_PATH"
EOF
cat > "$TMP/bin/hs" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  'ps -q db') echo db-id ;;
  *'atttypmod'*) echo 384 ;;
  *'SELECT bank_id FROM public.banks'*) echo bank1 ;;
  *'SELECT bank_id, count(*) FROM public.memory_units'*) printf 'bank1\t1\n' ;;
  *'SELECT count(*) FROM public.banks'*) echo 1 ;;
  *'vector_dims(embedding)'*) echo 0 ;;
  *'export-bank'*)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -v) volume="$2"; shift 2 ;;
        --output) archive="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    : > "${volume%:/transfer}/${archive##*/}"
    printf x > "${volume%:/transfer}/${archive##*/}"
    ;;
esac
EOF
chmod +x "$TMP/bin/"*
export CALLS="$TMP/calls" BACKUP_PATH="$TMP/backups/pre"
"$TMP/bin/reembed.sh" > "$TMP/out"
[ ! -e "$CALLS" ]
[ -z "$(find "$TMP/backups" -mindepth 1 -print)" ]
grep -q 'DRY RUN' "$TMP/out"
"$TMP/bin/reembed.sh" --yes > "$TMP/out"
grep -q 'verified 1 bank' "$TMP/out"
python3 - "$CALLS" <<'PY'
import sys
calls=open(sys.argv[1]).read().splitlines()
assert calls.index('backup') < next(i for i, s in enumerate(calls) if 'ALTER DATABASE' in s)
assert next(i for i,s in enumerate(calls) if 'export-bank' in s) < next(i for i,s in enumerate(calls) if 'ALTER DATABASE' in s)
assert 'sk-private-sentinel' not in '\n'.join(calls)
PY
echo ok
