#!/usr/bin/env bash
# End-to-end smoke test against a running Hindsight: create a bank, retain a
# durable fact, confirm it was actually extracted into a memory unit, recall
# it, then always delete the bank again (success or failure). Payloads
# verified against the v1.1.0 tag source (hindsight_api/api/http.py:
# CreateBankRequest, RetainRequest/MemoryItem, RetainResponse,
# ListMemoryUnitsResponse, RecallRequest/RecallResponse).
#
# retain's response (RetainResponse) only reports items_count — the number
# of items *submitted*, not the number of facts the LLM actually extracted
# and stored — so a retained-but-forgettable sentence (e.g. "smoke test
# memory created at <timestamp>") can get items_count=1 while the extractor
# keeps zero of it. We retain a clearly durable, specific statement instead,
# and separately confirm >=1 memory unit landed in the bank via
# GET .../memories/list before trusting recall to find anything.
#
# recall's extraction is concise and may paraphrase or drop incidental detail,
# so we never require a literal substring of the retained sentence to survive
# into the recall result. This bank was just created and holds nothing else,
# so any non-empty `results` array from recall against it is already proof
# recall found the fact just retained; whether a word from the fact (e.g.
# "Hanoi") literally survived is reported but never required for a pass.
#
# Usage: bin/smoke.sh
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HS="$CONFIG_DIR/bin/hs"

set -a
# shellcheck disable=SC1091
. "$CONFIG_DIR/base.env"
# shellcheck disable=SC1091
. "$CONFIG_DIR/secrets.env"
set +a

[ -n "${HINDSIGHT_API_TENANT_API_KEY:-}" ] || { echo "ERROR: HINDSIGHT_API_TENANT_API_KEY not set in secrets.env" >&2; exit 1; }

BASE_URL="$("$HS" url)"
BANK_ID="smoke-$(date +%s)-$$"
# Escaped once up front, not per-call: curl's config-file parser treats a
# bare `"`/`\` in the value as syntax.
AUTH_HEADER_ESCAPED=$(printf '%s' "$HINDSIGHT_API_TENANT_API_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')

say() { printf '\n==> %s\n' "$*"; }

req() {  # req <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}" out status
  # Authorization goes to curl via a `-K -` config file read from stdin,
  # never as a `-H` argv token — argv is visible to every local user via
  # `ps`/`/proc/<pid>/cmdline`, stdin is not.
  if [ -n "$body" ]; then
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
      | curl -sS --max-time 30 -w '\n%{http_code}' -K - -X "$method" \
        -H 'Content-Type: application/json' -d "$body" "$BASE_URL$path")"
  else
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
      | curl -sS --max-time 30 -w '\n%{http_code}' -K - -X "$method" "$BASE_URL$path")"
  fi
  status="${out##*$'\n'}"
  body_out="${out%$'\n'*}"
  echo "$method $path -> $status"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "$body_out" >&2
    return 1
  fi
  echo "$body_out"
}

cleanup() {
  local rc=$?
  say "Cleanup: deleting bank $BANK_ID"
  if ! req DELETE "/v1/default/banks/$BANK_ID" >/dev/null 2>&1; then
    echo "WARNING: failed to delete smoke bank $BANK_ID (may require manual cleanup)" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

say "1/5 Create bank $BANK_ID"
req PUT "/v1/default/banks/$BANK_ID" '{}' >/dev/null

say "2/5 Retain a durable fact"
retain_body=$(cat <<'JSON'
{"items": [{"content": "The smoke-test user prefers green tea and lives in Hanoi."}], "async": false}
JSON
)
req POST "/v1/default/banks/$BANK_ID/memories" "$retain_body" >/dev/null

say "3/5 Verify retain extracted at least one memory unit"
list_out="$(req GET "/v1/default/banks/$BANK_ID/memories/list?limit=1")"
total="$(printf '%s' "$list_out" | grep -o '"total"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$' || true)"
if [ -z "$total" ]; then
  echo "ERROR: could not find a 'total' field in the memories/list response:" >&2
  echo "$list_out" >&2
  exit 1
fi
if [ "$total" -lt 1 ]; then
  echo "ERROR: retain extracted 0 facts (LLM returned nothing worth keeping) from a sentence meant to be durable" >&2
  exit 1
fi
echo "memory units in bank: $total"

say "4/5 Recall it"
recall_body=$(cat <<'JSON'
{"query": "Where does the smoke-test user live, and what do they prefer to drink?"}
JSON
)
recall_out="$(req POST "/v1/default/banks/$BANK_ID/memories/recall" "$recall_body")"
echo "$recall_out"
if ! printf '%s' "$recall_out" | grep -q '"results"'; then
  echo "ERROR: recall response has no 'results' field:" >&2
  echo "$recall_out" >&2
  exit 1
fi
if printf '%s' "$recall_out" | grep -Eq '"results"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]'; then
  echo "ERROR: recall returned 0 results for a fact just confirmed present in bank $BANK_ID (retain worked, recall and retain disagree)" >&2
  exit 1
fi
if printf '%s' "$recall_out" | grep -qi "hanoi"; then
  echo "recall result mentions 'Hanoi' (expected content present)"
else
  echo "NOTE: recall result did not literally contain 'Hanoi' (non-fatal: recall may paraphrase or condense)"
fi

say "Smoke test OK"
