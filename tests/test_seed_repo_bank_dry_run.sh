#!/bin/sh
# bin/seed-repo-bank.sh --dry-run must perform only read-only discovery
# (bank existence, conversation-document listing) and write nothing: no
# document-transfer/reflect/retain POST, no ledger file. It must also
# report the exact transfer-candidate set it found -- conversation
# documents only, gitlog:<repo> is never a candidate (the coding-agent
# plugin owns and refreshes that document itself).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/server-setup/bin/lib" "$TMP/fakebin" \
  "$TMP/claude-projects/proj" "$TMP/codex-sessions" "$TMP/repo"
cp "$SS/bin/seed-repo-bank.sh" "$TMP/server-setup/bin/"
cp "$SS/bin/lib/json.sh" "$SS/bin/lib/transcripts.sh" "$TMP/server-setup/bin/lib/"
chmod +x "$TMP/server-setup/bin/seed-repo-bank.sh"

git init -q "$TMP/repo"

MATCHED_SID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
OTHER_SID="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
cat > "$TMP/claude-projects/proj/$MATCHED_SID.jsonl" <<EOF
{"type":"summary"}
{"type":"user","cwd":"$TMP/repo","sessionId":"$MATCHED_SID"}
EOF
# OTHER_SID has a document in the bank but no local transcript at all, and
# must therefore be silently excluded (not an error).

cat > "$TMP/coding-agent.json" <<'EOF'
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"DRYRUN-CANARY","bankId":"user-hieu","autoUpdate":true}
EOF

FAKE_LOG="$TMP/curl.log"
: > "$FAKE_LOG"
cat > "$TMP/fakebin/curl" <<CURLEOF
#!/bin/sh
cat >/dev/null 2>/dev/null || true
url=""
method="GET"
prev=""
for a in "\$@"; do
  [ "\$prev" = "-X" ] && method="\$a"
  url="\$a"
  prev="\$a"
done
printf '%s %s\n' "\$method" "\$url" >> "$FAKE_LOG"
case "\$method \$url" in
  "GET "*"/banks/coding-agent::repo/stats") printf '{}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0")
    printf '{"items":[{"id":"conversation:$MATCHED_SID","document_metadata":{"session_id":"$MATCHED_SID"}},{"id":"conversation:$OTHER_SID","document_metadata":{"session_id":"$OTHER_SID"}}],"total":2,"limit":200,"offset":0}\n200\n' ;;
  "GET "*"/banks/coding-agent::repo/documents?q="*)
    printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n' ;;
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

out="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo --dry-run)"

printf '%s\n' "$out" | grep -q 'DRY RUN' || { echo "$out"; echo "FAIL: missing DRY RUN marker"; exit 1; }
printf '%s\n' "$out" | grep -q 'Transfer candidates (1)' || { echo "$out"; echo "FAIL: expected 1 transfer candidate"; exit 1; }
printf '%s\n' "$out" | grep -q "conversation:$MATCHED_SID" || { echo "$out"; echo "FAIL: missing mapped conversation in plan"; exit 1; }
if printf '%s\n' "$out" | grep -q "conversation:$OTHER_SID"; then
  echo "$out"; echo "FAIL: untracked-session conversation must not appear in the plan"; exit 1
fi
# "gitlog:repo" legitimately appears in the descriptive header text
# ("... gitlog:repo is never transferred"); only a line that is just the
# candidate itself, indented exactly like the other listed candidates,
# would mean it was actually listed.
if printf '%s\n' "$out" | grep -qx '  gitlog:repo'; then
  echo "$out"; echo "FAIL: gitlog:repo must never be listed as a transfer candidate"; exit 1
fi

[ -e "$TMP/ledger.jsonl" ] && { echo "FAIL: dry-run must not write the ledger"; exit 1; }
if grep -qE '^(POST|PUT|PATCH|DELETE) ' "$FAKE_LOG"; then
  echo "FAIL: dry-run made a write call:"; cat "$FAKE_LOG"; exit 1
fi

echo "ok - dry-run reports the plan and writes nothing"
