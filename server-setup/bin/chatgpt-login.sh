#!/usr/bin/env bash
# Install laptop ChatGPT credentials over stdin; never expose tokens in argv.
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
check_generated_secrets() {
  local key
  for key in HINDSIGHT_DB_PASSWORD HINDSIGHT_API_TENANT_API_KEY HINDSIGHT_CP_ACCESS_KEY; do
    if [ ! -f "$CONFIG_DIR/secrets.env" ] || env_is_blank "$CONFIG_DIR/secrets.env" "$key"; then
      echo "chatgpt-login: $key is missing or empty in secrets.env — run bin/bootstrap.sh first." >&2
      exit 1
    fi
  done
}
compose() {
  check_generated_secrets
  docker compose -f "$CONFIG_DIR/compose.yaml" \
    --env-file "$CONFIG_DIR/version.env" \
    --env-file "$CONFIG_DIR/base.env" \
    --env-file "$CONFIG_DIR/secrets.env" "$@"
}

case "${1:-}" in
  --status)
    [ "$#" -eq 1 ] || { echo "usage: chatgpt-login.sh [--status]" >&2; exit 2; }
    compose run --rm -T --no-deps hindsight hindsight-admin chatgpt status
    ;;
  '')
    compose up -d chatgpt-volume-init
    # The container trap removes the staged file on success and every failure.
    # shellcheck disable=SC2016 # Expanded by sh inside the container.
    compose run --rm -T --no-deps hindsight sh -c '
      set -eu
      umask 077
      tmp=$(mktemp "$HINDSIGHT_API_LLM_CHATGPT_HOME/.import.XXXXXX")
      trap '\''rm -f "$tmp"'\'' EXIT
      cat > "$tmp"
      hindsight-admin chatgpt login --from-file "$tmp"
      hindsight-admin chatgpt status
    '
    ;;
  *) echo "usage: chatgpt-login.sh [--status]" >&2; exit 2 ;;
esac
