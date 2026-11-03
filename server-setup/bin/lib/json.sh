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
