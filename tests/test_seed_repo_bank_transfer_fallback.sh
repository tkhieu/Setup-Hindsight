#!/bin/sh
# When the (deprecated) document-transfer export call fails outright (a
# definite, terminal failure -- not a timeout), a real run must not abort:
# it skips the copy step, reports the skip, still runs reflect+retain
# (distill), and records transfer_status="skipped" / transferred_count=0
# (no pending operation) in the ledger -- never touching the source bank.
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
SID="55555555-5555-5555-5555-555555555555"
cat > "$TMP/claude-projects/proj/$SID.jsonl" <<EOF
{"type":"user","cwd":"$TMP/repo","sessionId":"$SID"}
EOF

cat > "$TMP/coding-agent.json" <<'EOF'
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"FALLBACK-CANARY","bankId":"user-hieu","autoUpdate":true}
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
  "GET "*"/banks/coding-agent::repo/stats") printf '{}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0")
    printf '{"items":[{"id":"conversation:$SID","document_metadata":{"session_id":"$SID"}}],"total":1,"limit":200,"offset":0}\n200\n' ;;
  "POST "*"/banks/user-hieu/document-transfer/export"*) printf '{"detail":"export endpoint removed"}\n500\n' ;;
  "POST "*"/banks/user-hieu/reflect") printf '{"text":"Decisions and rationale: none recorded."}\n200\n' ;;
  "POST "*"/banks/coding-agent::repo/memories") printf '{"items_count":1}\n200\n' ;;
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

out="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo 2>&1)"

printf '%s\n' "$out" | grep -qi 'continuing with distill only' || { echo "$out"; echo "FAIL: missing the fallback message"; exit 1; }
grep -q '^POST .*/banks/user-hieu/reflect$' "$FAKE_LOG" || { echo "FAIL: reflect was not called despite the transfer failure"; exit 1; }
grep -q '^POST .*/banks/coding-agent::repo/memories$' "$FAKE_LOG" || { echo "FAIL: retain was not called despite the transfer failure"; exit 1; }

[ -f "$TMP/ledger.jsonl" ] || { echo "FAIL: ledger was not written"; exit 1; }
[ "$(wc -l < "$TMP/ledger.jsonl")" -eq 2 ] || { echo "FAIL: expected exactly 2 ledger lines (transfer+distill)"; cat "$TMP/ledger.jsonl"; exit 1; }
python3 -I -c "
import json
lines = [json.loads(l) for l in open('$TMP/ledger.jsonl')]
transfer = lines[0]
assert transfer['stage'] == 'transfer', transfer
assert transfer['transfer_status'] == 'skipped', transfer
assert transfer['transferred_count'] == 0, transfer
assert transfer['pending_bank'] is None, transfer
assert transfer['pending_operation_id'] is None, transfer

distill = lines[1]
assert distill['stage'] == 'distill', distill
assert distill['distill_document_id'] == 'migrated:user-hieu:repo', distill
"

echo "ok - a failed document-transfer falls back to distill-only and records the skip"
