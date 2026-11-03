#!/bin/sh
# If dropping the trial database fails after a successful trial import,
# restore-db.sh must ABORT before any destructive step on the real
# restore path — not warn-and-continue into stop/backup/recreate/restore
# with the live database and app, and not clear its "it's still safe to
# just drop later" bookkeeping as if the drop had actually happened.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin/lib"
cp "$SS/bin/restore-db.sh" "$TMP/bin/restore-db.sh"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/env.sh"
cp "$SS/bin/lib/dump.sh" "$TMP/bin/lib/dump.sh"
cp "$SS/bin/lib/lock.sh" "$TMP/bin/lib/lock.sh"
chmod +x "$TMP/bin/restore-db.sh"

LIVE_DB=hindsight_db
HS_LOG="$TMP/hs.log"
: > "$HS_LOG"

# Fake hs: the trial import succeeds (so we actually reach the dropdb
# call), but dropdb itself always fails — simulating e.g. a transient
# connection issue on the db container right after a successful import.
cat > "$TMP/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$HS_LOG"
case "\$1" in
  stop|start)
    echo "fake-hs: VIOLATION: real restore called '\$1' on the app despite the failed trial-db drop" >&2
    exit 9 ;;
  up|ps|url)
    exit 0 ;;
  exec)
    shift
    case "\$*" in
      *"DROP DATABASE"*)
        echo "fake-hs: VIOLATION: DROP DATABASE reached despite the failed trial-db drop" >&2
        exit 9 ;;
      *dropdb*)
        exit 1 ;;  # the failure under test
      *pg_isready*) exit 0 ;;
      *"SELECT count"*) echo 1 ;;  # trial_import_and_check's core-table check must succeed
    esac
    has_stdin=0
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "-f" ] && [ "\$a" = "-" ]; then has_stdin=1; fi
      prev="\$a"
    done
    [ "\$has_stdin" = 1 ] && cat >/dev/null
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
if ./bin/restore-db.sh --yes "$TMP/fixture-dump.sql.gz" </dev/null 2>"$TMP/err"; then
  echo "expected restore-db.sh to abort (non-zero exit) when dropping the trial db fails"
  cat "$TMP/err"
  exit 1
fi
cat "$TMP/err"

grep -qi "could not drop trial database" "$TMP/err" || { echo "expected a clear 'could not drop trial database' message naming it"; exit 1; }
grep -q "restoretest_" "$TMP/err" || { echo "expected the leftover trial db's name in the error message"; exit 1; }

if grep -q '^stop hindsight$' "$HS_LOG"; then
  echo "restore-db.sh stopped hindsight despite the failed trial-db drop:"
  cat "$HS_LOG"
  exit 1
fi
if grep -q "DROP DATABASE" "$HS_LOG"; then
  echo "restore-db.sh reached DROP DATABASE despite the failed trial-db drop:"
  cat "$HS_LOG"
  exit 1
fi

echo ok
