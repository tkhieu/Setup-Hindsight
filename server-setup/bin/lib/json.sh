# shellcheck shell=bash
# JSON helpers for release and GHCR responses in bin/check-upstream.sh.

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

# json_path <dotted.path>   JSON object on stdin -> the value at that path,
# rendered as plain text (a nested object/array prints as compact JSON), or
# "" if any segment is missing or the input isn't valid JSON. Used by
# bin/seed-repo-bank.sh to read operation status and result_metadata fields
# whose nesting varies by endpoint. The path is passed as argv, not
# interpolated into the script source, so it is safe even if it ever carries
# untrusted content.
json_path() {
  local path="$1"
  python3 -I -c "
import json, sys
path = sys.argv[1]
try:
    cur = json.load(sys.stdin)
except Exception:
    cur = None
for part in path.split('.'):
    cur = cur.get(part) if isinstance(cur, dict) else None
if cur is None:
    print('')
elif isinstance(cur, bool):
    print('true' if cur else 'false')
elif isinstance(cur, (str, int, float)):
    print(cur)
else:
    print(json.dumps(cur))
" "$path"
}
