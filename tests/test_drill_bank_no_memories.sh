#!/bin/sh
# bin/restore-db.sh --drill must PASS on a dump with banks=1 but
# memory_units=entities=documents=0 — a bank that has never had anything
# retained into it (PUT /v1/default/banks/{id} creates it immediately,
# with zero memories) is a normal, healthy state, not a truncated dump.
# Only 'banks' is ever compared against HINDSIGHT_DRILL_MIN_ROWS; the
# other three tables are existence-only.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin/lib"
cp "$SS/bin/restore-db.sh" "$TMP/bin/restore-db.sh"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/env.sh"
chmod +x "$TMP/bin/restore-db.sh"

cat > "$TMP/bin/hs" <<'EOF'
#!/bin/sh
case "$1" in
  stop|start) exit 9 ;;  # drill must never touch the app
  exec)
    shift
    has_stdin=0
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-f" ] && [ "$a" = "-" ]; then has_stdin=1; fi
      prev="$a"
    done
    [ "$has_stdin" = 1 ] && cat >/dev/null
    case "$*" in
      *"FROM banks"*) echo 1 ;;          # one bank ...
      *"FROM memory_units"*) echo 0 ;;   # ... with nothing retained into it yet
      *"FROM entities"*) echo 0 ;;
      *"FROM documents"*) echo 0 ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/hs"

cat > "$TMP/base.env" <<'EOF'
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=hindsight_db
EOF
: > "$TMP/secrets.env"

printf -- '-- dummy sql dump\n' | gzip > "$TMP/fixture-dump.sql.gz"

cd "$TMP"
if ! out="$(./bin/restore-db.sh --drill "$TMP/fixture-dump.sql.gz" </dev/null 2>&1)"; then
  echo "$out"
  echo "expected --drill to PASS on banks=1, memory_units=0 (a bank with nothing retained yet is valid, not broken)"
  exit 1
fi
echo "$out"

printf '%s\n' "$out" | grep -q "Drill OK" || { echo "missing 'Drill OK' in output"; exit 1; }
printf '%s\n' "$out" | grep -q "memory_units: 0 rows" || { echo "expected to see memory_units: 0 rows reported"; exit 1; }

echo ok
