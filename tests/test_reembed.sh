#!/bin/sh
set -eu
SS="$(cd "$(dirname "$0")/../server-setup" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin/lib" "$TMP/backups"
cp "$SS/bin/reembed.sh" "$TMP/bin/"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/"
cp "$SS/bin/lib/lock.sh" "$TMP/bin/lib/"
cat > "$TMP/base.env" <<'EOF'
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=hindsight_db
HINDSIGHT_API_EMBEDDINGS_PROVIDER=openai
HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL=text-embedding-3-small
EOF
printf 'HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY=sk-private-sentinel\n' > "$TMP/secrets.env"
# Fake backup.sh takes the shared lock exactly like the real one does. Run
# nested under reembed.sh --yes (which already holds it), it must get
# through immediately via the re-entrancy marker instead of deadlocking —
# the tiny timeout makes a real re-flock fail fast instead of hanging.
cat > "$TMP/bin/backup.sh" <<'EOF'
#!/usr/bin/env bash
CONFIG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$CONFIG_DIR/bin/lib/lock.sh"
HINDSIGHT_OPS_LOCK_TIMEOUT=1 acquire_ops_lock "$CONFIG_DIR"
printf 'backup held=%s\n' "${HINDSIGHT_OPS_LOCK_HELD:-}" >> "$CALLS"
: > "$BACKUP_PATH-db.sql.gz"
printf 'BACKUP_PREFIX=%s\n' "$BACKUP_PATH"
EOF
cat > "$TMP/bin/hs" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  'stop hindsight')
    # Optional pause point so the test can probe the lock mid-run.
    if [ -n "${PAUSE_DIR:-}" ]; then
      : > "$PAUSE_DIR/reached"
      n=0
      while [ ! -e "$PAUSE_DIR/go" ] && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n + 1)); done
    fi ;;
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
[ ! -e "$TMP/.ops.lock" ] || { echo "FAIL: dry run created the lock file"; exit 1; }
grep -q 'DRY RUN' "$TMP/out"
"$TMP/bin/reembed.sh" --yes > "$TMP/out"
grep -q 'verified 1 bank' "$TMP/out"
python3 - "$CALLS" <<'PY'
import sys
calls=open(sys.argv[1]).read().splitlines()
assert calls.index('backup held=1') < next(i for i, s in enumerate(calls) if 'ALTER DATABASE' in s)
assert next(i for i,s in enumerate(calls) if 'export-bank' in s) < next(i for i,s in enumerate(calls) if 'ALTER DATABASE' in s)
assert 'sk-private-sentinel' not in '\n'.join(calls)
PY

# reembed.sh --yes holds the shared lock for its whole run: paused at
# `hs stop hindsight` (after the nested backup has finished),
# a concurrent acquirer with a short timeout must FAIL.
PAUSE_DIR="$TMP/pause"
mkdir -p "$PAUSE_DIR"
: > "$CALLS"
PAUSE_DIR="$PAUSE_DIR" "$TMP/bin/reembed.sh" --yes > "$TMP/out2" 2>&1 &
pid=$!
n=0
while [ ! -e "$PAUSE_DIR/reached" ] && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n + 1)); done
[ -e "$PAUSE_DIR/reached" ] || { : > "$PAUSE_DIR/go"; wait "$pid" || true; cat "$TMP/out2"; echo "FAIL: reembed never reached hs stop"; exit 1; }
grep -q '^backup held=1$' "$CALLS" || { : > "$PAUSE_DIR/go"; wait "$pid" || true; echo "FAIL: nested backup did not run under the held lock"; cat "$CALLS"; exit 1; }
# positional parameter is expanded by child bash
# shellcheck disable=SC2016
if env -u HINDSIGHT_OPS_LOCK_HELD HINDSIGHT_OPS_LOCK_TIMEOUT=1 bash -c '. "$1/bin/lib/lock.sh"; acquire_ops_lock "$1"' _ "$TMP" 2>"$TMP/lockerr"; then
  : > "$PAUSE_DIR/go"; wait "$pid" || true
  echo "FAIL: a concurrent acquire_ops_lock succeeded while reembed.sh --yes was mid-run"; exit 1
fi
grep -q 'could not acquire' "$TMP/lockerr" || { : > "$PAUSE_DIR/go"; wait "$pid" || true; cat "$TMP/lockerr"; echo "FAIL: unexpected lock error"; exit 1; }
: > "$PAUSE_DIR/go"
wait "$pid" || { cat "$TMP/out2"; echo "FAIL: paused reembed run did not finish successfully"; exit 1; }
grep -q 'verified 1 bank' "$TMP/out2"
# Released on exit: the lock is free again.
# positional parameter is expanded by child bash
# shellcheck disable=SC2016
env -u HINDSIGHT_OPS_LOCK_HELD HINDSIGHT_OPS_LOCK_TIMEOUT=1 bash -c '. "$1/bin/lib/lock.sh"; acquire_ops_lock "$1"' _ "$TMP" \
  || { echo "FAIL: lock not released after reembed.sh exited"; exit 1; }
echo ok
