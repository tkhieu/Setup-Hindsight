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

# json_array_len   JSON array on stdin -> its length, or 0 (also 0 if the
# input isn't a JSON array at all, e.g. an error body)
json_array_len() {
  python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
print(len(d) if isinstance(d, list) else 0)
"
}

# json_array_find_number <key> <value>   JSON array on stdin -> the
# "number" field of the first object whose <key> equals <value> exactly, or ""
json_array_find_number() {
  local key="$1" value="$2"
  python3 -I -c "
import json, sys
key = sys.argv[1]
value = sys.argv[2]
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
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
