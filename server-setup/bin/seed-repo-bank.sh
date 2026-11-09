#!/usr/bin/env bash
# Seed a per-repo Hindsight bank (coding-agent::<repo>) once from the shared
# user bank, as part of the gradual split away from a single user-wide bank.
# See docs/RUNBOOK.md for the operator procedure this script implements.
#
# Usage: bin/seed-repo-bank.sh <repo-basename> [--dry-run] [--source BANK_ID]
#
# What it does, against the public Hindsight API (not the local docker
# stack -- this runs on a dev workstation, not the server):
#   1. Exact transfer: every conversation document whose session_id maps --
#      via a local Claude Code or Codex transcript -- to this repo's main
#      worktree. Copied via the (deprecated, async) document-transfer
#      export/import endpoints. `gitlog:<repo>` is deliberately NEVER
#      transferred: the coding-agent plugin creates and refreshes that
#      document itself in every bank it manages, so copying it would race
#      the plugin's own writes over one document id it already owns.
#      Conversation documents have no such owner -- their session_id is
#      tied to an already-finished past session, so nothing else can ever
#      recreate that exact document id.
#   2. Distill: `reflect` on the source bank with a fixed question set about
#      the repo, then `retain` the answer into the destination bank as
#      document `migrated:<source-bank>:<repo>`, tags `project:<repo>` and
#      `source:migration`. Retain's upsert-by-document_id makes a rerun
#      replace this one document rather than duplicate it.
#   3. Ledger: TWO JSONL lines appended to
#      server-setup/state/bank-seed-ledger.jsonl per real run -- one for the
#      transfer stage (written immediately once its outcome is known, BEFORE
#      distill even starts, so a distill failure never loses the transfer's
#      ownership record) and one for the distill stage (written after retain
#      succeeds). No memory content, only repo/counts/ids.
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
#
# `set +x` runs first and unconditionally, before anything else: xtrace
# prints each command with its variables already expanded, so a caller (or
# an inherited SHELLOPTS=xtrace / BASH_ENV) that turned tracing on would
# otherwise print the token straight out of the `printf '...Bearer %s...'
# "$AUTH_HEADER_ESCAPED"` calls below -- the one thing the `-K -` stdin
# convention exists to prevent. This line must stay first.
set +x
unset BASH_XTRACEFD
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/json.sh"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/transcripts.sh"

die() { echo "seed-repo-bank: $*" >&2; exit 1; }

usage() { echo "usage: bin/seed-repo-bank.sh <repo-basename> [--dry-run] [--source BANK_ID]" >&2; }

# Every temp file this script creates (document-listing pages, the
# downloaded transfer ZIP) is tracked here and removed on exit -- success,
# a `die`, or any other failure path -- not just along the happy path, so
# --dry-run (and a failing real run) never leaves scratch files behind.
#
# Each call site does `f="$(mktemp ...)" && TMP_FILES+=("$f")` as two
# separate statements -- NOT a `mktemp_tracked` helper that appends to
# TMP_FILES itself. A helper invoked as `x="$(mktemp_tracked)"` would run
# inside the command-substitution subshell `$(...)` forks, so its array
# append would mutate only that subshell's throwaway copy of TMP_FILES and
# vanish the moment the subshell exits -- the parent shell's TMP_FILES
# would stay empty and nothing would ever be cleaned up.
TMP_FILES=()
trap 'rm -f "${TMP_FILES[@]}"' EXIT

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
DISTILL_DOC_ID="migrated:$SRC_BANK:$REPO"

# A bank can't be its own migration source: reflect/retain would read and
# write the same bank, and document-transfer export+import would copy a
# bank's documents onto themselves.
[ "$SRC_BANK" != "$DST_BANK" ] || die "--source ($SRC_BANK) must not equal the destination bank ($DST_BANK)"

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
# returns 0; prints the body (or a curl-failure note) to stderr and returns
# 1 otherwise. curl's own exit status is checked explicitly -- a network
# failure (DNS, connection refused, timeout) never writes the %{http_code}
# suffix -w asks for, and without this check `status` would be empty and
# the `-lt 200`/`-ge 300` tests below would both silently error out false,
# falling through as if the call had succeeded with an empty body.
req() {
  local method="$1" url="$2" body="${3:-}" out rc status body_out
  if [ -n "$body" ]; then
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
      | curl -sS --max-time "$HTTP_TIMEOUT" -w '\n%{http_code}' -K - -X "$method" \
        -H 'Content-Type: application/json' -d "$body" "$url")"
    rc=$?
  else
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
      | curl -sS --max-time "$HTTP_TIMEOUT" -w '\n%{http_code}' -K - -X "$method" "$url")"
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "seed-repo-bank: curl exit $rc calling $method $url" >&2
    return 1
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
  local url="$1" file="$2" out rc status body_out
  out="$(printf 'header = "Authorization: Bearer %s"\nform = "file=@%s;type=application/octet-stream"\n' \
      "$AUTH_HEADER_ESCAPED" "$file" \
    | curl -sS --max-time "$HTTP_TIMEOUT" -w '\n%{http_code}' -K - -X POST "$url")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "seed-repo-bank: curl exit $rc uploading to $url" >&2
    return 1
  fi
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
  local url="$1" dest="$2" status rc
  status="$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH_HEADER_ESCAPED" \
    | curl -sS --max-time "$DOWNLOAD_TIMEOUT" -w '%{http_code}' -K - -X GET -o "$dest" "$url")"
  rc=$?
  [ "$rc" -eq 0 ] && [ "$status" -ge 200 ] && [ "$status" -lt 300 ]
}

urlencode() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# bank_exists <bank_id> -- 0 if it exists, 1 if confirmed missing (404).
# Any other HTTP status (including a curl-level failure, which leaves
# $status empty and falls into the `*)` default below) is treated as
# fatal: it means we can't trust our own read of bank state, so the script
# stops rather than guessing.
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

# poll_operation <bank> <operation_id> -> prints the final operation JSON
# and returns 0 once status=completed. Returns 1 ONLY on a definite,
# terminal failure the server itself reported (status=failed/cancelled/
# not_found) -- safe to treat as "this did not happen". Everything else
# that goes wrong while polling -- the GET itself failing (network error,
# 429, 5xx -- req() already turns all of those into a single "return 1"),
# or OPERATION_TIMEOUT elapsing while status is still pending/processing --
# returns 2: the outcome is genuinely unknown, NOT a failure, so the caller
# must record that as pending, never as skipped.
poll_operation() {
  local bank="$1" op_id="$2" start status body
  start="$SECONDS"
  while :; do
    if body="$(req GET "$API_URL/v1/default/banks/$bank/operations/$op_id")"; then
      status="$(printf '%s' "$body" | json_path status)"
      case "$status" in
        completed) printf '%s' "$body"; return 0 ;;
        failed|cancelled|not_found) echo "seed-repo-bank: operation $op_id ($bank) ended as $status" >&2; return 1 ;;
      esac
    else
      status="(poll request failed)"
    fi
    if [ $((SECONDS - start)) -ge "$OPERATION_TIMEOUT" ]; then
      echo "seed-repo-bank: operation $op_id ($bank) still $status after ${OPERATION_TIMEOUT}s -- outcome unknown, not retrying further this run" >&2
      return 2
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

# ledger_append <json-object-of-stage-specific-fields> -- merges the fields
# common to every entry (repo, timestamp, source/destination bank, dry_run)
# with the stage-specific object given, and appends one JSONL line.
ledger_append() {
  mkdir -p "$(dirname "$LEDGER_FILE")"
  local ts
  ts="$(TZ=Asia/Saigon date -Is)"
  python3 -I -c '
import json, sys
extra = json.loads(sys.argv[1])
rec = {
    "repo": sys.argv[2],
    "timestamp": sys.argv[3],
    "source_bank": sys.argv[4],
    "destination_bank": sys.argv[5],
    "dry_run": False,
}
rec.update(extra)
print(json.dumps(rec, ensure_ascii=False))
' "$1" "$REPO" "$ts" "$SRC_BANK" "$DST_BANK" >> "$LEDGER_FILE"
}

# ---------------------------------------------------------------------------
# Discovery (read-only; same for --dry-run and a real run)
# ---------------------------------------------------------------------------

echo "seed-repo-bank: repo=$REPO source=$SRC_BANK destination=$DST_BANK"

dst_exists=1
if ! bank_exists "$DST_BANK"; then dst_exists=0; fi

# Exact transfer: conversation documents only. `gitlog:<repo>` is
# deliberately excluded -- the coding-agent plugin itself creates and
# refreshes that document (and the per-bank survey baseline) in whichever
# bank is active, so this script copying it would race the plugin's own
# writes over a document id the plugin, not this script, owns. Confirmed
# by reading the plugin's own git.ts logic (gitLogIsCurrent / GITLOG_HEAD):
# it checks for and re-deepens `gitlog:<repo>` in the bank it is pointed
# at, independent of anything already sitting there. A conversation
# document has no such owner: its id is tied to an already-finished past
# session, so nothing else can ever recreate that exact id.
TRANSFER_IDS=()

conv_offset=0
tags_qs="tags=$(urlencode "source:chat")&tags_match=any_strict"
while :; do
  page_tmp="$(mktemp)"
  TMP_FILES+=("$page_tmp")
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

# A transfer candidate that already exists in the destination bank (e.g.
# because an earlier run of this same script already copied it) is never
# ours to claim as "newly confirmed imported" a second time, or something
# a rollback should attribute to a later run -- on_conflict=skip leaves it
# untouched either way. CONFIRMABLE_IDS is exactly the subset we can
# safely attribute to THIS run once the destination reports it present;
# checked once here, before any transfer is attempted, specifically so a
# later presence check can't mistake "was already there" for "we just
# created this".
PRE_EXISTING_IN_DST=()
CONFIRMABLE_IDS=()
if [ "$dst_exists" = 1 ]; then
  for id in "${TRANSFER_IDS[@]}"; do
    chk_tmp="$(mktemp)"
    TMP_FILES+=("$chk_tmp")
    req GET "$API_URL/v1/default/banks/$DST_BANK/documents?q=$(urlencode "$id")&limit=5" > "$chk_tmp" \
      || die "could not list documents on destination bank $DST_BANK"
    if [ "$(doc_id_exists "$chk_tmp" "$id")" = 1 ]; then
      PRE_EXISTING_IN_DST+=("$id")
    else
      CONFIRMABLE_IDS+=("$id")
    fi
  done
else
  CONFIRMABLE_IDS=("${TRANSFER_IDS[@]}")
fi

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
  echo "Transfer candidates (${#TRANSFER_IDS[@]}) -- conversation documents only, gitlog:$REPO is never transferred:"
  if [ "${#TRANSFER_IDS[@]}" -eq 0 ]; then
    echo "  (none found)"
  else
    printf '  %s\n' "${TRANSFER_IDS[@]}"
  fi
  if [ "${#PRE_EXISTING_IN_DST[@]}" -gt 0 ]; then
    echo "  (${#PRE_EXISTING_IN_DST[@]} of these already exist in the destination bank (an earlier run already"
    echo "   copied them) and would be left untouched by on_conflict=skip, never re-confirmed or re-rolled-back:"
    printf '     %s\n' "${PRE_EXISTING_IN_DST[@]}"
    echo "  )"
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

# run_transfer -> on a confirmed-completed import, returns 0 (the caller
# then calls confirm_imported_ids itself -- this function never trusts
# result_metadata.documents_imported, since the API's own OpenAPI schema
# marks result_metadata's shape as internal/unstable). On a definite,
# terminal failure at any step (exit 1), the caller treats this as "skip
# the copy, continue with distill". On exit 2 the export or import
# operation's outcome is unknown (see poll_operation) -- prints
# "<bank>\t<operation_id>" of the operation still in flight; the caller
# must record that as pending, never as skipped/0, since it may turn out
# to have succeeded by the time anyone looks again (see
# reconcile_pending_import, called on the next run). The source bank is
# only ever read from in this function; the only write is the
# on_conflict=skip import into the destination bank.
run_transfer() {
  local qs id export_body op_id export_op poll_rc dl_url key tmp_zip import_body

  qs=""
  for id in "${TRANSFER_IDS[@]}"; do
    qs="${qs}&document_id=$(urlencode "$id")"
  done
  qs="${qs#&}"

  export_body="$(req POST "$API_URL/v1/default/banks/$SRC_BANK/document-transfer/export?$qs" "")" || return 1
  op_id="$(printf '%s' "$export_body" | json_path operation_id)"
  [ -n "$op_id" ] || return 1
  if export_op="$(poll_operation "$SRC_BANK" "$op_id")"; then poll_rc=0; else poll_rc=$?; fi
  if [ "$poll_rc" -eq 2 ]; then printf '%s\t%s' "$SRC_BANK" "$op_id"; return 2; fi
  [ "$poll_rc" -eq 0 ] || return 1

  dl_url="$(printf '%s' "$export_op" | json_path result_metadata.download_url)"
  key="$(printf '%s' "$export_op" | json_path result_metadata.storage_key)"
  case "$dl_url" in
    http*) ;;
    /*) dl_url="$API_URL$dl_url" ;;
    *) [ -n "$key" ] && dl_url="$API_URL/v1/default/files/download/$key" ;;
  esac
  [ -n "$dl_url" ] || return 1

  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/seed-repo-bank.XXXXXX.zip")" || return 1
  TMP_FILES+=("$tmp_zip")
  req_download "$dl_url" "$tmp_zip" || { rm -f "$tmp_zip"; return 1; }

  import_body="$(req_upload "$API_URL/v1/default/banks/$DST_BANK/document-transfer?on_conflict=skip" "$tmp_zip")" \
    || { rm -f "$tmp_zip"; return 1; }
  rm -f "$tmp_zip"
  op_id="$(printf '%s' "$import_body" | json_path operation_id)"
  [ -n "$op_id" ] || return 1
  if poll_operation "$DST_BANK" "$op_id" >/dev/null; then poll_rc=0; else poll_rc=$?; fi
  if [ "$poll_rc" -eq 2 ]; then printf '%s\t%s' "$DST_BANK" "$op_id"; return 2; fi
  [ "$poll_rc" -eq 0 ] || return 1
}

# confirm_imported_ids <id>... -> prints a JSON array of the given ids that
# now exist in the destination bank. This is the ONLY source of truth this
# script uses for "what did this run actually create in the destination
# bank" -- never a count parsed out of an operation's result_metadata.
# Called with CONFIRMABLE_IDS after run_transfer returns 0 (freshly
# completed), or with a PREVIOUS run's recorded candidate list from
# reconcile_pending_import -- deliberately never with the CURRENT run's own
# CONFIRMABLE_IDS in that second case: by the time a pending operation is
# reconciled, the documents it just finished creating are already sitting
# in the destination bank, so a fresh "pre-existing in dst" check run at
# the very start of THIS invocation (before reconcile even looks at the
# operation) would wrongly see them as pre-existing and exclude them.
confirm_imported_ids() {
  local id tmp found=()
  for id in "$@"; do
    tmp="$(mktemp)"
    TMP_FILES+=("$tmp")
    req GET "$API_URL/v1/default/banks/$DST_BANK/documents?q=$(urlencode "$id")&limit=5" > "$tmp" \
      || die "could not list documents on destination bank $DST_BANK while confirming the transfer"
    if [ "$(doc_id_exists "$tmp" "$id")" = 1 ]; then
      found+=("$id")
    fi
  done
  python3 -I -c '
import json, sys
print(json.dumps(sys.argv[1:]))
' "${found[@]}"
}

# reconcile_pending_import -> finds the most recent ledger entry for this
# repo AND this --source bank whose stage="transfer", transfer_status=
# "pending", and whose operation_id has not already been resolved by a
# LATER entry's "reconciles" field (so a pending entry is reconciled AT
# MOST ONCE, no matter how many later runs happen before anyone notices --
# without this check, every run that doesn't independently resolve its own
# fresh transfer would keep re-finding the same old pending row forever and
# re-append a "resolved" entry for it every time). If that operation is now
# complete, prints "<operation_id>\t<confirm_imported_ids JSON>" so the
# caller can both skip resubmitting a fresh transfer AND record which
# pending entry this one resolves. Returns 1 if there is nothing to
# reconcile or it still isn't done -- the caller then falls through to a
# normal run_transfer attempt, always safe to retry (on_conflict=skip).
reconcile_pending_import() {
  local last_pending bank op_id attempted_json body status attempted_ids=() line
  [ -f "$LEDGER_FILE" ] || return 1
  last_pending="$(python3 -I -c '
import json, sys
repo, src = sys.argv[1], sys.argv[2]
records = [json.loads(l) for l in open(sys.argv[3]) if l.strip()]
resolved = {r["reconciles"] for r in records if r.get("reconciles")}
last = None
for rec in records:
    if rec.get("repo") != repo or rec.get("source_bank") != src:
        continue
    if rec.get("stage") != "transfer" or rec.get("transfer_status") != "pending":
        continue
    if rec.get("pending_operation_id") in resolved:
        continue
    last = rec
if last is not None:
    print((last.get("pending_bank") or "") + "\t" + (last.get("pending_operation_id") or "") + "\t"
          + json.dumps(last.get("attempted_confirmable_ids") or []))
' "$REPO" "$SRC_BANK" "$LEDGER_FILE" 2>/dev/null)" || return 1
  [ -n "$last_pending" ] || return 1
  bank="$(printf '%s' "$last_pending" | cut -f1)"
  op_id="$(printf '%s' "$last_pending" | cut -f2)"
  attempted_json="$(printf '%s' "$last_pending" | cut -f3)"
  [ "$bank" = "$DST_BANK" ] && [ -n "$op_id" ] || return 1

  body="$(req GET "$API_URL/v1/default/banks/$bank/operations/$op_id")" || return 1
  status="$(printf '%s' "$body" | json_path status)"
  [ "$status" = completed ] || return 1
  echo "seed-repo-bank: reconciled previously-pending import operation $op_id ($bank)" >&2

  while IFS= read -r line; do attempted_ids+=("$line"); done < <(python3 -I -c '
import json, sys
for x in json.loads(sys.argv[1]):
    print(x)
' "$attempted_json")
  printf '%s\t%s' "$op_id" "$(confirm_imported_ids "${attempted_ids[@]}")"
}

transfer_status="none"
confirmed_ids_json="[]"
pending_bank=""
pending_op_id=""
reconciles_op_id=""

if reconcile_out="$(reconcile_pending_import)"; then
  transfer_status="transferred"
  reconciles_op_id="${reconcile_out%%$'\t'*}"
  confirmed_ids_json="${reconcile_out#*$'\t'}"
elif [ "${#TRANSFER_IDS[@]}" -gt 0 ] && [ "${#CONFIRMABLE_IDS[@]}" -eq 0 ]; then
  # Every candidate already exists in the destination bank -- a common
  # case on a rerun. Nothing new to confirm, and no reason to hit the
  # deprecated document-transfer endpoints just to get a no-op skip back.
  transfer_status="transferred"
  echo "seed-repo-bank: all ${#TRANSFER_IDS[@]} transfer candidate(s) already exist in the destination bank; nothing new to copy"
elif [ "${#TRANSFER_IDS[@]}" -gt 0 ]; then
  if transfer_out="$(run_transfer)"; then transfer_rc=0; else transfer_rc=$?; fi
  case "$transfer_rc" in
    0)
      transfer_status="transferred"
      confirmed_ids_json="$(confirm_imported_ids "${CONFIRMABLE_IDS[@]}")"
      echo "seed-repo-bank: document-transfer completed; confirmed imported: $confirmed_ids_json (of ${#TRANSFER_IDS[@]} candidates, ${#PRE_EXISTING_IN_DST[@]} already present)"
      ;;
    2)
      transfer_status="pending"
      pending_bank="${transfer_out%%$'\t'*}"
      pending_op_id="${transfer_out#*$'\t'}"
      echo "seed-repo-bank: document-transfer outcome unknown (operation $pending_op_id on $pending_bank still running after ${OPERATION_TIMEOUT}s) -- recorded as pending, NOT skipped. Re-running this script later will check it and reconcile (docs/RUNBOOK.md)." >&2
      ;;
    *)
      transfer_status="skipped"
      echo "seed-repo-bank: document-transfer failed; skipping it and continuing with distill only (source bank untouched)" >&2
      ;;
  esac
else
  echo "seed-repo-bank: no conversation documents mapped to $REPO; nothing to transfer"
fi

attempted_confirmable_json="$(python3 -I -c '
import json, sys
print(json.dumps(sys.argv[1:]))
' "${CONFIRMABLE_IDS[@]}")"

# Transfer stage: written immediately, before distill even starts, so a
# distill failure below can never lose this run's transfer ownership
# record (see the module header and reconcile_pending_import).
ledger_append "$(python3 -I -c '
import json, sys
confirmed_ids = json.loads(sys.argv[2])
print(json.dumps({
    "stage": "transfer",
    # transfer_status: "transferred" (confirmed_document_ids is the real
    # list, incl. reconciled), "skipped" (a terminal failure the server
    # itself reported -- safe to treat as not copied), "pending" (outcome
    # unknown -- a timeout or a transient poll error, NOT the same as
    # skipped), or "none" (nothing to copy).
    "transfer_status": sys.argv[1],
    # Exactly what this run (or a later reconcile of it) confirmed present
    # in the destination bank that was NOT there before -- never a count
    # trusted from the transfer operation'"'"'s own result_metadata. This is
    # the list docs/RUNBOOK.md rollback deletes; it never includes a
    # document that already existed in the destination bank beforehand.
    "confirmed_document_ids": confirmed_ids,
    "transferred_count": len(confirmed_ids),
    "pending_bank": sys.argv[3] or None,
    "pending_operation_id": sys.argv[4] or None,
    # The candidate set checked THIS run (excluding anything already
    # present in the destination bank before this run started). Recorded
    # on every entry, not just "pending" ones, but it only matters for a
    # later reconcile_pending_import: it checks exactly these ids, not
    # whatever a future run'"'"'s own fresh pre-existing check would compute,
    # which by then could wrongly see these as pre-existing (they would
    # have just landed from the very operation being reconciled).
    "attempted_confirmable_ids": json.loads(sys.argv[5]),
    # Set only when this entry resolves an earlier "pending" entry: the
    # operation_id of that entry, so reconcile_pending_import never
    # re-resolves (and re-appends a duplicate "transferred" entry for) the
    # same pending row on some later run.
    "reconciles": sys.argv[6] or None,
}))
' "$transfer_status" "$confirmed_ids_json" "$pending_bank" "$pending_op_id" "$attempted_confirmable_json" "$reconciles_op_id")"

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
        # Explicit, not relying on the documented default for retain: a
        # rerun must replace this one document (delete + reprocess), never
        # duplicate it, which is exactly what makes this idempotent.
        "update_mode": "replace",
    }],
    "async": False,
}))
' "$reflect_text" "$DISTILL_DOC_ID" "$REPO")"
req POST "$API_URL/v1/default/banks/$DST_BANK/memories" "$retain_body" > /dev/null \
  || die "retain of distilled document into $DST_BANK failed"
echo "seed-repo-bank: retained distilled document \"$DISTILL_DOC_ID\" into $DST_BANK"

# Distill stage: its own entry, separate from the transfer stage above.
ledger_append "$(python3 -I -c '
import json, sys
print(json.dumps({"stage": "distill", "distill_document_id": sys.argv[1]}))
' "$DISTILL_DOC_ID")"

echo "seed-repo-bank: done. Ledger: $LEDGER_FILE"
