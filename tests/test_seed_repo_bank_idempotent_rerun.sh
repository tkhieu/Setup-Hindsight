#!/bin/sh
# Running bin/seed-repo-bank.sh twice for the same repo must be idempotent:
# both runs retain the distilled document under the exact same document_id
# (migrated:<source>:<repo>), relying on retain's upsert-by-document_id to
# replace rather than duplicate it, and each run appends exactly one ledger
# line. Also checks, as the rest of this repo's scripts do, that the API
# token never reaches curl's argv (only the -K stdin config carries it).
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
    printf '{"operation_id":"imp-1","status":"completed","result_metadata":{"documents_imported":0}}\n200\n' ;;
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

out1="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo)"
out2="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo)"

printf '%s\n' "$out1" | grep -q 'migrated:user-hieu:repo' || { echo "$out1"; echo "FAIL: run 1 did not retain the expected document id"; exit 1; }
printf '%s\n' "$out2" | grep -q 'migrated:user-hieu:repo' || { echo "$out2"; echo "FAIL: run 2 did not retain the expected document id"; exit 1; }

[ "$(wc -l < "$TMP/ledger.jsonl")" -eq 2 ] || { echo "FAIL: expected exactly 2 ledger lines after 2 runs"; cat "$TMP/ledger.jsonl"; exit 1; }
python3 -I -c "
import json
ids = {json.loads(line)['distill_document_id'] for line in open('$TMP/ledger.jsonl')}
assert ids == {'migrated:user-hieu:repo'}, ids
"

if grep -qF "$API_CANARY" "$FAKE_LOG"; then
  echo "FAIL: API token canary found in curl argv:"; cat "$FAKE_LOG"; exit 1
fi

echo "ok - rerun retains under the same document_id (idempotent) and never puts the token in argv"
