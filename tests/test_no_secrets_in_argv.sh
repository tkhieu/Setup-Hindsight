#!/bin/sh
# No script may ever put a secret value into another process's argv (every
# local user can read that via `ps`/`/proc/<pid>/cmdline`, unlike stdin or
# the environment block). Fakes record their own argv verbatim; we grep
# those logs for a canary secret value and expect zero matches, even though
# the same canary legitimately flows through stdin (curl -K -) or the
# environment (docker compose run -e NAME, name-only).
#
# Covers: smoke.sh's Authorization header, and restore-db.sh --drill-full's
# Authorization header + the drill container's database password.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"

API_CANARY="CANARY-API-KEY-f00dbeef"
DB_CANARY="CANARY-DB-PASSWORD-cafef00d"

# ======================================================================
# Scenario 1: smoke.sh
# ======================================================================
T1="$(mktemp -d)"

mkdir -p "$T1/bin" "$T1/fakebin"
cp "$SS/bin/smoke.sh" "$T1/bin/smoke.sh"
chmod +x "$T1/bin/smoke.sh"

cat > "$T1/bin/hs" <<'EOF'
#!/bin/sh
case "$1" in
  url) echo "http://127.0.0.1:8888" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T1/bin/hs"

CURL_LOG_1="$T1/curl.log"
: > "$CURL_LOG_1"
cat > "$T1/fakebin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CURL_LOG_1"
cat >/dev/null
url=""
for a in "\$@"; do url="\$a"; done
case "\$url" in
  *memories/recall) printf '{"results":[{"text":"The smoke-test user prefers green tea and lives in Hanoi."}]}\n200\n' ;;
  *memories/list*) printf '{"items":[{"id":"x"}],"total":1,"limit":1,"offset":0}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T1/fakebin/curl"

cat > "$T1/base.env" <<'EOF'
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=hindsight_db
EOF
cat > "$T1/secrets.env" <<EOF
HINDSIGHT_API_TENANT_API_KEY=$API_CANARY
EOF

( cd "$T1" && PATH="$T1/fakebin:$PATH" ./bin/smoke.sh </dev/null )

if grep -qF "$API_CANARY" "$CURL_LOG_1"; then
  echo "smoke.sh: API key canary found in curl's argv:"
  cat "$CURL_LOG_1"
  exit 1
fi
# Sanity: prove the fake curl actually saw the real header (via stdin,
# which this test does not log) by checking the log recorded the expected
# number of requests — a no-op log would also "pass" the grep above for
# the wrong reason (nothing ran at all).
[ "$(wc -l < "$CURL_LOG_1")" -ge 5 ] || { echo "smoke.sh: expected at least 5 curl calls, got:"; cat "$CURL_LOG_1"; exit 1; }

rm -rf "$T1"
echo "ok - smoke.sh"

# ======================================================================
# Scenario 2: restore-db.sh --drill-full
# ======================================================================
T2="$(mktemp -d)"

mkdir -p "$T2/bin/lib" "$T2/fakebin"
cp "$SS/bin/restore-db.sh" "$T2/bin/restore-db.sh"
cp "$SS/bin/lib/env.sh" "$T2/bin/lib/env.sh"
cp "$SS/bin/lib/dump.sh" "$T2/bin/lib/dump.sh"
chmod +x "$T2/bin/restore-db.sh"

HS_LOG_2="$T2/hs.log"
: > "$HS_LOG_2"
cat > "$T2/bin/hs" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$HS_LOG_2"
case "\$1" in
  url) echo "http://127.0.0.1:8888" ;;
  exec)
    shift
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
  *) exit 0 ;;
esac
EOF
chmod +x "$T2/bin/hs"

DOCKER_LOG_2="$T2/docker.log"
: > "$DOCKER_LOG_2"
cat > "$T2/fakebin/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG_2"
for a in "\$@"; do
  if [ "\$a" = "run" ]; then echo "fakecid123"; exit 0; fi
done
exit 0
EOF
chmod +x "$T2/fakebin/docker"

CURL_LOG_2="$T2/curl.log"
: > "$CURL_LOG_2"
cat > "$T2/fakebin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CURL_LOG_2"
cat >/dev/null 2>/dev/null || true
url=""
for a in "\$@"; do url="\$a"; done
case "\$url" in
  */health) exit 0 ;;
  *banks*limit=1) echo '{"total": 3}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T2/fakebin/curl"

cat > "$T2/base.env" <<EOF
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=hindsight_db
EOF
cat > "$T2/secrets.env" <<EOF
HINDSIGHT_DB_PASSWORD=$DB_CANARY
HINDSIGHT_API_TENANT_API_KEY=$API_CANARY
EOF

# A dump shaped enough to pass bin/lib/dump.sh's structural check.
cat > "$T2/fixture-dump.sql" <<'SQL'
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
gzip -c "$T2/fixture-dump.sql" > "$T2/fixture-dump.sql.gz"

( cd "$T2" && PATH="$T2/fakebin:$PATH" HINDSIGHT_DRILL_PORT=18888 \
    ./bin/restore-db.sh --drill --drill-full "$T2/fixture-dump.sql.gz" </dev/null )

for log in "$HS_LOG_2" "$DOCKER_LOG_2" "$CURL_LOG_2"; do
  if grep -qF "$API_CANARY" "$log" || grep -qF "$DB_CANARY" "$log"; then
    echo "restore-db.sh --drill-full: a secret canary was found in argv ($log):"
    cat "$log"
    exit 1
  fi
done

# Confirm the docker compose run call used -e by NAME ONLY, never NAME=value.
grep -q -- '-e HINDSIGHT_API_DATABASE_URL hindsight' "$DOCKER_LOG_2" \
  || { echo "expected '-e HINDSIGHT_API_DATABASE_URL' (name only) in docker's argv:"; cat "$DOCKER_LOG_2"; exit 1; }
if grep -q -- '-e HINDSIGHT_API_DATABASE_URL=' "$DOCKER_LOG_2"; then
  echo "docker compose run was passed the database URL as NAME=value in argv:"
  cat "$DOCKER_LOG_2"
  exit 1
fi

rm -rf "$T2"
echo "ok - restore-db.sh --drill-full"
