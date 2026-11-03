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
if [ -f "$CONFIG_DIR/secrets.env" ]; then
  echo "secrets.env already exists — leaving it as-is."
else
  umask 077
  cp "$CONFIG_DIR/secrets.env.example" "$CONFIG_DIR/secrets.env"
  chmod 600 "$CONFIG_DIR/secrets.env"
  for k in HINDSIGHT_DB_PASSWORD HINDSIGHT_API_TENANT_API_KEY HINDSIGHT_CP_ACCESS_KEY; do
    sed -i "s|^${k}=\$|${k}=$(openssl rand -hex 32)|" "$CONFIG_DIR/secrets.env"
  done
  echo "generated HINDSIGHT_DB_PASSWORD, HINDSIGHT_API_TENANT_API_KEY, HINDSIGHT_CP_ACCESS_KEY -> secrets.env (chmod 600)"
  echo "still blank, must be filled by hand: HINDSIGHT_API_LLM_API_KEY (OpenAI), RCLONE_CONFIG_R2_* (R2), CLOUDFLARED_CREDENTIALS_FILE (path, see cloudflared/)."
fi

llm_key="$(env_get "$CONFIG_DIR/secrets.env" HINDSIGHT_API_LLM_API_KEY)"
if [ -z "$llm_key" ]; then
  cat <<TXT

Chưa chạy được: HINDSIGHT_API_LLM_API_KEY còn trống trong secrets.env.
  1. vim $CONFIG_DIR/secrets.env    # điền OpenAI key vào HINDSIGHT_API_LLM_API_KEY
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
"$HS" up -d

say "Waiting for /health"
"$HS" ready

api_key="$(env_get "$CONFIG_DIR/secrets.env" HINDSIGHT_API_TENANT_API_KEY)"
cp_key="$(env_get "$CONFIG_DIR/secrets.env" HINDSIGHT_CP_ACCESS_KEY)"
cat <<TXT

Xong. Bước tiếp theo:

  1. Backup secrets.env ra ngoài server (password manager / máy khác).
  2. Từ máy dev, mở tunnel để thử:
       ssh -L 8888:127.0.0.1:8888 -L 9999:127.0.0.1:9999 hieu@100.77.187.94
     API key (agents/MCP, header Authorization: Bearer <key>):
       $api_key
     UI login (http://localhost:9999):
       $cp_key
  3. Smoke test: bin/smoke.sh
  4. Cấu hình R2 + cloudflared + systemd timer: docs/PLAYBOOK.md §4.
TXT
