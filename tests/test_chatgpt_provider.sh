#!/bin/sh
set -eu
SS="$(cd "$(dirname "$0")/../server-setup" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin/lib" "$TMP/fake" "$TMP/chatgpt"
cp "$SS/bin/hs" "$SS/bin/bootstrap.sh" "$SS/bin/chatgpt-login.sh" "$TMP/bin/"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/"
cp "$SS/secrets.env.example" "$TMP/secrets.env.example"
chmod +x "$TMP/bin/"*
printf 'HINDSIGHT_API_LLM_PROVIDER=chatgpt\n' > "$TMP/base.env"
cat > "$TMP/secrets.env" <<'EOF'
HINDSIGHT_DB_PASSWORD=x
HINDSIGHT_API_TENANT_API_KEY=tenant
HINDSIGHT_CP_ACCESS_KEY=ui
HINDSIGHT_API_LLM_API_KEY=
EOF
cat > "$TMP/fake/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *'run --rm -T --no-deps hindsight sh -c'*)
    while [ "$1" != run ]; do shift; done
    shift 7
    HINDSIGHT_API_LLM_CHATGPT_HOME="$CHATGPT_TEST_HOME" sh -c "$1"
    ;;
  *'hindsight-admin chatgpt status'*)
    [ "${STATUS_OK:-0}" = 1 ] || exit 1
    printf 'Plan usage enabled: yes\nSigned in: yes\n'
    ;;
esac
EOF
chmod +x "$TMP/fake/docker"
cat > "$TMP/fake/hindsight-admin" <<'EOF'
#!/bin/sh
case "$*" in
  'chatgpt login --from-file '*)
    [ "$(stat -c %a "$4")" = 600 ] || exit 1
    [ "$(cat "$4")" = credential-private-value ] || exit 1
    [ "${IMPORT_OK:-1}" = 1 ]
    ;;
  'chatgpt status') printf 'Plan usage enabled: yes\nSigned in: yes\n' ;;
esac
EOF
chmod +x "$TMP/fake/hindsight-admin"
export PATH="$TMP/fake:$PATH" CALLS="$TMP/calls" CHATGPT_TEST_HOME="$TMP/chatgpt"

STATUS_OK=1; export STATUS_OK
"$TMP/bin/hs" up -d > "$TMP/out" 2> "$TMP/err"
grep -q 'compose.*up -d' "$CALLS"
grep -q 'run --rm -T --no-deps hindsight hindsight-admin chatgpt status' "$CALLS"

STATUS_OK=0; export STATUS_OK
if "$TMP/bin/hs" up -d > "$TMP/out" 2> "$TMP/err"; then exit 1; fi
grep -q 'bin/chatgpt-login.sh' "$TMP/err"
if "$TMP/bin/bootstrap.sh" > "$TMP/out" 2> "$TMP/err"; then exit 1; fi
grep -q 'bin/chatgpt-login.sh' "$TMP/err"
if grep -q 'HINDSIGHT_API_LLM_API_KEY' "$TMP/err"; then exit 1; fi

printf 'HINDSIGHT_API_LLM_PROVIDER=openai\n' > "$TMP/base.env"
if "$TMP/bin/hs" up -d > "$TMP/out" 2> "$TMP/err"; then exit 1; fi
grep -q 'HINDSIGHT_API_LLM_API_KEY' "$TMP/err"

printf 'HINDSIGHT_API_LLM_PROVIDER=chatgpt\n' > "$TMP/base.env"
STATUS_OK=1; export STATUS_OK
cat > "$TMP/fake/openssl" <<'EOF'
#!/bin/sh
printf 'generated\n'
EOF
cat > "$TMP/fake/curl" <<'EOF'
#!/bin/sh
printf 'healthy'
EOF
chmod +x "$TMP/fake/openssl" "$TMP/fake/curl"
"$TMP/bin/bootstrap.sh" > "$TMP/out" 2> "$TMP/err"
grep -q 'run --rm -T --no-deps hindsight hindsight-admin chatgpt status' "$CALLS"
mv "$TMP/secrets.env" "$TMP/old-secrets.env"
"$TMP/bin/bootstrap.sh" > "$TMP/out" 2> "$TMP/err"
grep -q '^HINDSIGHT_DB_PASSWORD=generated$' "$TMP/secrets.env"
grep -q '^HINDSIGHT_API_TENANT_API_KEY=generated$' "$TMP/secrets.env"
grep -q '^HINDSIGHT_CP_ACCESS_KEY=generated$' "$TMP/secrets.env"
grep -q '^HINDSIGHT_API_LLM_API_KEY=$' "$TMP/secrets.env"

printf 'credential-private-value' | "$TMP/bin/chatgpt-login.sh" > "$TMP/out" 2> "$TMP/err"
if grep -q 'credential-private-value' "$CALLS"; then exit 1; fi
[ -z "$(find "$TMP/chatgpt" -name '.import.*' -print)" ]
IMPORT_OK=0; export IMPORT_OK
if printf 'credential-private-value' | "$TMP/bin/chatgpt-login.sh" > "$TMP/out" 2> "$TMP/err"; then exit 1; fi
[ -z "$(find "$TMP/chatgpt" -name '.import.*' -print)" ]
"$TMP/bin/chatgpt-login.sh" --status > "$TMP/out" 2> "$TMP/err"

echo ok
