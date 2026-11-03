#!/bin/sh
# bin/hs must refuse `up` (and start/run/create) before ever touching
# docker when secrets.env is missing, or when any required secret it
# checks is empty.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin/lib"
cp "$SS/bin/hs" "$TMP/bin/hs"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/env.sh"
chmod +x "$TMP/bin/hs"
printf 'HINDSIGHT_API_LLM_PROVIDER=openai\n' > "$TMP/base.env"

# case 1: secrets.env missing entirely
if "$TMP/bin/hs" up </dev/null >"$TMP/out1" 2>"$TMP/err1"; then
  echo "expected failure when secrets.env is missing"
  exit 1
fi
grep -q "secrets.env" "$TMP/err1" || { echo "expected mention of secrets.env:"; cat "$TMP/err1"; exit 1; }

# case 2: secrets.env present, HINDSIGHT_API_TENANT_API_KEY empty
cat > "$TMP/secrets.env" <<'EOF'
HINDSIGHT_DB_PASSWORD=x
HINDSIGHT_API_LLM_API_KEY=sk-test
HINDSIGHT_API_TENANT_API_KEY=
HINDSIGHT_CP_ACCESS_KEY=y
EOF
if "$TMP/bin/hs" up </dev/null >"$TMP/out2" 2>"$TMP/err2"; then
  echo "expected failure when HINDSIGHT_API_TENANT_API_KEY is empty"
  exit 1
fi
grep -q "HINDSIGHT_API_TENANT_API_KEY" "$TMP/err2" || { echo "expected mention of HINDSIGHT_API_TENANT_API_KEY:"; cat "$TMP/err2"; exit 1; }

# case 3: API key set, OpenAI key empty
cat > "$TMP/secrets.env" <<'EOF'
HINDSIGHT_DB_PASSWORD=x
HINDSIGHT_API_LLM_API_KEY=
HINDSIGHT_API_TENANT_API_KEY=abc123
HINDSIGHT_CP_ACCESS_KEY=y
EOF
if "$TMP/bin/hs" up </dev/null >"$TMP/out3" 2>"$TMP/err3"; then
  echo "expected failure when HINDSIGHT_API_LLM_API_KEY is empty"
  exit 1
fi
grep -q "HINDSIGHT_API_LLM_API_KEY" "$TMP/err3" || { echo "expected mention of HINDSIGHT_API_LLM_API_KEY:"; cat "$TMP/err3"; exit 1; }

# case 4: API key + OpenAI key set, UI access key empty
cat > "$TMP/secrets.env" <<'EOF'
HINDSIGHT_DB_PASSWORD=x
HINDSIGHT_API_LLM_API_KEY=sk-test
HINDSIGHT_API_TENANT_API_KEY=abc123
HINDSIGHT_CP_ACCESS_KEY=
EOF
if "$TMP/bin/hs" up </dev/null >"$TMP/out4" 2>"$TMP/err4"; then
  echo "expected failure when HINDSIGHT_CP_ACCESS_KEY is empty"
  exit 1
fi
grep -q "HINDSIGHT_CP_ACCESS_KEY" "$TMP/err4" || { echo "expected mention of HINDSIGHT_CP_ACCESS_KEY:"; cat "$TMP/err4"; exit 1; }

for key in HINDSIGHT_DB_PASSWORD HINDSIGHT_API_TENANT_API_KEY HINDSIGHT_API_LLM_API_KEY HINDSIGHT_CP_ACCESS_KEY; do
  for format in spaces crlf; do
    cat > "$TMP/secrets.env" <<'EOF'
HINDSIGHT_DB_PASSWORD=x
HINDSIGHT_API_TENANT_API_KEY=tenant
HINDSIGHT_API_LLM_API_KEY=api
HINDSIGHT_CP_ACCESS_KEY=ui
EOF
    if [ "$format" = spaces ]; then
      sed "s/^$key=.*/$key=   /" "$TMP/secrets.env" > "$TMP/blank"
    else
      awk -v key="$key" '{ if (index($0, key "=") == 1) $0 = key "="; printf "%s\r\n", $0 }' "$TMP/secrets.env" > "$TMP/blank"
    fi
    mv "$TMP/blank" "$TMP/secrets.env"
    if "$TMP/bin/hs" up </dev/null >"$TMP/out" 2>"$TMP/err"; then exit 1; fi
    grep -q "$key" "$TMP/err"
  done
done

echo ok
