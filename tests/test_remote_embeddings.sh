#!/bin/sh
set -eu
SS="$(cd "$(dirname "$0")/../server-setup" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin/lib" "$TMP/fake"
cp "$SS/bin/hs" "$SS/bin/bootstrap.sh" "$TMP/bin/"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/"
cp "$SS/secrets.env.example" "$TMP/secrets.env.example"
printf 'HINDSIGHT_API_LLM_PROVIDER=chatgpt\nHINDSIGHT_API_EMBEDDINGS_PROVIDER=openai\n' > "$TMP/base.env"
cat > "$TMP/secrets.env" <<'EOF'
HINDSIGHT_DB_PASSWORD=x
HINDSIGHT_API_TENANT_API_KEY=tenant
HINDSIGHT_CP_ACCESS_KEY=ui
EOF
printf 'HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY=   \n' >> "$TMP/secrets.env"
cat > "$TMP/fake/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *'hindsight-admin chatgpt status'*) printf 'Signed in: yes\nPlan usage enabled: yes\n' ;;
esac
EOF
chmod +x "$TMP/fake/docker"
export PATH="$TMP/fake:$PATH" CALLS="$TMP/calls"
if "$TMP/bin/hs" up -d > "$TMP/out" 2> "$TMP/err"; then exit 1; fi
grep -q HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY "$TMP/err"
[ ! -e "$CALLS" ]
if "$TMP/bin/bootstrap.sh" > "$TMP/out" 2> "$TMP/err"; then exit 1; fi
grep -q HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY "$TMP/err"
if [ -e "$CALLS" ] && grep -q 'up -d$' "$CALLS"; then exit 1; fi

sed -i 's/^HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY=.*/HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY=sk-private-sentinel/' "$TMP/secrets.env"
"$TMP/bin/hs" up -d > "$TMP/out" 2> "$TMP/err"
grep -q 'up -d$' "$CALLS"
if grep -q 'sk-private-sentinel' "$CALLS" "$TMP/out" "$TMP/err"; then exit 1; fi
echo ok
