#!/bin/sh
# bin/hs config must refuse to print anything except --services/--quiet —
# a bare `docker compose config` resolves every secret (POSTGRES_PASSWORD,
# API keys, ...) into its stdout.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin/lib"
cp "$SS/bin/hs" "$TMP/bin/hs"
cp "$SS/bin/lib/env.sh" "$TMP/bin/lib/env.sh"
chmod +x "$TMP/bin/hs"
cat > "$TMP/secrets.env" <<'EOF'
HINDSIGHT_DB_PASSWORD=x
HINDSIGHT_API_LLM_API_KEY=sk-test
HINDSIGHT_API_TENANT_API_KEY=abc123
HINDSIGHT_CP_ACCESS_KEY=y
EOF

# case 1: bare `hs config` (no flags) must be refused before ever calling
# docker (no compose.yaml/version.env/base.env exist in this scratch dir —
# if it tried to call docker, it would fail with a different, unrelated
# error, which this test would catch as a wrong-error-message failure).
if "$TMP/bin/hs" config </dev/null >"$TMP/out1" 2>"$TMP/err1"; then
  echo "expected 'hs config' (no flags) to be refused"
  exit 1
fi
grep -q "secret" "$TMP/err1" || { echo "expected the refusal message to mention secrets:"; cat "$TMP/err1"; exit 1; }

# case 2: an unrelated flag must also be refused
if "$TMP/bin/hs" config --format json </dev/null >"$TMP/out2" 2>"$TMP/err2"; then
  echo "expected 'hs config --format json' to be refused"
  exit 1
fi
grep -q "services\|quiet" "$TMP/err2" || { echo "expected the refusal message to point at --services/--quiet:"; cat "$TMP/err2"; exit 1; }

# case 3: --services mixed with a disallowed flag must still be refused
# (the allowlist check must apply to every argument, not just the first)
if "$TMP/bin/hs" config --services --format json </dev/null >"$TMP/out3" 2>"$TMP/err3"; then
  echo "expected 'hs config --services --format json' to be refused"
  exit 1
fi

echo ok
