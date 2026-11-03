#!/bin/sh
# Runs every tests/test_*.sh (POSIX sh, each self-contained: sets up its own
# scratch dir with fake binaries, asserts, cleans up). Usage: tests/run.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0

for t in "$HERE"/test_*.sh; do
  [ -f "$t" ] || continue
  name="$(basename "$t")"
  out="$(mktemp)"
  if sh "$t" >"$out" 2>&1; then
    echo "ok   - $name"
    pass=$((pass + 1))
  else
    echo "FAIL - $name"
    sed 's/^/    /' "$out"
    fail=$((fail + 1))
  fi
  rm -f "$out"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
