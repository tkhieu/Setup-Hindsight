#!/bin/sh
# bin/seed-repo-bank.sh must refuse --source when it equals the computed
# destination bank (coding-agent::<repo>) -- reflecting/retaining a bank
# into itself, or document-transfer copying a bank onto itself, makes no
# sense and must be caught before any config/API access, not attempted.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/server-setup/bin/lib"
cp "$SS/bin/seed-repo-bank.sh" "$TMP/server-setup/bin/"
cp "$SS/bin/lib/json.sh" "$SS/bin/lib/transcripts.sh" "$TMP/server-setup/bin/lib/"
chmod +x "$TMP/server-setup/bin/seed-repo-bank.sh"

# Deliberately no coding-agent.json and no curl on PATH: this must be
# rejected before either is ever touched.
set +e
out="$("$TMP/server-setup/bin/seed-repo-bank.sh" repo --source coding-agent::repo 2>&1)"
rc=$?
set -e

[ "$rc" -ne 0 ] || { echo "$out"; echo "FAIL: expected a non-zero exit when --source equals the destination bank"; exit 1; }
printf '%s\n' "$out" | grep -q 'must not equal the destination bank' \
  || { echo "$out"; echo "FAIL: missing the source-equals-destination message"; exit 1; }

echo "ok - refuses --source equal to the destination bank, before touching config or the API"
