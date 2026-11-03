---
name: setup-hindsight-client
description: Cài đặt, kiểm tra hoặc gỡ Hindsight self-hosted cho Claude Code và Codex trên máy phát triển.
---

# Hindsight client

Chạy `workstation/bin/hindsight-client-setup` từ bản checkout của Setup-Hindsight. Dùng `--dry-run` để xem kế hoạch, `install` (hoặc không đối số) để cài, `--status` để kiểm tra, `--uninstall` để gỡ.

Cấu hình nằm tại `~/.config/hindsight/client.env` (quyền 600); installer tạo file từ `workstation/client.env.example` nếu thiếu. Điền `HINDSIGHT_API_KEY` vào file hoặc cung cấp qua môi trường. Không in, ghi log hoặc đưa khóa vào lệnh shell hiển thị. `HINDSIGHT_URL` mặc định là `https://hindsight-api.hieutk.dev`; `HINDSIGHT_BANK` mặc định `user-<tên đăng nhập>` và dùng chung cho Claude Code cùng Codex. Tích hợp chính thức lưu cấu hình chạy ở `~/.hindsight/coding-agent.json` và tự đăng ký hooks, MCP.

Khi lỗi:

- HTTP 401: kiểm tra khóa trong `client.env` và khóa trên server; thử lại `--status`.
- Không kết nối hoặc `/health` lỗi: kiểm tra DNS, Cloudflare Tunnel và dịch vụ Hindsight trên server.
- Không thấy ký ức đúng: so sánh `HINDSIGHT_BANK` trên các máy; cài lại sau khi đổi bank. Bank chỉ xuất hiện sau khi có dữ liệu.
- MCP hoặc hook thiếu: chạy lại `install`, kiểm tra `~/.claude/settings.json`, `~/.codex/hooks.json` và `~/.codex/config.toml`; khởi động phiên agent mới.
- Nếu thấy cảnh báo `Codex hooks chưa bật`, thêm `[features]` và `hooks = true` vào `~/.codex/config.toml`, rồi mở phiên Codex mới.

`--uninstall` giữ lại file chứa khóa và cấu hình Hindsight để người dùng có thể cài lại. Không tự ý xóa các file này.
