#!/usr/bin/env bash
# Read a literal KEY=value file; the last matching line wins.
env_get() {
  local file="$1" key="$2"
  awk -v key="$key" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$file"
}

env_is_blank() {
  local value
  value="$(env_get "$1" "$2")"
  [[ "$value" =~ ^[[:space:]]*$ ]]
}

# image_suffix <version.env> -- the hindsight image tag suffix compose.yaml
# pulls: `hindsight:${HINDSIGHT_VERSION}${HINDSIGHT_IMAGE_SUFFIX--slim}`.
# Same `${VAR-default}` semantics: UNSET -> "-slim", set-but-EMPTY -> ""
# (the full image). Precedence matches Compose interpolation: a value in
# the shell environment wins over version.env (bin/hs passes version.env
# via --env-file, which Compose ranks below shell env).
image_suffix() {
  local file="$1"
  if [ -n "${HINDSIGHT_IMAGE_SUFFIX+x}" ]; then
    printf '%s\n' "$HINDSIGHT_IMAGE_SUFFIX"
  elif grep -q '^HINDSIGHT_IMAGE_SUFFIX=' "$file" 2>/dev/null; then
    env_get "$file" HINDSIGHT_IMAGE_SUFFIX
  else
    printf '%s\n' "-slim"
  fi
}
