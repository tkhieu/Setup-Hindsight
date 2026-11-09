#!/bin/sh
# A real (non-dry-run) bin/seed-repo-bank.sh must refuse to proceed when the
# destination bank coding-agent::<repo> does not exist yet -- it must never
# create a bank itself -- and must make no document-transfer/reflect/retain
# write and append no ledger line.
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

cat > "$TMP/coding-agent.json" <<'EOF'
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"MISSINGDST-CANARY","bankId":"user-hieu","autoUpdate":true}
EOF

FAKE_LOG="$TMP/curl.log"
: > "$FAKE_LOG"
cat > "$TMP/fakebin/curl" <<'CURLEOF'
#!/bin/sh
cat >/dev/null 2>/dev/null || true
url=""; method="GET"; prev=""
for a in "$@"; do
  [ "$prev" = "-X" ] && method="$a"
  url="$a"
  prev="$a"
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_LOG"
case "$method $url" in
  "GET "*"/banks/coding-agent::repo/stats") printf '{}\n404\n' ;;
  "GET "*"/banks/user-hieu/documents?q=gitlog%3Arepo"*) printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0") printf '{"items":[],"total":0,"limit":200,"offset":0}\n200\n' ;;
  *) echo "unexpected call: $method $url" >&2; printf '{}\n599\n' ;;
esac
CURLEOF
chmod +x "$TMP/fakebin/curl"

export PATH="$TMP/fakebin:$PATH"
export FAKE_LOG
export HINDSIGHT_CODING_AGENT_CONFIG="$TMP/coding-agent.json"
export HINDSIGHT_SEED_CLAUDE_PROJECTS_DIR="$TMP/claude-projects"
export HINDSIGHT_SEED_CODEX_SESSIONS_DIR="$TMP/codex-sessions"
export HINDSIGHT_SEED_LEDGER_FILE="$TMP/ledger.jsonl"

set +e
out="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo 2>&1)"
rc=$?
set -e

[ "$rc" -ne 0 ] || { echo "$out"; echo "FAIL: expected a non-zero exit when the destination bank is missing"; exit 1; }
printf '%s\n' "$out" | grep -q 'does not exist yet' || { echo "$out"; echo "FAIL: missing the clear stop message"; exit 1; }
printf '%s\n' "$out" | grep -qi 'open this repo once' || { echo "$out"; echo "FAIL: missing the instruction to open the repo once"; exit 1; }

[ -e "$TMP/ledger.jsonl" ] && { echo "FAIL: must not write the ledger when the destination bank is missing"; exit 1; }
if grep -qE '^(POST|PUT|PATCH|DELETE) ' "$FAKE_LOG"; then
  echo "FAIL: a write call was made despite the missing destination bank:"; cat "$FAKE_LOG"; exit 1
fi

echo "ok - stops with a clear message when the destination bank is missing, writes nothing"
