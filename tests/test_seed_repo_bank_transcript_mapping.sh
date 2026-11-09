#!/bin/sh
# bin/seed-repo-bank.sh must map a conversation document to a repo only
# through a local transcript whose cwd's git main worktree matches the repo
# being seeded: a Claude Code transcript pointing at the target repo, a
# Codex transcript pointing at the target repo, a transcript pointing at a
# *different* repo, and a session with no local transcript at all must each
# be classified correctly (included, included, excluded, excluded).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/server-setup/bin/lib" "$TMP/fakebin" \
  "$TMP/claude-projects/proj" "$TMP/codex-sessions/2026/11/09" \
  "$TMP/target-repo" "$TMP/other-repo"
cp "$SS/bin/seed-repo-bank.sh" "$TMP/server-setup/bin/"
cp "$SS/bin/lib/json.sh" "$SS/bin/lib/transcripts.sh" "$TMP/server-setup/bin/lib/"
chmod +x "$TMP/server-setup/bin/seed-repo-bank.sh"

git init -q "$TMP/target-repo"
git init -q "$TMP/other-repo"

CLAUDE_SID="10000000-0000-0000-0000-000000000001"
CODEX_SID="20000000-0000-0000-0000-000000000002"
OTHER_REPO_SID="30000000-0000-0000-0000-000000000003"
NO_TRANSCRIPT_SID="40000000-0000-0000-0000-000000000004"

cat > "$TMP/claude-projects/proj/$CLAUDE_SID.jsonl" <<EOF
{"type":"summary"}
{"type":"user","cwd":"$TMP/target-repo","sessionId":"$CLAUDE_SID"}
EOF
cat > "$TMP/claude-projects/proj/$OTHER_REPO_SID.jsonl" <<EOF
{"type":"user","cwd":"$TMP/other-repo","sessionId":"$OTHER_REPO_SID"}
EOF

cat > "$TMP/codex-sessions/2026/11/09/rollout-2026-11-09T00-00-00-$CODEX_SID.jsonl" <<EOF
{"timestamp":"2026-11-09T00:00:00Z","ordinal":0,"type":"session_meta","payload":{"id":"$CODEX_SID","cwd":"$TMP/target-repo"}}
EOF
# NO_TRANSCRIPT_SID deliberately has no file anywhere.

cat > "$TMP/coding-agent.json" <<'EOF'
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"MAPPING-CANARY","bankId":"user-hieu","autoUpdate":true}
EOF

FAKE_LOG="$TMP/curl.log"
: > "$FAKE_LOG"
cat > "$TMP/fakebin/curl" <<CURLEOF
#!/bin/sh
cat >/dev/null 2>/dev/null || true
url=""; method="GET"; prev=""
for a in "\$@"; do
  [ "\$prev" = "-X" ] && method="\$a"
  url="\$a"
  prev="\$a"
done
printf '%s %s\n' "\$method" "\$url" >> "$FAKE_LOG"
case "\$method \$url" in
  "GET "*"/banks/coding-agent::target-repo/stats") printf '{}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?q=gitlog%3Atarget-repo"*) printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0")
    printf '{"items":[
      {"id":"conversation:$CLAUDE_SID","document_metadata":{"session_id":"$CLAUDE_SID"}},
      {"id":"conversation:$CODEX_SID","document_metadata":{"session_id":"$CODEX_SID"}},
      {"id":"conversation:$OTHER_REPO_SID","document_metadata":{"session_id":"$OTHER_REPO_SID"}},
      {"id":"conversation:$NO_TRANSCRIPT_SID","document_metadata":{"session_id":"$NO_TRANSCRIPT_SID"}}
    ],"total":4,"limit":200,"offset":0}\n200\n' ;;
  *) echo "unexpected call: \$method \$url" >&2; printf '{}\n599\n' ;;
esac
CURLEOF
chmod +x "$TMP/fakebin/curl"

export PATH="$TMP/fakebin:$PATH"
export FAKE_LOG
export HINDSIGHT_CODING_AGENT_CONFIG="$TMP/coding-agent.json"
export HINDSIGHT_SEED_CLAUDE_PROJECTS_DIR="$TMP/claude-projects"
export HINDSIGHT_SEED_CODEX_SESSIONS_DIR="$TMP/codex-sessions"
export HINDSIGHT_SEED_LEDGER_FILE="$TMP/ledger.jsonl"

out="$("$TMP/server-setup/bin/seed-repo-bank.sh" target-repo --dry-run)"

printf '%s\n' "$out" | grep -q 'Transfer candidates (2)' || { echo "$out"; echo "FAIL: expected exactly 2 mapped conversations"; exit 1; }
printf '%s\n' "$out" | grep -q "conversation:$CLAUDE_SID" || { echo "$out"; echo "FAIL: Claude Code session not mapped"; exit 1; }
printf '%s\n' "$out" | grep -q "conversation:$CODEX_SID" || { echo "$out"; echo "FAIL: Codex session not mapped"; exit 1; }
if printf '%s\n' "$out" | grep -qE "conversation:($OTHER_REPO_SID|$NO_TRANSCRIPT_SID)"; then
  echo "$out"; echo "FAIL: a different-repo or transcript-less session was included"; exit 1
fi

echo "ok - transcript mapping (Claude Code + Codex, excludes other-repo and transcript-less sessions)"
