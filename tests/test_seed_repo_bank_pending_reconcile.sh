#!/bin/sh
# When the import half of document-transfer never reaches a terminal state
# before HINDSIGHT_SEED_OPERATION_TIMEOUT elapses, the outcome is unknown --
# it may complete on the server right after this script gives up waiting.
# Run 1 must record transfer_status="pending" (with the bank + operation id
# to check later), NOT "skipped"/transferred_count=0 -- distill still runs
# regardless. Run 2, once that same operation has actually completed on the
# (fake) server, must reconcile it: confirm the real imported document ids
# and -- the real point of this test -- never resubmit a fresh
# document-transfer export/import for it.
#
# By run 2, IMPORT_STATUS=completed is already set BEFORE run 2 even starts
# -- the fake server's "did gitlog:repo land in the destination bank" check
# answers yes from the very first call, deliberately simulating the
# document having landed between run 1 giving up and run 2 starting, i.e.
# BEFORE run 2's own discovery phase runs its pre-existing-in-destination
# check. That ordering is exactly what makes reconcile_pending_import's use
# of the PENDING LEDGER ENTRY's own recorded attempted_confirmable_ids
# load-bearing: run 2's fresh discovery would otherwise see gitlog:repo as
# already present and exclude it from this run's own CONFIRMABLE_IDS,
# which would make confirm_imported_ids check nothing and silently report
# zero confirmed -- reusing the pending entry's recorded candidate instead
# avoids that entirely.
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
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"PENDING-CANARY","bankId":"user-hieu","autoUpdate":true}
EOF

FAKE_LOG="$TMP/curl.log"
: > "$FAKE_LOG"
# IMPORT_STATUS (env, read at call time) selects what the import operation
# reports: "processing" (never finishes -> run 1 times out) or "completed"
# (run 2's reconcile check).
cat > "$TMP/fakebin/curl" <<'CURLEOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG"
cat >/dev/null 2>/dev/null || true
url=""; method="GET"; out_file=""; prev=""
for a in "$@"; do
  case "$prev" in
    -X) method="$a" ;;
    -o) out_file="$a" ;;
  esac
  url="$a"
  prev="$a"
done
case "$method $url" in
  "GET "*"/banks/coding-agent::repo/stats") printf '{}\n200\n' ;;
  "GET "*"/banks/user-hieu/documents?q=gitlog%3Arepo"*) printf '{"items":[{"id":"gitlog:repo"}],"total":1,"limit":5,"offset":0}\n200\n' ;;
  "GET "*"/banks/coding-agent::repo/documents?q=gitlog%3Arepo"*)
    if [ "${IMPORT_STATUS:-processing}" = completed ]; then
      printf '{"items":[{"id":"gitlog:repo"}],"total":1,"limit":5,"offset":0}\n200\n'
    else
      printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n'
    fi ;;
  "GET "*"/banks/user-hieu/documents?tags=source%3Achat"*"offset=0") printf '{"items":[],"total":0,"limit":200,"offset":0}\n200\n' ;;
  "POST "*"/banks/user-hieu/document-transfer/export"*) printf '{"operation_id":"exp-1","status":"pending"}\n202\n' ;;
  "GET "*"/banks/user-hieu/operations/exp-1")
    printf '{"operation_id":"exp-1","status":"completed","result_metadata":{"download_url":"http://fake.invalid/v1/default/files/download/k1","storage_key":"k1"}}\n200\n' ;;
  "GET "*"/files/download/k1")
    [ -n "$out_file" ] && printf 'PK-fake-zip' > "$out_file"
    printf '200' ;;
  "POST "*"/banks/coding-agent::repo/document-transfer?on_conflict=skip")
    printf '{"operation_id":"imp-pending-1","status":"pending"}\n202\n' ;;
  "GET "*"/banks/coding-agent::repo/operations/imp-pending-1")
    if [ "${IMPORT_STATUS:-processing}" = completed ]; then
      printf '{"operation_id":"imp-pending-1","status":"completed","result_metadata":{"documents_imported":3}}\n200\n'
    else
      printf '{"operation_id":"imp-pending-1","status":"processing"}\n200\n'
    fi ;;
  "POST "*"/banks/user-hieu/reflect") printf '{"text":"Decisions and rationale: none recorded."}\n200\n' ;;
  "POST "*"/banks/coding-agent::repo/memories") printf '{"items_count":1}\n200\n' ;;
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
export HINDSIGHT_SEED_OPERATION_TIMEOUT=1
export HINDSIGHT_SEED_POLL_INTERVAL=1

# ---------------------------------------------------------------------------
# Run 1: the import operation never finishes -> pending, not skipped.
# ---------------------------------------------------------------------------
export IMPORT_STATUS=processing
out1="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo 2>&1)"

printf '%s\n' "$out1" | grep -qi 'recorded as pending' || { echo "$out1"; echo "FAIL: run 1 missing the pending message"; exit 1; }
printf '%s\n' "$out1" | grep -qi 'retained distilled document' || { echo "$out1"; echo "FAIL: run 1 did not still distill"; exit 1; }

[ "$(wc -l < "$TMP/ledger.jsonl")" -eq 1 ] || { echo "FAIL: expected exactly 1 ledger line after run 1"; cat "$TMP/ledger.jsonl"; exit 1; }
python3 -I -c "
import json
rec = json.loads(open('$TMP/ledger.jsonl').readline())
assert rec['transfer_status'] == 'pending', rec
assert rec['transferred_count'] == 0, rec
assert rec['confirmed_document_ids'] == [], rec
assert rec['attempted_confirmable_ids'] == ['gitlog:repo'], rec
assert rec['pending_bank'] == 'coding-agent::repo', rec
assert rec['pending_operation_id'] == 'imp-pending-1', rec
"

export_calls_after_run1="$(grep -c '/document-transfer/export' "$FAKE_LOG")"

# ---------------------------------------------------------------------------
# Run 2: the same operation has now completed server-side -> reconcile.
# ---------------------------------------------------------------------------
export IMPORT_STATUS=completed
out2="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo 2>&1)"

printf '%s\n' "$out2" | grep -qi 'reconciled previously-pending import operation' \
  || { echo "$out2"; echo "FAIL: run 2 did not reconcile the pending operation"; exit 1; }

[ "$(wc -l < "$TMP/ledger.jsonl")" -eq 2 ] || { echo "FAIL: expected exactly 2 ledger lines after run 2"; cat "$TMP/ledger.jsonl"; exit 1; }
python3 -I -c "
import json
lines = [json.loads(l) for l in open('$TMP/ledger.jsonl')]
rec = lines[1]
assert rec['transfer_status'] == 'transferred', rec
assert rec['confirmed_document_ids'] == ['gitlog:repo'], rec
assert rec['transferred_count'] == 1, rec
assert rec['pending_bank'] is None, rec
assert rec['pending_operation_id'] is None, rec
"

export_calls_after_run2="$(grep -c '/document-transfer/export' "$FAKE_LOG")"
[ "$export_calls_after_run2" -eq "$export_calls_after_run1" ] \
  || { echo "FAIL: run 2 resubmitted a fresh document-transfer export instead of reconciling"; cat "$FAKE_LOG"; exit 1; }

echo "ok - an unfinished import is recorded as pending (not skipped) and a later run reconciles it without resubmitting"
