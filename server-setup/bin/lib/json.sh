# shellcheck shell=bash
# Minimal JSON helpers for bin/check-upstream.sh — no jq on the server.
# python3 is already a hard dependency of this repo (bin/install-systemd.sh
# checks for it, and bin/restore-db.sh's --drill-full path already uses it
# unconditionally for JSON) and is preferred here too: it is the only path
# that can safely parse a JSON array (the open-issues listing) or escape an
# arbitrary multi-line string (an issue body) into a JSON string literal.
# The sed/awk fallback below only ever reads a single flat top-level
# string/bool field out of one JSON object — a deliberately narrow case,
# used only if python3 is ever missing.
HAVE_PYTHON3=0
command -v python3 >/dev/null 2>&1 && HAVE_PYTHON3=1

# json_str <key>   JSON object on stdin -> that key's string value, or ""
json_str() {
  local key="$1"
  if [ "$HAVE_PYTHON3" = 1 ]; then
    python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
v = d.get('$key')
print(v if isinstance(v, str) else '')
"
  else
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"\\\\]\|\\\\.\)*\"" | head -1 \
      | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"(.*)"$/\1/'
  fi
}

# json_bool <key>   JSON object on stdin -> "true", "false", or ""
json_bool() {
  local key="$1"
  if [ "$HAVE_PYTHON3" = 1 ]; then
    python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
v = d.get('$key')
print('true' if v is True else ('false' if v is False else ''))
"
  else
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\(true\|false\)" | head -1 | sed -E 's/.*:[[:space:]]*//'
  fi
}

# json_escape   raw text on stdin -> JSON-escaped text on stdout (no
# surrounding quotes added — caller wraps it in "..."). Without python3,
# only backslash/quote/newline are escaped (enough for ASCII issue titles
# and bodies built entirely by check-upstream.sh itself, never from
# untrusted upstream content beyond plain release-note text).
json_escape() {
  if [ "$HAVE_PYTHON3" = 1 ]; then
    python3 -I -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])'
  else
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g'
  fi
}

# json_array_find_number <key> <value>   JSON array on stdin -> the
# "number" field of the first object whose <key> equals <value> exactly, or
# "". Requires python3 — a real array scan without a JSON parser is not
# attempted; the sed/awk fallback path (no python3) always returns empty,
# and callers must treat that the same as "not found" (so a missing python3
# costs at most a duplicate issue being opened, never a crash).
json_array_find_number() {
  local key="$1" value="$2"
  [ "$HAVE_PYTHON3" = 1 ] || return 0
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
