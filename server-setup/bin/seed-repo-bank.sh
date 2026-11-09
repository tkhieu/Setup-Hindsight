#!/usr/bin/env bash
# Seed a per-repo Hindsight bank (coding-agent::<repo>) once from the shared
# user bank, as part of the gradual split away from a single user-wide bank.
# See docs/RUNBOOK.md for the operator procedure this script implements.
#
# Usage: bin/seed-repo-bank.sh <repo-basename> [--dry-run] [--source BANK_ID]
#
# What it does, against the public Hindsight API (not the local docker
# stack -- this runs on a dev workstation, not the server):
#   1. Exact transfer: the source bank's `gitlog:<repo>` document, plus any
#      conversation document whose session_id maps -- via a local Claude
#      Code or Codex transcript -- to this repo's main worktree. Copied via
#      the (deprecated, async) document-transfer export/import endpoints.
#   2. Distill: `reflect` on the source bank with a fixed question set about
#      the repo, then `retain` the answer into the destination bank as
#      document `migrated:<source-bank>:<repo>`, tags `project:<repo>` and
#      `source:migration`. Retain's upsert-by-document_id makes a rerun
#      replace this one document rather than duplicate it.
#   3. Ledger: one JSONL line appended to server-setup/state/bank-seed-ledger.jsonl
#      (no memory content, only repo/counts/ids).
#
# --dry-run performs only the read-only discovery above and prints the plan;
# it never calls document-transfer, reflect, retain, or writes the ledger.
#
# The destination bank must already exist (created by the coding-agent
# plugin the first time the repo is opened in Claude Code/Codex) -- this
# script never creates or writes to it until that has happened, and never
# writes to or deletes from the source bank at all.
#
# Auth: HINDSIGHT_API_TOKEN env var, or the "apiToken" field of
# ~/.hindsight/coding-agent.json (HINDSIGHT_CODING_AGENT_CONFIG overrides the
# path). The API base URL always comes from that same file's "apiUrl". The
# token is never placed in argv or printed -- it reaches curl only via a
# `-K -` config file read from stdin, same as bin/smoke.sh.
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/json.sh"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/transcripts.sh"

die() { echo "seed-repo-bank: $*" >&2; exit 1; }

usage() { echo "usage: bin/seed-repo-bank.sh <repo-basename> [--dry-run] [--source BANK_ID]" >&2; }

HTTP_TIMEOUT="${HINDSIGHT_SEED_HTTP_TIMEOUT:-60}"
DOWNLOAD_TIMEOUT="${HINDSIGHT_SEED_DOWNLOAD_TIMEOUT:-180}"
OPERATION_TIMEOUT="${HINDSIGHT_SEED_OPERATION_TIMEOUT:-120}"
POLL_INTERVAL="${HINDSIGHT_SEED_POLL_INTERVAL:-2}"
PAGE_SIZE="${HINDSIGHT_SEED_PAGE_SIZE:-200}"
CLAUDE_DIR="${HINDSIGHT_SEED_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
CODEX_DIR="${HINDSIGHT_SEED_CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
LEDGER_FILE="${HINDSIGHT_SEED_LEDGER_FILE:-$CONFIG_DIR/state/bank-seed-ledger.jsonl}"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
REPO=""
DRY_RUN=0
SRC_BANK="user-hieu"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --source) [ "$#" -ge 2 ] || { usage; die "--source needs a value"; }; SRC_BANK="$2"; shift 2 ;;
    --source=*) SRC_BANK="${1#--source=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift ;;
    -*) usage; die "unknown option: $1" ;;
    *)
      [ -z "$REPO" ] || { usage; die "unexpected extra argument: $1"; }
      REPO="$1"; shift ;;
  esac
done
[ -n "$REPO" ] || { usage; die "missing <repo-basename>"; }
[[ "$REPO" =~ ^[A-Za-z0-9._-]+$ ]] || die "repo basename must match ^[A-Za-z0-9._-]+\$: $REPO"
[[ "$SRC_BANK" =~ ^[A-Za-z0-9._:-]+$ ]] || die "--source must match ^[A-Za-z0-9._:-]+\$: $SRC_BANK"

DST_BANK="coding-agent::$REPO"
GITLOG_ID="gitlog:$REPO"
DISTILL_DOC_ID="migrated:$SRC_BANK:$REPO"

# ---------------------------------------------------------------------------
# Config: API URL + token. Token may come from the environment instead of
# the config file; the URL always comes from the config file.
# ---------------------------------------------------------------------------
CODING_AGENT_CONFIG="${HINDSIGHT_CODING_AGENT_CONFIG:-$HOME/.hindsight/coding-agent.json}"
[ -f "$CODING_AGENT_CONFIG" ] || die "coding-agent config not found: $CODING_AGENT_CONFIG"

API_TOKEN="${HINDSIGHT_API_TOKEN:-}"
if [ -z "$API_TOKEN" ]; then
  API_TOKEN="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("apiToken") or "")' "$CODING_AGENT_CONFIG")"
fi
[ -n "$API_TOKEN" ] || die "no API token: set HINDSIGHT_API_TOKEN or add \"apiToken\" to $CODING_AGENT_CONFIG"

API_URL="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("apiUrl") or "")' "$CODING_AGENT_CONFIG")"
[ -n "$API_URL" ] || die "no \"apiUrl\" in $CODING_AGENT_CONFIG"
API_URL="${API_URL%/}"

# Escaped once, not per-call: curl's -K config parser treats a bare `"`/`\`
# in the value as syntax. Never passed via -H / argv (see module header).
AUTH_HEADER_ESCAPED=$(printf '%s' "$API_TOKEN" | sed 's/\\/\\\\/g; s/"/\\"/g')

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

# req <method> <url> [json-body] -> prints the response body on 2xx and
# returns 0; prints the body to stderr and returns 1 otherwise.
req() {
  local method="$1" url="$2" body="${3:-}" out status body_out
  if [ -n "$body" ]; then
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
      | curl -sS --max-time "$HTTP_TIMEOUT" -w '\n%{http_code}' -K - -X "$method" \
        -H 'Content-Type: application/json' -d "$body" "$url")"
  else
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
      | curl -sS --max-time "$HTTP_TIMEOUT" -w '\n%{http_code}' -K - -X "$method" "$url")"
  fi
  status="${out##*$'\n'}"
  body_out="${out%$'\n'*}"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "$body_out" >&2
    return 1
  fi
  printf '%s' "$body_out"
}

# req_upload <url> <file-path> -> multipart file upload; same success/failure
# contract as req(). The file field goes through -K's `form` directive too,
# so neither the token nor the call ever appears in curl's argv.
req_upload() {
  local url="$1" file="$2" out status body_out
  out="$(printf 'header = "Authorization: Bearer %s"\nform = "file=@%s;type=application/octet-stream"\n' \
      "$AUTH_HEADER_ESCAPED" "$file" \
    | curl -sS --max-time "$HTTP_TIMEOUT" -w '\n%{http_code}' -K - -X POST "$url")"
  status="${out##*$'\n'}"
  body_out="${out%$'\n'*}"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "$body_out" >&2
    return 1
  fi
  printf '%s' "$body_out"
}

# req_download <url> <dest-file> -> streams the response body to <dest-file>.
req_download() {
  local url="$1" dest="$2" status
  status="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
    | curl -sS --max-time "$DOWNLOAD_TIMEOUT" -w '%{http_code}' -K - -X GET -o "$dest" "$url")"
  [ "$status" -ge 200 ] && [ "$status" -lt 300 ]
}

urlencode() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# bank_exists <bank_id> -- 0 if it exists, 1 if confirmed missing (404).
# Any other HTTP status is treated as fatal: it means we can't trust our
# own read of bank state, so the script stops rather than guessing.
bank_exists() {
  local bank="$1" out status
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
    | curl -sS --max-time "$HTTP_TIMEOUT" -w '\n%{http_code}' -K - -X GET "$API_URL/v1/default/banks/$bank/stats")"
  status="${out##*$'\n'}"
  case "$status" in
    2??) return 0 ;;
    404) return 1 ;;
    *) die "unexpected HTTP $status checking bank $bank" ;;
  esac
}

# poll_operation <bank> <operation_id> -> prints the final operation JSON and
# returns 0 once status=completed; returns 1 on failed/cancelled/not_found
# or once OPERATION_TIMEOUT elapses.
poll_operation() {
  local bank="$1" op_id="$2" start status body
  start="$SECONDS"
  while :; do
    body="$(req GET "$API_URL/v1/default/banks/$bank/operations/$op_id")" || return 1
    status="$(printf '%s' "$body" | json_path status)"
    case "$status" in
      completed) printf '%s' "$body"; return 0 ;;
      failed|cancelled|not_found) echo "seed-repo-bank: operation $op_id ($bank) ended as $status" >&2; return 1 ;;
    esac
    if [ $((SECONDS - start)) -ge "$OPERATION_TIMEOUT" ]; then
      echo "seed-repo-bank: timed out after ${OPERATION_TIMEOUT}s waiting on operation $op_id ($bank)" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

# extract_sessions <documents-list-json-file> -> one "doc_id<TAB>session_id"
# line per item that has document_metadata.session_id.
extract_sessions() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for item in d.get("items", []):
    meta = item.get("document_metadata") or {}
    sid = meta.get("session_id")
    if sid:
        print(item.get("id", "") + "\t" + sid)
' "$1"
}

# doc_id_exists <documents-list-json-file> <exact-id> -> "1" or "0". `q` is
# a substring filter, so an exact match must still be confirmed client-side.
doc_id_exists() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
target = sys.argv[2]
print("1" if any(item.get("id") == target for item in d.get("items", [])) else "0")
' "$1" "$2"
}

# ---------------------------------------------------------------------------
# Discovery (read-only; same for --dry-run and a real run)
# ---------------------------------------------------------------------------

echo "seed-repo-bank: repo=$REPO source=$SRC_BANK destination=$DST_BANK"

dst_exists=1
if ! bank_exists "$DST_BANK"; then dst_exists=0; fi

TRANSFER_IDS=()

gitlog_tmp="$(mktemp)"
req GET "$API_URL/v1/default/banks/$SRC_BANK/documents?q=$(urlencode "$GITLOG_ID")&limit=5" > "$gitlog_tmp" \
  || die "could not list documents on source bank $SRC_BANK"
if [ "$(doc_id_exists "$gitlog_tmp" "$GITLOG_ID")" = 1 ]; then
  TRANSFER_IDS+=("$GITLOG_ID")
fi
rm -f "$gitlog_tmp"

conv_offset=0
tags_qs="tags=$(urlencode "source:chat")&tags_match=any_strict"
while :; do
  page_tmp="$(mktemp)"
  req GET "$API_URL/v1/default/banks/$SRC_BANK/documents?$tags_qs&limit=$PAGE_SIZE&offset=$conv_offset" > "$page_tmp" \
    || die "could not list conversation documents on source bank $SRC_BANK"
  total="$(json_path total < "$page_tmp")"
  [ -n "$total" ] || total=0
  while IFS=$'\t' read -r doc_id sid; do
    [ -n "$sid" ] || continue
    repo_match="$(resolve_repo_for_session "$sid" "$CLAUDE_DIR" "$CODEX_DIR" 2>/dev/null)" || repo_match=""
    if [ "$repo_match" = "$REPO" ]; then
      TRANSFER_IDS+=("$doc_id")
    fi
  done < <(extract_sessions "$page_tmp")
  rm -f "$page_tmp"
  conv_offset=$((conv_offset + PAGE_SIZE))
  [ "$conv_offset" -lt "$total" ] || break
done

REFLECT_QUERY=$(cat <<EOF
You are reviewing everything you have learned so far to extract what you specifically know about the project/repository named "$REPO". Answer only with facts you can confidently attribute to "$REPO" itself; leave out anything about a different repository, and leave out anything too generic to tell apart from other projects. Organize the answer under exactly these five headings, each a short bullet list; if you have nothing repo-specific for a heading, write "None recorded." under it instead of guessing:

## Decisions and rationale
## Conventions
## Architecture and components
## Open work
## Past incidents
EOF
)

# ---------------------------------------------------------------------------
# --dry-run: report the plan, write nothing
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "DRY RUN -- no API writes, no ledger write."
  echo
  if [ "$dst_exists" = 1 ]; then
    echo "Destination bank status: exists"
  else
    echo "Destination bank status: MISSING -- a real run would stop here until the repo"
    echo "  is opened once in Claude Code or Codex so the coding-agent plugin creates it."
  fi
  echo
  echo "Transfer candidates (${#TRANSFER_IDS[@]}):"
  if [ "${#TRANSFER_IDS[@]}" -eq 0 ]; then
    echo "  (none found)"
  else
    printf '  %s\n' "${TRANSFER_IDS[@]}"
  fi
  echo
  echo "Reflect query (against $SRC_BANK):"
  printf '%s\n' "$REFLECT_QUERY" | sed 's/^/  /'
  echo
  echo "Distill target: $DST_BANK document \"$DISTILL_DOC_ID\" (tags: project:$REPO, source:migration)"
  echo
  echo "Ledger (not written): $LEDGER_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Real run
# ---------------------------------------------------------------------------
if [ "$dst_exists" = 0 ]; then
  cat >&2 <<MSG
seed-repo-bank: destination bank '$DST_BANK' does not exist yet.
Open this repo once in Claude Code or Codex (with per-repo banks enabled) so
the coding-agent plugin creates and configures it, then re-run this script.
Banks are never created by this script.
MSG
  exit 1
fi

# run_transfer -> prints the reported (or, failing that, attempted) imported
# document count and returns 0; returns 1 on any failure, at any step, of
# the (deprecated) document-transfer export/import endpoints. The source
# bank is only ever read from in this function; the only write is the
# on_conflict=skip import into the destination bank.
run_transfer() {
  local qs id export_body op_id export_op dl_url key tmp_zip import_body import_op imported

  qs=""
  for id in "${TRANSFER_IDS[@]}"; do
    qs="${qs}&document_id=$(urlencode "$id")"
  done
  qs="${qs#&}"

  export_body="$(req POST "$API_URL/v1/default/banks/$SRC_BANK/document-transfer/export?$qs" "")" || return 1
  op_id="$(printf '%s' "$export_body" | json_path operation_id)"
  [ -n "$op_id" ] || return 1
  export_op="$(poll_operation "$SRC_BANK" "$op_id")" || return 1

  dl_url="$(printf '%s' "$export_op" | json_path result_metadata.download_url)"
  key="$(printf '%s' "$export_op" | json_path result_metadata.storage_key)"
  case "$dl_url" in
    http*) ;;
    /*) dl_url="$API_URL$dl_url" ;;
    *) [ -n "$key" ] && dl_url="$API_URL/v1/default/files/download/$key" ;;
  esac
  [ -n "$dl_url" ] || return 1

  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/seed-repo-bank.XXXXXX.zip")" || return 1
  req_download "$dl_url" "$tmp_zip" || { rm -f "$tmp_zip"; return 1; }

  import_body="$(req_upload "$API_URL/v1/default/banks/$DST_BANK/document-transfer?on_conflict=skip" "$tmp_zip")" \
    || { rm -f "$tmp_zip"; return 1; }
  rm -f "$tmp_zip"
  op_id="$(printf '%s' "$import_body" | json_path operation_id)"
  [ -n "$op_id" ] || return 1
  import_op="$(poll_operation "$DST_BANK" "$op_id")" || return 1

  imported="$(printf '%s' "$import_op" | json_path result_metadata.documents_imported)"
  [ -n "$imported" ] || imported="${#TRANSFER_IDS[@]}"
  printf '%s' "$imported"
}

transfer_count=0
transfer_skipped=0
if [ "${#TRANSFER_IDS[@]}" -gt 0 ]; then
  if transfer_count="$(run_transfer)"; then
    echo "seed-repo-bank: document-transfer reported $transfer_count imported (of ${#TRANSFER_IDS[@]} requested)"
  else
    echo "seed-repo-bank: document-transfer failed or timed out; skipping it and continuing with distill only (source bank untouched)" >&2
    transfer_skipped=1
    transfer_count=0
  fi
else
  echo "seed-repo-bank: no gitlog or mapped conversation documents found for $REPO; nothing to transfer"
fi

reflect_body="$(python3 -I -c '
import json, sys
print(json.dumps({"query": sys.argv[1], "budget": "low"}))
' "$REFLECT_QUERY")"
reflect_response="$(req POST "$API_URL/v1/default/banks/$SRC_BANK/reflect" "$reflect_body")" \
  || die "reflect on source bank $SRC_BANK failed"
reflect_text="$(printf '%s' "$reflect_response" | json_path text)"
[ -n "$reflect_text" ] || die "reflect on source bank $SRC_BANK returned no text"

retain_body="$(python3 -I -c '
import json, sys
print(json.dumps({
    "items": [{
        "content": sys.argv[1],
        "document_id": sys.argv[2],
        "tags": ["project:" + sys.argv[3], "source:migration"],
        "timestamp": "unset",
    }],
    "async": False,
}))
' "$reflect_text" "$DISTILL_DOC_ID" "$REPO")"
req POST "$API_URL/v1/default/banks/$DST_BANK/memories" "$retain_body" > /dev/null \
  || die "retain of distilled document into $DST_BANK failed"
echo "seed-repo-bank: retained distilled document \"$DISTILL_DOC_ID\" into $DST_BANK"

mkdir -p "$(dirname "$LEDGER_FILE")"
ts="$(TZ=Asia/Saigon date -Is)"
python3 -I -c '
import json, sys
rec = {
    "repo": sys.argv[1],
    "timestamp": sys.argv[2],
    "source_bank": sys.argv[3],
    "destination_bank": sys.argv[4],
    "transferred_count": int(sys.argv[5]),
    "transfer_skipped": sys.argv[6] == "1",
    "distill_document_id": sys.argv[7],
    "dry_run": False,
}
print(json.dumps(rec, ensure_ascii=False))
' "$REPO" "$ts" "$SRC_BANK" "$DST_BANK" "$transfer_count" "$transfer_skipped" "$DISTILL_DOC_ID" >> "$LEDGER_FILE"

echo "seed-repo-bank: done. Ledger: $LEDGER_FILE"
