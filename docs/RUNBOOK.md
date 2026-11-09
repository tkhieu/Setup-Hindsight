# RUNBOOK: seed bank theo repo (tách dần khỏi `user-hieu`)

Quy trình chạy tay để chuyển ký ức từ bank chung `user-hieu` sang bank riêng
`coding-agent::<repo>` cho từng repo, theo thiết kế "tách dần" (không chép
hội thoại thô, không xoá gì ở `user-hieu`). Script: `server-setup/bin/seed-repo-bank.sh`.
Không tự động chạy theo lịch — bạn chạy từng repo khi nhớ hoặc theo nhịp
kiểm tra hằng tuần ở mục 4.

Script này chạy trên **máy dev** (không phải trên server), gọi thẳng
`https://hindsight-api.hieutk.dev` bằng token trong `~/.hindsight/coding-agent.json`
(hoặc biến môi trường `HINDSIGHT_API_TOKEN`). Không cần SSH vào server.

## 0. Điều kiện trước

1. **Phase 1 đã chạy**: có bản backup DB (`server-setup/bin/backup.sh`) và bank
   clone `user-hieu-archive-20261109` tồn tại. Kiểm tra (chỉ đọc):

   ```bash
   CFG=~/.hindsight/coding-agent.json
   TOKEN=$(python3 -c "import json;print(json.load(open('$CFG'))['apiToken'])")
   API=$(python3 -c "import json;print(json.load(open('$CFG'))['apiUrl'])")
   printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - "$API/v1/default/banks?q=user-hieu-archive"
   ```

   Thấy `user-hieu-archive-20261109` trong kết quả thì mới seed repo đầu tiên;
   chưa thấy thì chạy phase 1 trước (xem `plans/.../phase-01-backup-and-freeze.md`
   lúc làm phase đó — không có trong repo này, plan không commit).
2. **Repo đã mở ít nhất một lần** trong Claude Code hoặc Codex với per-repo
   bank đã bật (phase 2) — đây là cách bank đích `coding-agent::<repo>` được
   plugin tự tạo. Script **không bao giờ tự tạo bank** — thấy bank đích chưa
   có thì dừng và báo đúng việc này.

## 1. Quy trình cho một repo

```bash
cd server-setup
bin/seed-repo-bank.sh <repo-basename> --dry-run   # xem kế hoạch, không ghi gì
bin/seed-repo-bank.sh <repo-basename>              # chạy thật
```

`<repo-basename>` là tên thư mục của **main worktree** (không phải tên một
linked worktree) — đúng tên repo bạn thấy trong `coding-agent::<repo>`.

Ví dụ thật (dry-run cho repo pilot `Setup-Hindsight`, lúc viết runbook này
bank đích chưa tồn tại và không có hội thoại nào map được qua transcript):

```
$ bin/seed-repo-bank.sh Setup-Hindsight --dry-run
seed-repo-bank: repo=Setup-Hindsight source=user-hieu destination=coding-agent::Setup-Hindsight

DRY RUN -- no API writes, no ledger write.

Destination bank status: MISSING -- a real run would stop here until the repo
  is opened once in Claude Code or Codex so the coding-agent plugin creates it.

Transfer candidates (1):
  gitlog:Setup-Hindsight

Reflect query (against user-hieu):
  ...

Distill target: coding-agent::Setup-Hindsight document "migrated:user-hieu:Setup-Hindsight" (tags: project:Setup-Hindsight, source:migration)

Ledger (not written): .../server-setup/state/bank-seed-ledger.jsonl
```

Dry-run làm đúng 3 việc đọc (không ghi gì, không cần `--dry-run` cân nhắc an
toàn): kiểm tra bank đích có tồn tại chưa, tìm document `gitlog:<repo>` và
các hội thoại map được qua transcript cục bộ, dựng câu hỏi `reflect`. Danh
sách "Transfer candidates" chính là tập document sẽ được chép chính xác ở
bước chạy thật — ghi lại danh sách này, cần dùng lại ở mục rollback (3).

Khi chạy thật, nếu bank đích đã tồn tại, script làm theo thứ tự:

1. Chép chính xác từng document trong "Transfer candidates" bằng
   `document-transfer/export` (bank nguồn) rồi `document-transfer?on_conflict=skip`
   (bank đích) — hai endpoint này **đã deprecated**, chạy bất đồng bộ (trả
   `operation_id`, script tự poll `.../operations/{id}`). Nếu bước này lỗi
   hoặc hết thời gian chờ, script **không dừng**: in cảnh báo, bỏ qua bước
   chép, và vẫn tiếp tục bước 2.
2. `reflect` trên bank nguồn với một bộ câu hỏi cố định về repo (quyết định +
   lý do, quy ước, kiến trúc/thành phần, việc dở dang, lỗi đã gặp), chỉ giữ
   thông tin gắn được với repo. Kết quả được `retain` vào bank đích thành
   document `migrated:<bank nguồn>:<repo>`, tag `project:<repo>` và
   `source:migration`. Document này dùng `document_id` cố định nên **chạy
   lại luôn thay thế, không nhân bản** (hành vi upsert sẵn có của `retain`).
3. Ghi một dòng JSONL vào `server-setup/state/bank-seed-ledger.jsonl`
   (thư mục `state/` không commit — xem `.gitignore`): repo, thời điểm
   (giờ Việt Nam), bank nguồn/đích, số document bước 1 báo cáo đã chép (0 nếu
   bị bỏ qua), `distill_document_id`, `dry_run: false`. Không ghi nội dung
   memory.

Script không bao giờ ghi hoặc xoá bất cứ gì trên **bank nguồn** — chỉ đọc.

## 2. Kiểm tra sau khi chạy thật

```bash
CFG=~/.hindsight/coding-agent.json
TOKEN=$(python3 -c "import json;print(json.load(open('$CFG'))['apiToken'])")
API=$(python3 -c "import json;print(json.load(open('$CFG'))['apiUrl'])")
DST="coding-agent::<repo-basename>"

# Số document bank đích (so với trước khi chạy, nên ghi lại số trước đó)
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - "$API/v1/default/banks/$DST/stats"

# Recall thử một câu hỏi về repo -- phải thấy nội dung đến từ document migrated:*
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$TOKEN" \
  | curl -sS -K - -X POST -d '{"query":"Repo này có quyết định kiến trúc hay quy ước gì đáng nhớ?"}' \
    "$API/v1/default/banks/$DST/memories/recall"

tail -1 server-setup/state/bank-seed-ledger.jsonl
```

Chạy lại script lần 2 cho cùng repo rồi lặp lại bước đếm document: số
document bank đích **không tăng thêm** vì phần "chép chính xác" dùng
`on_conflict=skip` và phần "chưng cất" thay thế đúng một document cùng id —
đây là cách xác nhận idempotent trên bank thật, ledger chỉ là nhật ký thao
tác, không phải nguồn sự thật cho việc đếm.

## 3. Rollback (chỉ ở bank đích, không đụng bank nguồn)

Xoá đúng những gì repo đó đã nhận: lấy lại danh sách bằng cách chạy lại
`--dry-run` cho repo đó (danh sách "Transfer candidates" không đổi vì logic
map là xác định), rồi xoá từng document ở bank đích — **không xoá ở bank
nguồn**:

```bash
CFG=~/.hindsight/coding-agent.json
TOKEN=$(python3 -c "import json;print(json.load(open('$CFG'))['apiToken'])")
API=$(python3 -c "import json;print(json.load(open('$CFG'))['apiUrl'])")
DST="coding-agent::<repo-basename>"

for DOC_ID in "migrated:user-hieu:<repo-basename>" "gitlog:<repo-basename>" "conversation:<session_id...>"; do
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
    | curl -sS -K - -X DELETE "$API/v1/default/banks/$DST/documents/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$DOC_ID")"
done
```

Document `source:migration` (tag trên document `migrated:*`) là cách lọc
riêng document chưng cất nếu `reflect` trộn nhầm repo mà không muốn xoá cả
phần chép chính xác.

## 4. Kiểm tra hằng tuần

So danh sách repo đang hoạt động với repo đã có dòng trong ledger:

```bash
python3 -c "
import json
seeded = sorted({json.loads(l)['repo'] for l in open('server-setup/state/bank-seed-ledger.jsonl')})
print('\n'.join(seeded))
" 2>/dev/null || echo "(chưa seed repo nào)"
```

Repo nào đang làm việc thật (mở trong Claude Code/Codex gần đây) mà chưa có
trong danh sách trên thì chạy mục 1 cho repo đó. Repo không còn làm nữa thì
bỏ qua — ký ức của nó vẫn còn nguyên trong `user-hieu`/`user-hieu-archive-20261109`.

## 5. Tra lại `user-hieu` cho một session cũ

Bank chung `user-hieu` không bị xoá hay sửa bởi script này. Sau khi phase 2/4
đổi mặc định client sang per-repo (`coding-agent::{gitProject}`), muốn một
phiên Claude Code/Codex tạm tra lại trực tiếp `user-hieu` thì đặt biến môi
trường trước khi mở phiên:

```bash
export HINDSIGHT_BANK_ID=user-hieu
```

rồi mở phiên mới (xem `docs/CLIENT_SETUP.md`). Lúc viết runbook này phase 2
chưa chạy nên mọi phiên vẫn đang dùng `user-hieu` theo mặc định — chưa cần
biến này. Hoặc hỏi trực tiếp qua API bất cứ lúc nào, chỉ đọc (đã dry-trace
thật ở trên, `user-hieu` hiện có 633 document):

```bash
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$TOKEN" \
  | curl -sS -K - -X POST -d '{"query":"<câu hỏi>"}' "$API/v1/default/banks/user-hieu/memories/recall"
```

## 6. Tiêu chí nghỉ hưu `user-hieu` (phase 5 — chưa làm trong PR này)

Chỉ cân nhắc khi **đồng thời**:

1. mọi repo hoạt động trong 30 ngày gần nhất đã có dòng trong ledger;
2. `user-hieu` không nhận document mới kể từ mốc đếm ở phase 1 (so `GET
   /v1/default/banks/user-hieu/stats` với mốc đó);
3. bạn xác nhận không còn cần tra trực tiếp `user-hieu` cho việc hiện tại.

Khi đó: đổi mô tả `user-hieu` thành "archive, chỉ đọc", giữ cả `user-hieu`
lẫn `user-hieu-archive-20261109`. **Giữ tối thiểu 90 ngày** sau khi nghỉ hưu
trước khi cân nhắc xoá — quyết định xoá nằm ngoài phạm vi runbook này, làm
riêng sau khi đã xác nhận không cần nữa.

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| `destination bank ... does not exist yet` | Bank đích chưa được plugin tạo — mở repo một lần trong Claude Code/Codex rồi chạy lại |
| `no API token` | Thiếu `HINDSIGHT_API_TOKEN` và không có `apiToken` hợp lệ trong `~/.hindsight/coding-agent.json` |
| `document-transfer failed or timed out; skipping it` | Endpoint deprecated không ổn định hoặc timeout — script vẫn chạy xong phần chưng cất; xem `transfer_skipped` trong ledger, có thể thử lại sau |
| `Transfer candidates (0)` ở dry-run | Không có `gitlog:<repo>` và không hội thoại nào map được qua transcript cục bộ — bình thường với repo ít hoạt động trước khi bật per-repo; phần chưng cất vẫn chạy khi chạy thật |
| Ledger không có dòng mới | Script dừng trước bước ghi ledger (ví dụ bank đích thiếu, hoặc `reflect`/`retain` lỗi) — xem log lỗi stderr |
