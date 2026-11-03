# Nối Claude Code và Codex vào Hindsight

Hướng dẫn cài client trên máy dev. Server phải đang chạy (xem
[`PLAYBOOK.md`](PLAYBOOK.md)); kiểm tra trước:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://hindsight-api.hieutk.dev/health   # phải là 200
```

Client gồm plugin `hindsight-client` (skill `setup-hindsight-client` + script
`hindsight-client-setup`). Script gọi tích hợp chính thức
`@vectorize-io/hindsight-coding-agents@0.8.2` để đăng ký MCP và hooks cho cả
Claude Code lẫn Codex. Chi tiết installer: [`workstation/README.md`](../workstation/README.md).

**Yêu cầu trên máy dev:** `npx` (Node.js), `claude`, `codex`, `curl`, Python 3.11+,
và SSH key có quyền đọc repo private `tkhieu/Setup-Hindsight` (cũng dùng để SSH vào server).

## 1. Cài plugin

```bash
# Claude Code
claude plugin marketplace add tkhieu/Setup-Hindsight
claude plugin install hindsight-client@setup-hindsight

# Codex — dùng SSH URL vì Codex mặc định clone qua HTTPS
codex plugin marketplace add git@github.com:tkhieu/Setup-Hindsight.git
codex plugin add hindsight-client@setup-hindsight
```

Trong phiên Claude Code có thể dùng `/plugin marketplace add tkhieu/Setup-Hindsight`
rồi `/plugin install hindsight-client@setup-hindsight`.

## 2. Tạo `~/.config/hindsight/client.env`

API key cho agent là **`HINDSIGHT_API_TENANT_API_KEY`** trong
`~/hindsight/server-setup/secrets.env` trên server — **không phải**
`HINDSIGHT_CP_ACCESS_KEY` (key đó chỉ để đăng nhập UI `https://hindsight.hieutk.dev`).

Lệnh dưới kéo key qua SSH và ghi thẳng vào file (quyền `600`), không in key ra màn hình
và không đưa key vào tham số dòng lệnh:

```bash
install -d -m 700 ~/.config/hindsight
( umask 077
  K=$(ssh hieu@100.77.187.94 "grep '^HINDSIGHT_API_TENANT_API_KEY=' ~/hindsight/server-setup/secrets.env | cut -d= -f2-")
  printf 'HINDSIGHT_URL=https://hindsight-api.hieutk.dev\nHINDSIGHT_API_KEY=%s\n' "$K" > ~/.config/hindsight/client.env
  unset K )
grep -c '^HINDSIGHT_API_KEY=.' ~/.config/hindsight/client.env   # phải in ra 1
```

Lệnh này ghi đè `client.env` nếu file đã có. Biến môi trường `HINDSIGHT_URL`,
`HINDSIGHT_API_KEY`, `HINDSIGHT_BANK` (nếu đặt) ghi đè giá trị trong file.

**Bank:** mặc định `user-<tên đăng nhập>`, Claude Code và Codex dùng chung. Muốn
nhiều máy chia sẻ cùng một bộ memory thì thêm cùng một dòng trên mọi máy:

```bash
echo 'HINDSIGHT_BANK=user-hieu' >> ~/.config/hindsight/client.env
```

## 3. Chạy setup

Mở phiên Claude Code mới, gõ:

```
/hindsight-client:setup-hindsight-client
```

và bảo nó chạy lần lượt `--dry-run`, `install`, `--status`. Skill tự tìm script trong
plugin và chạy với `HINDSIGHT_CLIENT_PLUGIN_MODE=1` để không tạo skill trùng.

Hoặc chạy trực tiếp từ bản checkout (chọn **một** trong hai cách, không dùng cả hai):

```bash
workstation/bin/hindsight-client-setup --dry-run
workstation/bin/hindsight-client-setup install
workstation/bin/hindsight-client-setup --status
```

Cài xong, **mở phiên Claude Code và Codex mới** để chúng nạp MCP và hooks.

Gỡ: `workstation/bin/hindsight-client-setup --uninstall` (giữ lại `client.env` để cài lại).

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| Cảnh báo `Codex hooks chưa bật` | Thêm `[features]` và `hooks = true` vào `~/.codex/config.toml`, mở phiên Codex mới |
| `401` | Key sai, hoặc dùng nhầm `HINDSIGHT_CP_ACCESS_KEY`. Làm lại bước 2 |
| Không kết nối / `/health` lỗi | Tunnel hoặc stack trên server đang lỗi — xem PLAYBOOK, mục triệu chứng |
| Không thấy memory | `HINDSIGHT_BANK` khác nhau giữa các máy; bank chỉ xuất hiện sau khi đã có dữ liệu |
| MCP hoặc hook thiếu | Chạy lại `install`; kiểm tra `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.codex/config.toml` |
