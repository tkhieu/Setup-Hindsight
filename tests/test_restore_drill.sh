#!/bin/sh
# bin/restore-db.sh --drill must never touch the live database or stop/start
# hindsight: every `hs exec ... db ...` call it makes must target the
# throwaway restoretest_* database, never the configured live db name.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin/lib"
cp "$SS/bin/restore-db.sh" "$TMP/bin/restore-db.sh"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/env.sh"
cp "$SS/bin/lib/dump.sh" "$TMP/bin/lib/dump.sh"
chmod +x "$TMP/bin/restore-db.sh"

LIVE_DB=hindsight_db
HS_LOG="$TMP/hs.log"
: > "$HS_LOG"
cat > "$TMP/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$HS_LOG"
case "\$1" in
  stop|start)
    echo "fake-hs: VIOLATION: drill called '\$1' on the app" >&2
    exit 9 ;;
  ps|url)
    exit 0 ;;
  exec)
    shift
    db=""
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "-d" ]; then db="\$a"; fi
      prev="\$a"
    done
    if [ -z "\$db" ]; then
      for a in "\$@"; do db="\$a"; done
    fi
    if [ "\$db" = "$LIVE_DB" ]; then
      echo "fake-hs: VIOLATION: touched live db '$LIVE_DB'" >&2
      exit 9
    fi
    has_stdin=0
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "-f" ] && [ "\$a" = "-" ]; then has_stdin=1; fi
      prev="\$a"
    done
    [ "\$has_stdin" = 1 ] && cat >/dev/null
    case "\$*" in
      *"SELECT count"*) echo 5 ;;
    esac
    exit 0 ;;
  *)
    exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/hs"

cat > "$TMP/base.env" <<EOF
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=$LIVE_DB
EOF
: > "$TMP/secrets.env"

# A dump shaped enough to pass bin/lib/dump.sh's structural check (which
# has its own dedicated test, test_dump_validator.sh).
cat > "$TMP/fixture-dump.sql" <<'SQL'
--
-- PostgreSQL database dump
--

\restrict FAKEKEY00000000000000000000000000000000000000000000000000000

SET statement_timeout = 0;
SET client_encoding = 'UTF8';

--
-- PostgreSQL database dump complete
--

\unrestrict FAKEKEY00000000000000000000000000000000000000000000000000000
SQL
gzip -c "$TMP/fixture-dump.sql" > "$TMP/fixture-dump.sql.gz"

cd "$TMP"
if out="$(./bin/restore-db.sh --drill "$TMP/fixture-dump.sql.gz" </dev/null 2>&1)"; then
  echo "$out"
else
  status=$?
  echo "$out"
  echo "restore-db.sh --drill exited $status"
  exit 1
fi

printf '%s\n' "$out" | grep -q "Drill OK" || { echo "missing 'Drill OK' in output"; exit 1; }

grep -q '^exec -T db createdb' "$HS_LOG" || { echo "expected a createdb call:"; cat "$HS_LOG"; exit 1; }
grep -q '^exec -T db dropdb' "$HS_LOG" || { echo "expected a dropdb cleanup call:"; cat "$HS_LOG"; exit 1; }

# The live db name must never appear anywhere in any call this script made
# to hs — the strongest simple proof that the drill never touched it.
if grep -q "$LIVE_DB" "$HS_LOG"; then
  echo "drill referenced the live db name in an hs call:"
  cat "$HS_LOG"
  exit 1
fi

echo ok
