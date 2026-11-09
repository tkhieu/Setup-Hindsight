#!/bin/sh
# The transfer stage's ledger entry must be appended BEFORE reflect/retain
# (distill) are even attempted, not deferred until the whole run finishes.
# If distill then fails outright, the script dies -- but the transfer
# stage's ownership record (what it confirmed imported, or that it has
# nothing/skipped) must already be on disk, not lost along with the rest
# of the run.
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
SID="99999999-9999-9999-9999-999999999999"
cat > "$TMP/claude-projects/proj/$SID.jsonl" <<EOF
{"type":"user","cwd":"$TMP/repo","sessionId":"$SID"}
EOF

cat > "$TMP/coding-agent.json" <<'EOF'
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"LEDGERORDER-CANARY","bankId":"user-hieu","autoUpdate":true}
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
  "GET "*"/banks/coding-agent::repo/documents?q=conversation%3A$SID"*)
    if [ -f "$TMP/import-landed" ]; then
      printf '{"items":[{"id":"conversation:$SID"}],"total":1,"limit":5,"offset":0}\n200\n'
    else
      printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n'
    fi ;;
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0")
    printf '{"items":[{"id":"conversation:$SID","document_metadata":{"session_id":"$SID"}}],"total":1,"limit":200,"offset":0}\n200\n' ;;
  "POST "*"/banks/user-hieu/document-transfer/export"*) printf '{"operation_id":"exp-1","status":"pending"}\n202\n' ;;
  "GET "*"/banks/user-hieu/operations/exp-1")
    printf '{"operation_id":"exp-1","status":"completed","result_metadata":{"download_url":"http://fake.invalid/v1/default/files/download/k1","storage_key":"k1"}}\n200\n' ;;
  "GET "*"/files/download/k1")
    [ -n "\$out_file" ] && printf 'PK-fake-zip' > "\$out_file"
    printf '200' ;;
  "POST "*"/banks/coding-agent::repo/document-transfer?on_conflict=skip")
    printf '{"operation_id":"imp-1","status":"pending"}\n202\n' ;;
  "GET "*"/banks/coding-agent::repo/operations/imp-1")
    touch "$TMP/import-landed"
    printf '{"operation_id":"imp-1","status":"completed","result_metadata":{"documents_imported":1}}\n200\n' ;;
  # reflect -- the first step of distill -- fails outright.
  "POST "*"/banks/user-hieu/reflect") printf '{"detail":"llm unavailable"}\n500\n' ;;
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

set +e
out="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo 2>&1)"
rc=$?
set -e

[ "$rc" -ne 0 ] || { echo "$out"; echo "FAIL: expected the script to die when reflect fails"; exit 1; }
printf '%s\n' "$out" | grep -qi 'reflect on source bank .* failed' \
  || { echo "$out"; echo "FAIL: missing the reflect-failure message"; exit 1; }

[ -f "$TMP/ledger.jsonl" ] || { echo "FAIL: the transfer stage's ledger entry was lost along with the distill failure"; exit 1; }
[ "$(wc -l < "$TMP/ledger.jsonl")" -eq 1 ] \
  || { echo "FAIL: expected exactly 1 ledger line (transfer only -- distill never got to write its own)"; cat "$TMP/ledger.jsonl"; exit 1; }
python3 -I -c "
import json
rec = json.loads(open('$TMP/ledger.jsonl').readline())
assert rec['stage'] == 'transfer', rec
assert rec['transfer_status'] == 'transferred', rec
assert rec['confirmed_document_ids'] == ['conversation:$SID'], rec
"

echo "ok - the transfer stage's ledger entry survives a subsequent distill failure"
