#!/bin/sh
# Keep the API's full-reflect deadline above its 300s upstream default and
# below the seed client's 900s SSH-forward HTTP deadline.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
KEY=HINDSIGHT_API_REFLECT_WALL_TIMEOUT

base_value="$(sed -n "s/^${KEY}=\([0-9][0-9]*\)$/\1/p" "$SS/base.env")"
[ -n "$base_value" ] || { echo "base.env has no numeric $KEY"; exit 1; }
[ "$base_value" -gt 300 ] || { echo "$KEY must exceed the 300s upstream default"; exit 1; }
[ "$base_value" -lt 900 ] || { echo "$KEY must leave room below the seed's 900s HTTP limit"; exit 1; }

hindsight_block="$(awk '
  /^  hindsight:$/ { grab=1; next }
  grab && /^  [a-zA-Z0-9_-]+:$/ { exit }
  grab { print }
' "$SS/compose.yaml")"
[ -n "$hindsight_block" ] || { echo "compose.yaml has no hindsight service"; exit 1; }
printf '%s\n' "$hindsight_block" | grep -Fqx "      ${KEY}: \${${KEY}:-${base_value}}" \
  || { echo "hindsight service does not pass $KEY from base.env"; exit 1; }

echo "ok: $KEY = ${base_value}s in base.env and hindsight compose environment"
