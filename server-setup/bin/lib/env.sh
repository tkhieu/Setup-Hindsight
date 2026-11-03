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
