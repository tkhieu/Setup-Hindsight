#!/bin/sh
# Every temp file bin/seed-repo-bank.sh creates (document-listing pages,
# the downloaded transfer ZIP) must be removed on exit, including when the
# script dies partway through discovery -- not just along the happy path.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/server-setup/bin/lib" "$TMP/fakebin" \
  "$TMP/claude-projects" "$TMP/codex-sessions" "$TMP/scratch"
cp "$SS/bin/seed-repo-bank.sh" "$TMP/server-setup/bin/"
cp "$SS/bin/lib/json.sh" "$SS/bin/lib/transcripts.sh" "$TMP/server-setup/bin/lib/"
chmod +x "$TMP/server-setup/bin/seed-repo-bank.sh"

cat > "$TMP/coding-agent.json" <<'EOF'
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"TMPCLEANUP-CANARY","bankId":"user-hieu","autoUpdate":true}
EOF

# The conversation-document listing call (the second discovery GET) fails
# outright -> the script must `die` partway through discovery, after the
# first temp file (the gitlog listing) was already created.
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
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0") printf '{"detail":"boom"}\n500\n' ;;
  *) echo "unexpected call: $method $url" >&2; printf '{}\n599\n' ;;
esac
CURLEOF
chmod +x "$TMP/fakebin/curl"

export PATH="$TMP/fakebin:$PATH"
export HINDSIGHT_CODING_AGENT_CONFIG="$TMP/coding-agent.json"
export HINDSIGHT_SEED_CLAUDE_PROJECTS_DIR="$TMP/claude-projects"
export HINDSIGHT_SEED_CODEX_SESSIONS_DIR="$TMP/codex-sessions"
export HINDSIGHT_SEED_LEDGER_FILE="$TMP/ledger.jsonl"
export TMPDIR="$TMP/scratch"

before="$(find "$TMP/scratch" -type f | wc -l)"
set +e
"$TMP/server-setup/bin/seed-repo-bank.sh" repo --dry-run >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: expected the script to die when document listing fails"; exit 1; }

after="$(find "$TMP/scratch" -type f | wc -l)"
[ "$after" -eq "$before" ] || {
  echo "FAIL: temp files were left behind after a die() mid-discovery:"
  find "$TMP/scratch" -type f
  exit 1
}

echo "ok - temp files are cleaned up even when the script dies mid-discovery"
