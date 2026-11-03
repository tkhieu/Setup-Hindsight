#!/bin/sh
# bin/backup-r2.sh: mode routing (6h dumps to a LOCAL temp file, validates
# it, then uploads straight to db/6h/ — no staging/ prefix anymore;
# daily/weekly/monthly promote the newest db/6h/ snapshot to their own
# prefix) and never-delete (no destructive rclone verb is ever called, in
# any mode).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin/lib"
cp "$SS/bin/backup-r2.sh" "$TMP/bin/backup-r2.sh"
cp "$SS/bin/lib/dump.sh" "$TMP/bin/lib/dump.sh"
chmod +x "$TMP/bin/backup-r2.sh"

# Fake hs: only `exec ... pg_dump` is exercised by backup-r2.sh (6h mode).
# Must emit a real pg_dump-shaped completion footer — bin/lib/dump.sh's
# structural check requires it (no byte-size floor anymore: a real dump of
# a schema-less database is only ~400 bytes gzipped).
cat > "$TMP/bin/hs" <<'EOF'
#!/bin/sh
case "$1" in
  exec)
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
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/hs"

cat > "$TMP/base.env" <<'EOF'
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=hindsight_db
R2_BUCKET=test-bucket
RCLONE_CONFIG=/dev/null
RCLONE_CONFIG_R2_TYPE=s3
RCLONE_CONFIG_R2_PROVIDER=Cloudflare
RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
EOF

cat > "$TMP/secrets.env" <<'EOF'
RCLONE_CONFIG_R2_ENDPOINT=http://fake.local
RCLONE_CONFIG_R2_ACCESS_KEY_ID=x
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=y
EOF

RCLONE_LOG="$TMP/rclone.log"
: > "$RCLONE_LOG"
cat > "$TMP/fake-rclone" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RCLONE_LOG"
cmd="\$1"; shift
case "\$cmd" in
  delete|deletefile|purge|rmdirs|move|moveto|rmdir)
    echo "fake-rclone: VIOLATION: destructive command '\$cmd' called" >&2
    exit 2 ;;
  lsf) echo "20260101T000000Z.sql.gz"; exit 0 ;;
  copyto) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/fake-rclone"

export RCLONE_BIN="$TMP/fake-rclone"

cd "$TMP"
./bin/backup-r2.sh 6h </dev/null
./bin/backup-r2.sh daily </dev/null
./bin/backup-r2.sh weekly </dev/null
./bin/backup-r2.sh monthly </dev/null

# 6h: exactly one rclone call, a direct upload straight to db/6h/ — no
# rcat, no staging/ prefix, no separate promote step.
grep -q 'copyto .*db/6h/' "$RCLONE_LOG" || { echo "6h did not upload to db/6h/:"; cat "$RCLONE_LOG"; exit 1; }
if grep -qi 'staging' "$RCLONE_LOG"; then
  echo "backup-r2.sh still touches a staging/ prefix:"
  cat "$RCLONE_LOG"
  exit 1
fi
if grep -q '^rcat' "$RCLONE_LOG"; then
  echo "backup-r2.sh still uses rcat (streaming upload) instead of a local temp file:"
  cat "$RCLONE_LOG"
  exit 1
fi

grep -q '^copyto .*db/6h/.* .*db/daily/' "$RCLONE_LOG" || { echo "daily did not promote db/6h/ -> db/daily/:"; cat "$RCLONE_LOG"; exit 1; }
grep -q '^copyto .*db/6h/.* .*db/weekly/' "$RCLONE_LOG" || { echo "weekly did not promote db/6h/ -> db/weekly/:"; cat "$RCLONE_LOG"; exit 1; }
grep -q '^copyto .*db/6h/.* .*db/monthly/' "$RCLONE_LOG" || { echo "monthly did not promote db/6h/ -> db/monthly/:"; cat "$RCLONE_LOG"; exit 1; }

if grep -qE '^(delete|deletefile|purge|rmdirs|move|moveto|rmdir) ' "$RCLONE_LOG"; then
  echo "backup-r2.sh invoked a destructive rclone command:"
  cat "$RCLONE_LOG"
  exit 1
fi

echo ok
