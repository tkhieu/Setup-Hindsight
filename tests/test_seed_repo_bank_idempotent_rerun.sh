#!/bin/sh
# Running bin/seed-repo-bank.sh twice for the same repo must be idempotent:
# both runs' retain payload must carry the exact same document_id
# (migrated:<source>:<repo>) AND an explicit update_mode="replace" -- not
# relying on retain's default ever staying "replace" -- so a rerun replaces
# rather than duplicates it, and each run appends exactly one ledger line.
# Run 1's candidates are genuinely new, so they end up confirmed; by run 2
# they are already present in the destination bank, so run 2 must report
# an empty confirmed_document_ids (nothing NEW -- run 1's ledger entry
# already owns those ids for rollback purposes) and must skip the
# deprecated document-transfer export/import entirely rather than
# submitting one just to get a no-op skip back. Also checks, as the rest
# of this repo's scripts do, that the API token never reaches curl's argv
# (only the -K stdin config carries it).
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
SID="66666666-6666-6666-6666-666666666666"
cat > "$TMP/claude-projects/proj/$SID.jsonl" <<EOF
{"type":"user","cwd":"$TMP/repo","sessionId":"$SID"}
EOF

API_CANARY="CANARY-IDEMPOTENT-f00dbeef"
cat > "$TMP/coding-agent.json" <<EOF
{"serverMode":"remote","apiUrl":"http://fake.invalid","apiToken":"$API_CANARY","bankId":"user-hieu","autoUpdate":true}
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
  "GET "*"/banks/user-hieu/documents?q=gitlog%3Arepo"*) printf '{"items":[{"id":"gitlog:repo"}],"total":1,"limit":5,"offset":0}\n200\n' ;;
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
    printf '{"operation_id":"imp-1","status":"completed","result_metadata":{"documents_imported":0}}\n200\n' ;;
  "POST "*"/banks/user-hieu/reflect") printf '{"text":"Decisions and rationale: none recorded."}\n200\n' ;;
  "POST "*"/banks/coding-agent::repo/memories") printf '{"items_count":1}\n200\n' ;;
  "GET "*"/banks/coding-agent::repo/documents?q=gitlog%3Arepo"*)
    if [ -f "$TMP/import-landed" ]; then
      printf '{"items":[{"id":"gitlog:repo"}],"total":1,"limit":5,"offset":0}\n200\n'
    else
      printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n'
    fi ;;
  "GET "*"/banks/coding-agent::repo/documents?q=conversation%3A$SID"*)
    if [ -f "$TMP/import-landed" ]; then
      printf '{"items":[{"id":"conversation:$SID"}],"total":1,"limit":5,"offset":0}\n200\n'
    else
      printf '{"items":[],"total":0,"limit":5,"offset":0}\n200\n'
    fi ;;
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

out1="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo)"
out2="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo)"

printf '%s\n' "$out1" | grep -q 'migrated:user-hieu:repo' || { echo "$out1"; echo "FAIL: run 1 did not retain the expected document id"; exit 1; }
printf '%s\n' "$out2" | grep -q 'migrated:user-hieu:repo' || { echo "$out2"; echo "FAIL: run 2 did not retain the expected document id"; exit 1; }

[ "$(wc -l < "$TMP/ledger.jsonl")" -eq 2 ] || { echo "FAIL: expected exactly 2 ledger lines after 2 runs"; cat "$TMP/ledger.jsonl"; exit 1; }
python3 -I -c "
import json
lines = [json.loads(l) for l in open('$TMP/ledger.jsonl')]
ids = {rec['distill_document_id'] for rec in lines}
assert ids == {'migrated:user-hieu:repo'}, ids

# Run 1: both candidates are genuinely new -> confirmed.
run1 = lines[0]
assert run1['transfer_status'] == 'transferred', run1
assert set(run1['confirmed_document_ids']) == {'gitlog:repo', 'conversation:$SID'}, run1

# Run 2: everything is now pre-existing in the destination bank -> nothing
# NEW to confirm. Idempotent means safe to rerun, not 'always re-claims the
# same ids' -- run 1's ledger entry already owns them for rollback purposes.
run2 = lines[1]
assert run2['transfer_status'] == 'transferred', run2
assert run2['confirmed_document_ids'] == [], run2
"

# And specifically because everything was already pre-existing, run 2 must
# skip the deprecated document-transfer endpoints entirely rather than
# submitting a pointless export/import just to get a no-op skip back.
export_calls="$(grep -c '/document-transfer/export' "$FAKE_LOG")"
[ "$export_calls" -eq 1 ] || { echo "FAIL: expected exactly 1 document-transfer/export call (run 1 only), got $export_calls"; cat "$FAKE_LOG"; exit 1; }

if grep -qF "$API_CANARY" "$FAKE_LOG"; then
  echo "FAIL: API token canary found in curl argv:"; cat "$FAKE_LOG"; exit 1
fi

# Both calls' logged argv must carry the retain payload itself (sent via
# -d, same as the rest of this repo's scripts send non-secret JSON bodies)
# with the fixed document_id and an explicit replace update_mode. Each
# grep stage matches its own substring anywhere on the line, independent
# of where in the line the other substring falls.
retain_with_docid="$(grep -F 'banks/coding-agent::repo/memories' "$FAKE_LOG" \
  | grep -cF '"document_id": "migrated:user-hieu:repo"')" || true
retain_with_replace="$(grep -F 'banks/coding-agent::repo/memories' "$FAKE_LOG" \
  | grep -cF '"update_mode": "replace"')" || true
[ "${retain_with_docid:-0}" -eq 2 ] \
  || { echo "FAIL: expected both retain calls to carry document_id=migrated:user-hieu:repo, got $retain_with_docid"; cat "$FAKE_LOG"; exit 1; }
[ "${retain_with_replace:-0}" -eq 2 ] \
  || { echo "FAIL: expected both retain calls to carry update_mode=replace, got $retain_with_replace"; cat "$FAKE_LOG"; exit 1; }

echo "ok - rerun retains under the same document_id with replace semantics (idempotent), and never puts the token in argv"
