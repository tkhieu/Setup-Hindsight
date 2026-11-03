# Setup-Hindsight

Self-host [Hindsight](https://hindsight.vectorize.io) (agent memory của Vectorize)
trên server `hieu@100.77.187.94` — cùng máy với Omnigent và Multica, theo đúng
khuôn của `Setup-Omnigent` / `Setup-Multica`.

| Thư mục / tài liệu | Dùng khi |
|---|---|
| `docs/PLAYBOOK.md` | vận hành: cài lần đầu, lệnh hằng ngày, upgrade/rollback, backup, diễn tập restore, sự cố |
| `server-setup/` | compose override, env, script (`bin/`), systemd timer, cloudflared |
| `workstation/` | nối agent trên máy dev (Claude Code, Codex) vào Hindsight qua MCP |

Quyết định đã chốt:

- Hindsight chạy bằng image pin phiên bản (`version.env`) + Postgres pgvector riêng.
- LLM provider: OpenAI.
- Backup: `pg_dump` lên Cloudflare R2 qua rclone, không mã hoá, script không bao giờ xoá
  (hết hạn do R2 lifecycle rule).
- Diễn tập restore định kỳ vào DB tạm, không đụng instance đang chạy.

Không bao giờ commit `secrets.env`, API key, token R2/Cloudflare.
