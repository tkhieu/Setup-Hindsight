#!/usr/bin/env bash
# First install on the server, under ~/hindsight. Idempotent — safe to
# re-run. Usage: bin/bootstrap.sh
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
HS="$CONFIG_DIR/bin/hs"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Checking dependencies"
for c in docker openssl curl; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 \
  || { echo "need Docker Compose v2 (docker compose). v1 is not supported." >&2; exit 1; }

mkdir -p "$CONFIG_DIR/backups"

say "Generating secrets"
umask 077
if [ ! -f "$CONFIG_DIR/secrets.env" ]; then
  cp "$CONFIG_DIR/secrets.env.example" "$CONFIG_DIR/secrets.env"
fi
chmod 600 "$CONFIG_DIR/secrets.env"
generated=0
for k in HINDSIGHT_DB_PASSWORD HINDSIGHT_API_TENANT_API_KEY HINDSIGHT_CP_ACCESS_KEY; do
  if env_is_blank "$CONFIG_DIR/secrets.env" "$k"; then
    (
      secret_tmp="$(mktemp "$CONFIG_DIR/.secrets.env.XXXXXX")"
      trap 'rm -f "$secret_tmp"' EXIT
      GENERATED_SECRET="$(openssl rand -hex 32)" awk -v key="$k" '
        index($0, key "=") == 1 {
          value = substr($0, length(key) + 2)
          gsub(/\r/, "", value)
          if (value ~ /^[[:space:]]*$/) {
            ending = (substr($0, length($0), 1) == "\r" ? "\r" : "")
            print key "=" ENVIRON["GENERATED_SECRET"] ending
            found = 1
            next
          }
        }
        { print }
        END { if (!found) print key "=" ENVIRON["GENERATED_SECRET"] }
      ' "$CONFIG_DIR/secrets.env" > "$secret_tmp"
      chmod 600 "$secret_tmp"
      mv "$secret_tmp" "$CONFIG_DIR/secrets.env"
    )
    echo "generated $k"
    generated=1
  fi
done
if [ "$generated" -eq 0 ]; then echo "all generated secrets already set"; fi

provider="$(env_get "$CONFIG_DIR/base.env" HINDSIGHT_API_LLM_PROVIDER)"
if [ "$provider" != chatgpt ] && env_is_blank "$CONFIG_DIR/secrets.env" HINDSIGHT_API_LLM_API_KEY; then
  cat <<TXT

Chưa chạy được: HINDSIGHT_API_LLM_API_KEY còn trống trong secrets.env (provider ${provider:-openai}).
  1. vim $CONFIG_DIR/secrets.env    # điền API key vào HINDSIGHT_API_LLM_API_KEY
  2. bin/bootstrap.sh               # chạy lại — các secret đã sinh được giữ nguyên

R2 (RCLONE_CONFIG_R2_*) và CLOUDFLARED_CREDENTIALS_FILE không bắt buộc để
khởi động, nhưng cần trước khi bật backup lên R2 (bin/install-systemd.sh)
và tunnel (docs/PLAYBOOK.md §4).
TXT
  exit 0
fi

say "Pulling images"
"$HS" pull

say "Starting"
if ! "$HS" up -d; then
  if [ "$provider" = chatgpt ]; then
    echo "Cài ChatGPT credential bằng bin/chatgpt-login.sh theo docs/PLAYBOOK.md §4, rồi chạy lại bin/bootstrap.sh." >&2
  fi
  exit 1
fi

say "Waiting for /health"
"$HS" ready

cat <<TXT

Xong. Bước tiếp theo:

  1. Backup secrets.env ra ngoài server (password manager / máy khác).
  2. Từ máy dev, mở tunnel để thử:
       ssh -L 8888:127.0.0.1:8888 -L 9999:127.0.0.1:9999 hieu@100.77.187.94
     API key (agents/MCP) và UI login nằm trong secrets.env.
  3. Smoke test: bin/smoke.sh
  4. Cấu hình R2 + cloudflared + systemd timer: docs/PLAYBOOK.md §4.
TXT
