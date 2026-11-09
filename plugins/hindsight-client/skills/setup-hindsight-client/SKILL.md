---
name: setup-hindsight-client
description: Cài đặt, kiểm tra hoặc gỡ Hindsight self-hosted cho Claude Code và Codex trên máy phát triển.
---

# Hindsight client

Khi skill đến từ marketplace, tìm thư mục plugin chứa file SKILL.md này (`skills/setup-hindsight-client/SKILL.md`), rồi chạy script tại `../../scripts/hindsight-client-setup` với `HINDSIGHT_CLIENT_PLUGIN_MODE=1`. Biến này tránh tạo skill symlink trùng với skill đã có trong plugin. Khi dùng bản checkout, có thể chạy `workstation/bin/hindsight-client-setup` trực tiếp. Dùng `--dry-run` để xem kế hoạch, `install` (hoặc không đối số) để cài, `--status` để kiểm tra, `--uninstall` để gỡ. Hỏi người dùng cung cấp API key qua file riêng hoặc môi trường nếu còn thiếu; không ghi key vào plugin.

Cấu hình nằm tại `~/.config/hindsight/client.env` (quyền 600); installer tạo file từ `client.env.example` trong plugin nếu thiếu. Điền `HINDSIGHT_API_KEY` vào file hoặc cung cấp qua môi trường. Không in, ghi log hoặc đưa khóa vào lệnh shell hiển thị. `HINDSIGHT_URL` mặc định là `https://hindsight-api.hieutk.dev`. Bank mặc định là `coding-agent::{gitProject}` theo repo: `gitProject` là tên thư mục main worktree, linked worktree dùng cùng bank, hai repo có cùng tên thư mục main worktree sẽ trùng bank. Đặt `HINDSIGHT_BANK=user-hieu` và chạy lại `install` nếu muốn dùng bank chung; xem [`CLIENT_SETUP.md`](../../../../docs/CLIENT_SETUP.md) để tra bank cũ một phiên bằng `HINDSIGHT_BANK_ID` và [`RUNBOOK.md`](../../../../docs/RUNBOOK.md) để seed ký ức cũ. Tích hợp chính thức lưu cấu hình chạy ở `~/.hindsight/coding-agent.json` và tự đăng ký hooks, MCP. Plugin chỉ đóng gói skill và script; không chứa khóa, MCP hay hooks để tránh đăng ký trùng với tích hợp chính thức.

Khi lỗi:

- HTTP 401: kiểm tra khóa trong `client.env` và khóa trên server; thử lại `--status`.
- Không kết nối hoặc `/health` lỗi: kiểm tra DNS, Cloudflare Tunnel và dịch vụ Hindsight trên server.
- Không thấy ký ức đúng: kiểm tra tên main worktree của repo và `HINDSIGHT_BANK` nếu có; cài lại sau khi đổi bank. Bank chỉ xuất hiện sau khi có dữ liệu; xem [`RUNBOOK.md`](../../../../docs/RUNBOOK.md) để seed ký ức cũ.
- MCP hoặc hook thiếu: chạy lại `install`, kiểm tra `~/.claude/settings.json`, `~/.codex/hooks.json` và `~/.codex/config.toml`; khởi động phiên agent mới.
- Nếu thấy cảnh báo `Codex hooks chưa bật`, thêm `[features]` và `hooks = true` vào `~/.codex/config.toml`, rồi mở phiên Codex mới.

`--uninstall` giữ lại file chứa khóa và cấu hình Hindsight để người dùng có thể cài lại. Không tự ý xóa các file này.
