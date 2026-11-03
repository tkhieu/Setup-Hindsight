# shellcheck shell=bash
# JSON helpers for bin/check-upstream.sh — no jq on the server. python3 is a
# REQUIRED dependency (confirmed present on the server; the caller checks
# for it at startup and fails loud if missing — see check-upstream.sh) and
# is the only thing used here: parsing a JSON array (the issues listing)
# or encoding an arbitrary string into a JSON string literal without a
# real parser is a correctness trap no sed/awk fallback is worth keeping.

# json_str <key>   JSON object on stdin -> that key's string value, or ""
json_str() {
  local key="$1"
  python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
v = d.get('$key')
print(v if isinstance(v, str) else '')
"
}

# json_bool <key>   JSON object on stdin -> "true", "false", or ""
json_bool() {
  local key="$1"
  python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
v = d.get('$key')
print('true' if v is True else ('false' if v is False else ''))
"
}

# json_array_len   JSON array on stdin -> its length, exit 0. On anything
# that is NOT a well-formed JSON array (invalid JSON, or valid JSON that
# isn't a list — e.g. an error object GitHub returned with HTTP 200, which
# does happen) prints nothing and exits 1: callers MUST treat that as an API
# error, never as "0 issues found" — silently treating a malformed body as
# an empty list is exactly what would let the issue-dedupe lookup miss a
# real match and spam a duplicate.
json_array_len() {
  python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, list):
    sys.exit(1)
print(len(d))
"
}

# json_array_find_number <key> <value>   JSON array on stdin -> the
# "number" field of the first object whose <key> equals <value> exactly, or
# "" if genuinely not found. Exits 1 (prints nothing) on anything that
# isn't a well-formed JSON array — same reasoning as json_array_len: a
# malformed body must never be read as "no match", only callers that
# already checked json_array_len are expected to reach this.
json_array_find_number() {
  local key="$1" value="$2"
  python3 -I -c "
import json, sys
key = sys.argv[1]
value = sys.argv[2]
try:
    items = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(items, list):
    sys.exit(1)
for it in items:
    if isinstance(it, dict) and it.get(key) == value:
        print(it.get('number', ''))
        break
" "$key" "$value"
}

# json_issue_payload <title> <body> <label>   -> a GitHub "create issue"
# JSON object on stdout, built with json.dumps (not string concatenation —
# title/body can contain anything, including quotes and newlines).
json_issue_payload() {
  python3 -I -c "
import json, sys
title, body, label = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({'title': title, 'body': body, 'labels': [label]}, separators=(',', ':'), ensure_ascii=False))
" "$1" "$2" "$3"
}

# json_label_payload <name> <color> <description>   -> a GitHub "create
# label" JSON object on stdout.
json_label_payload() {
  python3 -I -c "
import json, sys
name, color, desc = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({'name': name, 'color': color, 'description': desc}, separators=(',', ':'), ensure_ascii=False))
" "$1" "$2" "$3"
}

# json_has_error_code <code>   GitHub error JSON object on stdin -> exit 0
# if its "errors" array contains an entry whose "code" is exactly <code>,
# exit 1 otherwise (including malformed input or a missing/non-array
# "errors" field). Used to tell a real "already exists" 422 apart from any
# other validation failure that also happens to be a 422 — GitHub's label
# create returns {"errors":[{"resource":"Label","code":"already_exists",...}]}
# specifically for the former; treating EVERY 422 as "already exists"
# would silently swallow a genuinely broken request.
json_has_error_code() {
  local code="$1"
  python3 -I -c "
import json, sys
code = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
errors = d.get('errors') if isinstance(d, dict) else None
if isinstance(errors, list) and any(isinstance(e, dict) and e.get('code') == code for e in errors):
    sys.exit(0)
sys.exit(1)
" "$code"
}
