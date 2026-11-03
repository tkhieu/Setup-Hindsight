#!/usr/bin/env bash
# End-to-end smoke test against a running Hindsight: create a bank, retain a
# memory, recall it, then delete the bank again. Payloads verified against
# the v1.1.0 tag source (hindsight_api/api/http.py: CreateBankRequest,
# RetainRequest/MemoryItem, RecallRequest).
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
AUTH=(-H "Authorization: Bearer $HINDSIGHT_API_TENANT_API_KEY")

say() { printf '\n==> %s\n' "$*"; }

req() {  # req <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}" out status
  if [ -n "$body" ]; then
    out="$(curl -sS --max-time 30 -w '\n%{http_code}' -X "$method" "${AUTH[@]}" \
      -H 'Content-Type: application/json' -d "$body" "$BASE_URL$path")"
  else
    out="$(curl -sS --max-time 30 -w '\n%{http_code}' -X "$method" "${AUTH[@]}" "$BASE_URL$path")"
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

say "1/4 Create bank $BANK_ID"
req PUT "/v1/default/banks/$BANK_ID" '{}' >/dev/null

say "2/4 Retain a memory"
retain_body=$(cat <<JSON
{"items": [{"content": "Smoke test memory created by bin/smoke.sh at $(date -Iseconds)."}]}
JSON
)
req POST "/v1/default/banks/$BANK_ID/memories" "$retain_body" >/dev/null

say "3/4 Recall it"
recall_out="$(req POST "/v1/default/banks/$BANK_ID/memories/recall" '{"query": "smoke test"}')"
echo "$recall_out"
if ! printf '%s' "$recall_out" | grep -qi "smoke test"; then
  echo "ERROR: recall did not surface the memory just retained" >&2
  exit 1
fi

say "4/4 Delete bank $BANK_ID (cleanup)"
req DELETE "/v1/default/banks/$BANK_ID" >/dev/null

say "Smoke test OK"
