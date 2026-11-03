# Setup-Hindsight

Self-host [Hindsight](https://hindsight.vectorize.io) (agent memory của Vectorize)
trên server `hieu@100.77.187.94` — cùng máy với Omnigent và Multica, theo đúng
khuôn của `Setup-Omnigent` / `Setup-Multica`.

| Thư mục / tài liệu | Dùng khi |
|---|---|
| `docs/PLAYBOOK.md` | vận hành: cài lần đầu, lệnh hằng ngày, upgrade/rollback, backup, diễn tập restore, sự cố |
| `server-setup/` | compose override, env, script (`bin/`), systemd timer, cloudflared |
| `docs/CLIENT_SETUP.md` | nối Claude Code và Codex trên máy dev vào Hindsight (cài plugin, tạo `client.env`, chạy setup) |
| `plugins/hindsight-client/` | plugin marketplace cho Claude Code và Codex: skill + installer |
| `workstation/` | wrapper chạy installer từ bản checkout, test |

Quyết định đã chốt:

- Hindsight chạy bằng image pin phiên bản (`version.env`) + Postgres pgvector riêng.
- LLM provider: mặc định `chatgpt` (gói ChatGPT Pro qua Sign in with ChatGPT);
  đổi `HINDSIGHT_API_LLM_PROVIDER=openai` trong `base.env` để quay lại API key.
- Backup: `pg_dump` lên Cloudflare R2 qua rclone, không mã hoá, script không bao giờ xoá
  (hết hạn do R2 lifecycle rule).
- Diễn tập restore định kỳ vào DB tạm, không đụng instance đang chạy.

Không bao giờ commit `secrets.env`, API key, token R2/Cloudflare.
