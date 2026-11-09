#!/bin/sh
# A transient error while polling the import operation (a 5xx response,
# standing in for a network error or a 429) is NOT a definite failure --
# the server never told us the operation failed, we just couldn't reach it
# this one time. poll_operation must keep retrying through
# OPERATION_TIMEOUT rather than giving up on the first bad poll, and once
# the timeout elapses while every poll kept erroring, the outcome is
# "pending" (unknown), never "skipped" (which would mean this script is
# claiming certainty the server itself never gave it).
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
SID="88888888-8888-8888-8888-888888888888"
cat > "$TMP/claude-projects/proj/$SID.jsonl" <<EOF
{"type":"user","cwd":"$TMP/repo","sessionId":"$SID"}
EOF

cat > "$TMP/coding-agent.json" <<'EOF'
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"POLLERR-CANARY","bankId":"user-hieu","autoUpdate":true}
EOF

FAKE_LOG="$TMP/curl.log"
: > "$FAKE_LOG"
cat > "$TMP/fakebin/curl" <<CURLEOF
#!/bin/sh
printf '%s\n' "\$*" >> "$FAKE_LOG"
cat >/dev/null 2>/dev/null || true
url=""; method="GET"; out_file=""; prev=""
for a in "\$@"; do
  case "\$prev" in
    -X) method="\$a" ;;
    -o) out_file="\$a" ;;
  esac
  url="\$a"
  prev="\$a"
done
case "\$method \$url" in
  "GET "*"/banks/coding-agent::repo/stats") printf '{}\n200\n' ;;
  "GET "*"/banks/coding-agent::repo/documents?q="*) printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0")
    printf '{"items":[{"id":"conversation:$SID","document_metadata":{"session_id":"$SID"}}],"total":1,"limit":200,"offset":0}\n200\n' ;;
  "POST "*"/banks/user-hieu/document-transfer/export"*) printf '{"operation_id":"exp-1","status":"pending"}\n202\n' ;;
  "GET "*"/banks/user-hieu/operations/exp-1")
    printf '{"operation_id":"exp-1","status":"completed","result_metadata":{"download_url":"http://fake.invalid/v1/default/files/download/k1","storage_key":"k1"}}\n200\n' ;;
  "GET "*"/files/download/k1")
    [ -n "\$out_file" ] && printf 'PK-fake-zip' > "\$out_file"
    printf '200' ;;
  "POST "*"/banks/coding-agent::repo/document-transfer?on_conflict=skip")
    printf '{"operation_id":"imp-flaky-1","status":"pending"}\n202\n' ;;
  "GET "*"/banks/coding-agent::repo/operations/imp-flaky-1")
    # Every poll of this operation errors out -- the server is never
    # reached long enough to report a real status at all.
    printf '{"detail":"internal error"}\n500\n' ;;
  "POST "*"/banks/user-hieu/reflect") printf '{"text":"Decisions and rationale: none recorded."}\n200\n' ;;
  "POST "*"/banks/coding-agent::repo/memories") printf '{"items_count":1}\n200\n' ;;
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
export HINDSIGHT_SEED_OPERATION_TIMEOUT=1
export HINDSIGHT_SEED_POLL_INTERVAL=1

out="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo 2>&1)"

printf '%s\n' "$out" | grep -qi 'recorded as pending' \
  || { echo "$out"; echo "FAIL: a run of nothing but poll errors must still end up pending, not skipped"; exit 1; }
if printf '%s\n' "$out" | grep -qi 'document-transfer failed'; then
  echo "$out"; echo "FAIL: poll errors must never be reported as a definite transfer failure"; exit 1
fi

# More than one poll attempt must have actually happened before giving up
# (proving it retried through the timeout rather than returning on the
# first error).
poll_attempts="$(grep -c '/operations/imp-flaky-1' "$FAKE_LOG")"
[ "$poll_attempts" -ge 2 ] || { echo "FAIL: expected at least 2 poll attempts, got $poll_attempts"; cat "$FAKE_LOG"; exit 1; }

[ "$(wc -l < "$TMP/ledger.jsonl")" -eq 2 ] || { echo "FAIL: expected exactly 2 ledger lines (transfer+distill)"; cat "$TMP/ledger.jsonl"; exit 1; }
python3 -I -c "
import json
rec = json.loads(open('$TMP/ledger.jsonl').readline())
assert rec['stage'] == 'transfer', rec
assert rec['transfer_status'] == 'pending', rec
assert rec['pending_bank'] == 'coding-agent::repo', rec
assert rec['pending_operation_id'] == 'imp-flaky-1', rec
"

echo "ok - persistent poll errors (never a server-reported failure) end up pending, never skipped"
