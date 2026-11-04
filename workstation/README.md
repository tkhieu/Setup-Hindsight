# Hindsight trên máy phát triển

Installer dùng tích hợp chính thức `@vectorize-io/hindsight-coding-agents@0.8.5` (mới hơn bản 0.8.4 đi cùng Hindsight server v1.2.0) và tắt tự cập nhật để giữ đúng phiên bản. Tích hợp đăng ký MCP và hooks tự nhớ/tự gọi lại cho Claude Code (user scope) và Codex. Cả hai dùng chung một bank, mặc định `user-<tên đăng nhập>`; đổi `HINDSIGHT_BANK` nếu cần chia sẻ giữa các máy hoặc tách dữ liệu. Mặc định này đơn giản cho một người dùng, nhưng các dự án cùng bank sẽ chia sẻ ký ức.

## Cài qua marketplace

Repo GitHub này là private: trên mỗi máy cần Git credentials có quyền đọc repo. Claude Code thử SSH trước với dạng `owner/repo`; hãy cấu hình SSH key/agent trước. Codex CLI hiện dùng HTTPS cho dạng `owner/repo`, nên ví dụ dưới dùng SSH URL để phù hợp với máy đã xác thực SSH. Nếu muốn dùng HTTPS với Codex, cần cấu hình Git credential helper cho tài khoản GitHub; đăng nhập `gh` riêng chưa đủ. Sau khi PR này được merge vào nhánh mặc định:

```sh
claude plugin marketplace add tkhieu/Setup-Hindsight
claude plugin install hindsight-client@setup-hindsight

codex plugin marketplace add git@github.com:tkhieu/Setup-Hindsight.git
codex plugin add hindsight-client@setup-hindsight
```

Trong phiên Claude Code có thể dùng `/plugin marketplace add tkhieu/Setup-Hindsight`, rồi `/plugin install hindsight-client@setup-hindsight`; lệnh thứ hai mở màn hình chọn scope. Skill xuất hiện dưới tên `/hindsight-client:setup-hindsight-client`. Sau khi cài plugin, dùng skill để chạy `scripts/hindsight-client-setup` nằm ngay trong plugin, hoặc chạy script đó trực tiếp với `HINDSIGHT_CLIENT_PLUGIN_MODE=1` để tránh skill symlink trùng. Plugin cung cấp skill và script, còn kết nối MCP cùng hooks do gói tích hợp chính thức cài tại máy người dùng. Như vậy API key chỉ nằm trong cấu hình máy, không nằm trong manifest hoặc git; đóng gói MCP/hooks riêng sẽ tạo đăng ký trùng.

## Cài từ bản checkout

```sh
workstation/bin/hindsight-client-setup --dry-run
workstation/bin/hindsight-client-setup install
workstation/bin/hindsight-client-setup --status
workstation/bin/hindsight-client-setup --uninstall
```

Lần cài đầu tạo `~/.config/hindsight/client.env` từ `workstation/client.env.example`; điền `HINDSIGHT_API_KEY` rồi chạy lại. File phải có quyền `600`. Biến môi trường `HINDSIGHT_URL`, `HINDSIGHT_API_KEY`, `HINDSIGHT_BANK` ghi đè file. URL mặc định là `https://hindsight-api.hieutk.dev`. Cần Node.js/npm (`npx`), Claude Code, Codex, `curl` và Python 3.11+. Installer kiểm tra `/health` và GET `/v1/default/banks` có xác thực trước khi cài.

Tích hợp chính thức lưu cấu hình tại `~/.hindsight/coding-agent.json` (bản sao trước thay đổi ở `.hindsight-client-backup`), hooks tại cấu hình Claude/Codex, và skill này tại `~/.claude/skills` cùng `~/.codex/skills`. Nếu `[features]` đã có trong cấu hình Codex, installer bật `hooks = true` và sao lưu file trước khi sửa. Nếu tích hợp chính thức không bật hooks (ví dụ file chưa có `[features]`), installer cảnh báo: thêm `[features]` và `hooks = true` vào `~/.codex/config.toml`. Lệnh gỡ giữ file cấu hình và khóa để cài lại. Sau khi cài, mở phiên Claude Code hoặc Codex mới.

Lỗi 401: đối chiếu API key với server. Lỗi kết nối: kiểm tra Cloudflare Tunnel và `/health`. Sai ký ức: đối chiếu `HINDSIGHT_BANK` trên các máy và chạy lại `install`.
