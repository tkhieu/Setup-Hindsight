#!/bin/sh
# An inherited `SHELLOPTS=xtrace` (or BASH_ENV turning -x on) must not leak
# the API token: bash re-applies -x from an inherited SHELLOPTS the moment
# the script starts, and xtrace prints each command with its variables
# already expanded -- which would otherwise print the token straight out of
# the `printf '...Bearer %s...' "$AUTH_HEADER_ESCAPED"` calls, defeating the
# `-K -` stdin convention entirely. bin/seed-repo-bank.sh must turn tracing
# back off as its very first statement.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/server-setup/bin/lib" "$TMP/fakebin" \
  "$TMP/claude-projects" "$TMP/codex-sessions"
cp "$SS/bin/seed-repo-bank.sh" "$TMP/server-setup/bin/"
cp "$SS/bin/lib/json.sh" "$SS/bin/lib/transcripts.sh" "$TMP/server-setup/bin/lib/"
chmod +x "$TMP/server-setup/bin/seed-repo-bank.sh"

API_CANARY="CANARY-XTRACE-deadbeef"
cat > "$TMP/coding-agent.json" <<EOF
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"$API_CANARY","bankId":"user-hieu","autoUpdate":true}
EOF

cat > "$TMP/fakebin/curl" <<'CURLEOF'
#!/bin/sh
cat >/dev/null 2>/dev/null || true
url=""; method="GET"; prev=""
for a in "$@"; do
  [ "$prev" = "-X" ] && method="$a"
  url="$a"
  prev="$a"
done
case "$method $url" in
  "GET "*"/banks/coding-agent::repo/stats") printf '{}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?q=gitlog%3Arepo"*) printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0") printf '{"items":[],"total":0,"limit":200,"offset":0}\n200\n' ;;
  *) echo "unexpected call: $method $url" >&2; printf '{}\n599\n' ;;
esac
CURLEOF
chmod +x "$TMP/fakebin/curl"

export PATH="$TMP/fakebin:$PATH"
export HINDSIGHT_CODING_AGENT_CONFIG="$TMP/coding-agent.json"
export HINDSIGHT_SEED_CLAUDE_PROJECTS_DIR="$TMP/claude-projects"
export HINDSIGHT_SEED_CODEX_SESSIONS_DIR="$TMP/codex-sessions"
export HINDSIGHT_SEED_LEDGER_FILE="$TMP/ledger.jsonl"

# SHELLOPTS is how an interactive/CI shell's `set -x` propagates into a
# script bash runs as a separate process -- bash re-applies every option
# named in an inherited SHELLOPTS at startup, before the script's own first
# line runs. bash treats SHELLOPTS itself as read-only, even as a prefix
# assignment, so it has to reach the child's environment via `env` instead
# of a plain `SHELLOPTS=xtrace cmd`.
out="$(env SHELLOPTS=xtrace "$TMP/server-setup/bin/seed-repo-bank.sh" repo --dry-run 2>&1)"

if printf '%s\n' "$out" | grep -qF "$API_CANARY"; then
  echo "$out"
  echo "FAIL: API token canary leaked under an inherited SHELLOPTS=xtrace"
  exit 1
fi

echo "ok - an inherited SHELLOPTS=xtrace never leaks the API token"
