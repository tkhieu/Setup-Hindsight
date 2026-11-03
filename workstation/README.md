# Hindsight trên máy phát triển

Installer dùng tích hợp chính thức `@vectorize-io/hindsight-coding-agents@0.8.2` (bản đi cùng Hindsight server v1.1.0) và tắt tự cập nhật để giữ đúng phiên bản. Tích hợp đăng ký MCP và hooks tự nhớ/tự gọi lại cho Claude Code (user scope) và Codex. Cả hai dùng chung một bank, mặc định `user-<tên đăng nhập>`; đổi `HINDSIGHT_BANK` nếu cần chia sẻ giữa các máy hoặc tách dữ liệu. Mặc định này đơn giản cho một người dùng, nhưng các dự án cùng bank sẽ chia sẻ ký ức.

```sh
workstation/bin/hindsight-client-setup --dry-run
workstation/bin/hindsight-client-setup install
workstation/bin/hindsight-client-setup --status
workstation/bin/hindsight-client-setup --uninstall
```

Lần cài đầu tạo `~/.config/hindsight/client.env` từ `workstation/client.env.example`; điền `HINDSIGHT_API_KEY` rồi chạy lại. File phải có quyền `600`. Biến môi trường `HINDSIGHT_URL`, `HINDSIGHT_API_KEY`, `HINDSIGHT_BANK` ghi đè file. URL mặc định là `https://hindsight-api.hieutk.dev`. Cần Node.js/npm (`npx`), Claude Code, Codex, `curl` và Python 3.11+. Installer kiểm tra `/health` và GET `/v1/default/banks` có xác thực trước khi cài.

Tích hợp chính thức lưu cấu hình tại `~/.hindsight/coding-agent.json` (bản sao trước thay đổi ở `.hindsight-client-backup`), hooks tại cấu hình Claude/Codex, và skill này tại `~/.claude/skills` cùng `~/.codex/skills`. Nếu `[features]` đã có trong cấu hình Codex, installer bật `hooks = true` và sao lưu file trước khi sửa. Lệnh gỡ giữ file cấu hình và khóa để cài lại. Sau khi cài, mở phiên Claude Code hoặc Codex mới.

Lỗi 401: đối chiếu API key với server. Lỗi kết nối: kiểm tra Cloudflare Tunnel và `/health`. Sai ký ức: đối chiếu `HINDSIGHT_BANK` trên các máy và chạy lại `install`.
