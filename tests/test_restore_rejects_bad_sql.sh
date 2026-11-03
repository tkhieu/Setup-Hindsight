#!/bin/sh
# A gzip-valid file that even looks like a complete pg_dump (passes
# bin/lib/dump.sh's structural trailer check) but whose SQL body is
# garbage must be caught by the mandatory trial import — BEFORE
# restore-db.sh's real-restore path stops hindsight or touches the live
# database at all. Previously only gzip -t was checked before the
# destructive steps, so content like this would pass straight through to
# `stop hindsight` + `DROP DATABASE` before psql ever noticed the SQL was
# bad.
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

# Fake hs: the trial import (`psql -f -` into the throwaway restoretest_*
# db) fails whenever the piped SQL contains the marker this fixture uses
# in place of real SQL — simulating a real psql syntax-error rejection
# without needing a live Postgres for this unit test (the real-docker
# equivalent is run separately as part of the PR's e2e gate). Every other
# call just succeeds.
cat > "$TMP/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$HS_LOG"
case "\$1" in
  stop|start)
    echo "fake-hs: VIOLATION: real restore called '\$1' on the app before the trial import passed" >&2
    exit 9 ;;
  up|ps|url)
    exit 0 ;;
  exec)
    shift
    case "\$*" in
      *"DROP DATABASE"*)
        echo "fake-hs: VIOLATION: DROP DATABASE reached before the trial import passed" >&2
        exit 9 ;;
      *pg_isready*) exit 0 ;;
    esac
    has_stdin=0
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "-f" ] && [ "\$a" = "-" ]; then has_stdin=1; fi
      prev="\$a"
    done
    if [ "\$has_stdin" = 1 ]; then
      if grep -q SIMULATED_SQL_SYNTAX_ERROR; then
        exit 1   # psql rejecting genuinely invalid SQL
      fi
      exit 0
    fi
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

# gzip-valid, and shaped enough to pass the structural trailer check
# (valid header/footer) — the garbage is in the BODY, which only an actual
# import attempt can catch.
cat > "$TMP/bad.sql" <<'SQL'
--
-- PostgreSQL database dump
--

\restrict FAKEKEY00000000000000000000000000000000000000000000000000000

SET statement_timeout = 0;
SET client_encoding = 'UTF8';

SIMULATED_SQL_SYNTAX_ERROR THIS IS NOT VALID SQL;

--
-- PostgreSQL database dump complete
--

\unrestrict FAKEKEY00000000000000000000000000000000000000000000000000000
SQL
gzip -c "$TMP/bad.sql" > "$TMP/bad.sql.gz"

cd "$TMP"
if ./bin/restore-db.sh --yes "$TMP/bad.sql.gz" </dev/null 2>"$TMP/err"; then
  echo "expected restore-db.sh to reject a dump whose trial import fails"
  cat "$TMP/err"
  exit 1
fi
cat "$TMP/err"

grep -q "trial import failed" "$TMP/err" || { echo "expected 'trial import failed' in the error output"; exit 1; }
grep -q "untouched" "$TMP/err" || { echo "expected the output to say the live database/app are untouched"; exit 1; }

if grep -q '^stop hindsight$' "$HS_LOG"; then
  echo "restore-db.sh stopped hindsight before/despite the trial import failing:"
  cat "$HS_LOG"
  exit 1
fi
if grep -q "DROP DATABASE" "$HS_LOG"; then
  echo "restore-db.sh reached DROP DATABASE despite the trial import failing:"
  cat "$HS_LOG"
  exit 1
fi
# The live db name legitimately appears in the harmless pg_isready
# readiness probe (it only checks connectivity, never modifies anything) —
# the real assertions are "never stopped the app" and "never DROP
# DATABASE" above. Confirm the only other call naming it was pg_isready.
if grep "$LIVE_DB" "$HS_LOG" | grep -qv pg_isready; then
  echo "the live db name was referenced outside the pg_isready probe despite the trial import failing:"
  grep "$LIVE_DB" "$HS_LOG"
  exit 1
fi

echo ok
