#!/bin/sh
# A real (non-drill) restore must work from a fully cold stack: db not
# created/running yet (fresh server, or recovering with nothing up). This
# exercises restore-db.sh's `hs up -d db` step — without it, the pre-restore
# backup's `hs exec -T db pg_dump` has nothing to exec into and the whole
# restore would fail before it even gets to touch the database.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin/lib"
cp "$SS/bin/restore-db.sh" "$TMP/bin/restore-db.sh"
cp "$SS/bin/backup.sh" "$TMP/bin/backup.sh"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/env.sh"
cp "$SS/bin/lib/dump.sh" "$TMP/bin/lib/dump.sh"
chmod +x "$TMP/bin/restore-db.sh" "$TMP/bin/backup.sh"

DB_NAME=hindsight_db
DB_MARKER="$TMP/db_running"
HS_LOG="$TMP/hs.log"
: > "$HS_LOG"
rm -f "$DB_MARKER"  # starts COLD: db is not running yet

# Fake hs simulates a real docker-compose-backed stack closely enough to
# prove the ordering: `exec` into db fails until `up -d db` has run.
cat > "$TMP/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$HS_LOG"
case "\$1" in
  up)
    shift
    for a in "\$@"; do
      if [ "\$a" = "db" ]; then : > "$DB_MARKER"; fi
    done
    exit 0 ;;
  stop|start)
    exit 0 ;;
  ps)
    exit 0 ;;  # nothing running (hindsight was never started in this scenario)
  exec)
    if [ ! -f "$DB_MARKER" ]; then
      echo "fake-hs: ERROR: db is not running (simulated — restore-db.sh should have run 'hs up -d db' first)" >&2
      exit 1
    fi
    shift
    case "\$*" in
      *pg_isready*) exit 0 ;;
      *"SELECT count"*) echo 1 ;;  # trial_import_and_check's core-table check
      *pg_dump*)
        # A REALISTIC size on purpose — this is exactly the case that
        # broke when backup.sh gated on a 2048-byte floor: a freshly
        # initialized, schema-less database (this cold scenario's db was
        # just created by 'up -d db' above, hindsight has never run
        # migrations against it) produces a genuinely tiny dump. Measured
        # against a real pgvector/pg18 container: 720 bytes uncompressed,
        # ~400 gzipped. The content below mirrors that real dump's shape,
        # not an artificially-lowered threshold.
        cat <<'SQL'
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
        exit 0 ;;
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
HINDSIGHT_DB_NAME=$DB_NAME
EOF
: > "$TMP/secrets.env"

# A dump shaped enough to pass bin/lib/dump.sh's structural check (which
# has its own dedicated test, test_dump_validator.sh) — this test is about
# the cold-start ordering, not re-testing the validator.
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
if ! out="$(./bin/restore-db.sh --yes --no-start "$TMP/fixture-dump.sql.gz" </dev/null 2>&1)"; then
  echo "$out"
  echo "restore-db.sh failed against a cold stack (db not running yet)"
  exit 1
fi
echo "$out"

grep -q '^up -d db$' "$HS_LOG" || { echo "expected restore-db.sh to run 'hs up -d db':"; cat "$HS_LOG"; exit 1; }

# The pre-restore backup must have run (and succeeded) AFTER db was
# brought up, proving the ordering, not just that both steps happened.
up_line=$(grep -n '^up -d db$' "$HS_LOG" | head -1 | cut -d: -f1)
dump_line=$(grep -n 'pg_dump' "$HS_LOG" | head -1 | cut -d: -f1)
[ -n "$dump_line" ] || { echo "expected a pg_dump call in the hs log:"; cat "$HS_LOG"; exit 1; }
if [ "$dump_line" -lt "$up_line" ]; then
  echo "pg_dump was called before 'hs up -d db' — ordering is wrong"
  exit 1
fi

# And the backup must run AFTER hindsight is stopped, not before — a
# backup taken while the app is still writable could miss writes made
# between the dump and the actual stop.
stop_line=$(grep -n '^stop hindsight$' "$HS_LOG" | head -1 | cut -d: -f1)
[ -n "$stop_line" ] || { echo "expected a 'stop hindsight' call in the hs log:"; cat "$HS_LOG"; exit 1; }
if [ "$dump_line" -lt "$stop_line" ]; then
  echo "pg_dump was called before 'hs stop hindsight' — ordering is wrong"
  exit 1
fi

printf '%s\n' "$out" | grep -q "Restore OK" || { echo "missing 'Restore OK' in output"; exit 1; }

echo ok
