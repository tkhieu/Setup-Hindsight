#!/bin/sh
set -eu
SS="$(cd "$(dirname "$0")/../server-setup" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin/lib" "$TMP/fake"
cp "$SS/bin/bootstrap.sh" "$SS/bin/chatgpt-login.sh" "$SS/bin/hs" "$TMP/bin/"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/"
cp "$SS/secrets.env.example" "$TMP/secrets.env.example"
printf 'HINDSIGHT_API_LLM_PROVIDER=openai\n' > "$TMP/base.env"
cat > "$TMP/secrets.env" <<'EOF'
# Preserve this comment and the R2 fields verbatim.
RCLONE_CONFIG_R2_ENDPOINT=https://r2.example.test/path
RCLONE_CONFIG_R2_ACCESS_KEY_ID=r2-id-marker
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=r2-secret-marker
HINDSIGHT_DB_PASSWORD=
HINDSIGHT_API_TENANT_API_KEY=
HINDSIGHT_CP_ACCESS_KEY=
HINDSIGHT_API_LLM_API_KEY=
EOF
cp "$TMP/secrets.env" "$TMP/original"
cat > "$TMP/fake/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
EOF
cat > "$TMP/fake/openssl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
printf '%064d\n' 0
EOF
chmod +x "$TMP/fake/docker" "$TMP/fake/openssl"
export PATH="$TMP/fake:$PATH" CALLS="$TMP/calls"

"$TMP/bin/bootstrap.sh" > "$TMP/out" 2> "$TMP/err"
[ "$(stat -c %a "$TMP/secrets.env")" = 600 ]
awk -F= '/^HINDSIGHT_(DB_PASSWORD|API_TENANT_API_KEY|CP_ACCESS_KEY)=/ { if (length($2) != 64) exit 1; n++ } END { if (n != 3) exit 1 }' "$TMP/secrets.env"
awk '!/^HINDSIGHT_(DB_PASSWORD|API_TENANT_API_KEY|CP_ACCESS_KEY)=/' "$TMP/original" > "$TMP/other-original"
awk '!/^HINDSIGHT_(DB_PASSWORD|API_TENANT_API_KEY|CP_ACCESS_KEY)=/' "$TMP/secrets.env" > "$TMP/other-after"
cmp "$TMP/other-original" "$TMP/other-after"
for key in HINDSIGHT_DB_PASSWORD HINDSIGHT_API_TENANT_API_KEY HINDSIGHT_CP_ACCESS_KEY; do
  grep -q "generated $key" "$TMP/out"
done
awk -F= '
  NR == FNR {
    if ($1 ~ /^HINDSIGHT_(DB_PASSWORD|API_TENANT_API_KEY|CP_ACCESS_KEY)$/) secret[$2] = 1
    next
  }
  {
    for (value in secret) if (value != "" && index($0, value)) exit 1
  }
' "$TMP/secrets.env" "$TMP/out" "$TMP/err" "$CALLS"
cp "$TMP/secrets.env" "$TMP/first-run"
"$TMP/bin/bootstrap.sh" > "$TMP/out" 2> "$TMP/err"
cmp "$TMP/first-run" "$TMP/secrets.env"
grep -q 'all generated secrets already set' "$TMP/out"
[ "$(stat -c %a "$TMP/secrets.env")" = 600 ]

# A missing line is appended; existing generated values stay unchanged.
sed '/^HINDSIGHT_CP_ACCESS_KEY=/d' "$TMP/first-run" > "$TMP/secrets.env"
"$TMP/bin/bootstrap.sh" > "$TMP/out" 2> "$TMP/err"
grep -q 'generated HINDSIGHT_CP_ACCESS_KEY' "$TMP/out"
awk -F= '/^HINDSIGHT_CP_ACCESS_KEY=/ { if (length($2) != 64) exit 1; n++ } END { if (n != 1) exit 1 }' "$TMP/secrets.env"
awk '!/^HINDSIGHT_CP_ACCESS_KEY=/' "$TMP/first-run" > "$TMP/other-original"
awk '!/^HINDSIGHT_CP_ACCESS_KEY=/' "$TMP/secrets.env" > "$TMP/other-after"
cmp "$TMP/other-original" "$TMP/other-after"

# Login must refuse each empty generated key before its first Compose call.
for key in HINDSIGHT_DB_PASSWORD HINDSIGHT_API_TENANT_API_KEY HINDSIGHT_CP_ACCESS_KEY; do
  sed "s/^$key=.*/$key=/" "$TMP/first-run" > "$TMP/secrets.env"
  : > "$CALLS"
  if "$TMP/bin/chatgpt-login.sh" > "$TMP/out" 2> "$TMP/err"; then exit 1; fi
  grep -q 'bin/bootstrap.sh first' "$TMP/err"
  [ ! -s "$CALLS" ]
  if "$TMP/bin/chatgpt-login.sh" --status > "$TMP/out" 2> "$TMP/err"; then exit 1; fi
  grep -q 'bin/bootstrap.sh first' "$TMP/err"
  [ ! -s "$CALLS" ]
done

echo ok
