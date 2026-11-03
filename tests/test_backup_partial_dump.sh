#!/bin/sh
# When pg_dump fails mid-stream, neither bin/backup.sh nor bin/backup-r2.sh
# (6h mode) must leave anything usable behind: backup.sh must not leave a
# *-db.sql.gz (final OR .partial) file, and backup-r2.sh must never promote
# the (failed) object from staging/ to the readable db/6h/ prefix.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin/lib"
cp "$SS/bin/backup.sh" "$TMP/bin/backup.sh"
cp "$SS/bin/backup-r2.sh" "$TMP/bin/backup-r2.sh"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/env.sh"
cp "$SS/bin/lib/dump.sh" "$TMP/bin/lib/dump.sh"
chmod +x "$TMP/bin/backup.sh" "$TMP/bin/backup-r2.sh"

# Fake hs: `exec ... pg_dump` writes a few bytes (simulating a dump that
# got partway through) then fails — exactly the "died mid-stream" case
# these scripts have to not be fooled by.
cat > "$TMP/bin/hs" <<'EOF'
#!/bin/sh
case "$1" in
  exec) echo "-- partial dump bytes before the failure --"; exit 1 ;;
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

# ---- bin/backup.sh ----------------------------------------------------
cd "$TMP"
if ./bin/backup.sh partial-test </dev/null 2>"$TMP/backup.err"; then
  echo "expected backup.sh to fail when pg_dump fails"
  exit 1
fi
cat "$TMP/backup.err"

leftover="$(find "$TMP/backups" -maxdepth 1 -name '*-db.sql.gz*' 2>/dev/null)"
if [ -n "$leftover" ]; then
  echo "backup.sh left a file behind after a failed pg_dump:"
  echo "$leftover"
  exit 1
fi

# ---- bin/backup-r2.sh 6h -----------------------------------------------
# With the dump-to-local-file-first design, a failed pg_dump means
# backup-r2.sh never touches rclone AT ALL — not rcat, not copyto,
# nothing, in any prefix. The log staying completely EMPTY is the
# assertion, not just "no copyto": there is no longer a staging/ upload
# step that could legitimately run before the failure is noticed.
RCLONE_LOG="$TMP/rclone.log"
: > "$RCLONE_LOG"
cat > "$TMP/fake-rclone" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RCLONE_LOG"
exit 0
EOF
chmod +x "$TMP/fake-rclone"
export RCLONE_BIN="$TMP/fake-rclone"

if ./bin/backup-r2.sh 6h </dev/null 2>"$TMP/backup-r2.err"; then
  echo "expected backup-r2.sh 6h to fail when pg_dump fails"
  exit 1
fi
cat "$TMP/backup-r2.err"

if [ -s "$RCLONE_LOG" ]; then
  echo "backup-r2.sh called rclone at all on a failed dump (expected zero calls):"
  cat "$RCLONE_LOG"
  exit 1
fi

echo ok
