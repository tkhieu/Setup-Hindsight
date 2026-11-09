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

1. **Có bản backup đã xác minh khôi phục được.** Phase 1 ban đầu định dùng
   `POST .../banks/user-hieu/clone` để có một bản archive dạng bank, nhưng
   **lệnh clone đó OOM trên server** (máy chỉ có ~6 GiB RAM, nhân bản cả bank
   633 document/7160 fact vượt quá). Quyết định cuối: **không có bank
   archive** — bản sao khôi phục được là file dump Postgres, theo đúng cơ chế
   backup sẵn có của repo này (`server-setup/bin/backup.sh`,
   `bin/backup-r2.sh`, xem `docs/PLAYBOOK.md` mục 5 và 6), không phải bank
   clone.

   Ví dụ thật lúc viết runbook này (trên server, sau khi bật per-repo ở phase
   2): dump local
   `~/hindsight/server-setup/backups/20261109-030157-pre-per-repo-pilot-20261109-db.sql.gz`,
   bản sao R2 `db/6h/20261109T031638Z.sql.gz`. Xác minh dump đọc được —
   chạy trên server, qua `bin/restore-db.sh --drill` (import thử vào DB tạm,
   không đụng DB thật hay `hindsight`, xem `docs/PLAYBOOK.md` mục 6-7 để biết
   cơ chế đầy đủ):

   ```bash
   ssh hieu@100.77.187.94 'cd ~/hindsight/server-setup && bin/restore-db.sh --drill backups/20261109-030157-pre-per-repo-pilot-20261109-db.sql.gz'
   # hoặc xác minh đúng bản R2 ở trên:
   ssh hieu@100.77.187.94 'cd ~/hindsight/server-setup && bin/restore-db.sh --drill r2:db/6h/20261109T031638Z.sql.gz'
   ```

   **Không bao giờ chạy `POST .../banks/<bank_id>/clone`, và không bao giờ
   chạy `document-transfer`/`transfer` xuất toàn bộ `user-hieu` (export
   không giới hạn `document_id`), trên server này** — cùng nguyên nhân OOM
   đã xảy ra, bank quá lớn so với RAM máy. Script `seed-repo-bank.sh` không
   bao giờ làm việc này — nó chỉ export đúng tập document nhỏ cần seed cho
   một repo (`document_id` liệt kê rõ trong "Transfer candidates" ở mục 1),
   không bao giờ export cả bank.
2. **Mốc đếm để xác nhận `user-hieu` ngừng nhận ghi mới (phase 2 đã bật trên
   máy này)**: `user-hieu` hiện có **633 document, 7160 fact**:

   ```bash
   CFG=~/.hindsight/coding-agent.json
   TOKEN=$(python3 -c "import json;print(json.load(open('$CFG'))['apiToken'])")
   API=$(python3 -c "import json;print(json.load(open('$CFG'))['apiUrl'])")
   printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - "$API/v1/default/banks/user-hieu/stats"
   # -> total_documents, total_nodes (= fact)
   ```

   Đây là mốc đông lạnh; so lại số này bất cứ lúc nào để chắc `user-hieu`
   không tăng (dynamicBankId đã bật, mọi retain mới đi vào
   `coding-agent::{gitProject}`, không còn vào `user-hieu`).
3. **Repo đã mở ít nhất một lần** trong Claude Code hoặc Codex với per-repo
   bank đã bật (phase 2 — đã bật trên máy này, xem `~/.hindsight/coding-agent.json`:
   `dynamicBankId: true`, `bankIdTemplate: "coding-agent::{gitProject}"`) —
   đây là cách bank đích `coding-agent::<repo>` được plugin tự tạo. Script
   **không bao giờ tự tạo bank** — thấy bank đích chưa có thì dừng và báo
   đúng việc này.

## 1. Quy trình cho một repo

**Mọi lệnh trong runbook này chạy từ gốc repo `Setup-Hindsight`** (không
`cd server-setup` trước) — tất cả đường dẫn dưới đây (`server-setup/bin/...`,
`server-setup/state/...`) đều viết tương đối theo gốc repo, nhất quán trong
toàn bộ tài liệu:

```bash
server-setup/bin/seed-repo-bank.sh <repo-basename> --dry-run   # xem kế hoạch, không ghi gì
server-setup/bin/seed-repo-bank.sh <repo-basename>              # chạy thật
```

`<repo-basename>` là tên thư mục của **main worktree** (không phải tên một
linked worktree) — đúng tên repo bạn thấy trong `coding-agent::<repo>`.

Ví dụ thật (dry-run cho repo pilot `Setup-Hindsight`, lúc viết runbook này
— sau khi phase 2 đã bật — bank đích đã tồn tại, document
`gitlog:Setup-Hindsight` chưa có ở bank đích, chưa có hội thoại nào map được
qua transcript cục bộ cho repo này):

```
$ server-setup/bin/seed-repo-bank.sh Setup-Hindsight --dry-run
seed-repo-bank: repo=Setup-Hindsight source=user-hieu destination=coding-agent::Setup-Hindsight

DRY RUN -- no API writes, no ledger write.

Destination bank status: exists

Transfer candidates (1):
  gitlog:Setup-Hindsight

Reflect query (against user-hieu):
  ...

Distill target: coding-agent::Setup-Hindsight document "migrated:user-hieu:Setup-Hindsight" (tags: project:Setup-Hindsight, source:migration)

Ledger (not written): .../server-setup/state/bank-seed-ledger.jsonl
```

Dry-run chỉ đọc (không cần cân nhắc an toàn): kiểm tra bank đích có tồn tại
chưa, tìm document `gitlog:<repo>` và các hội thoại map được qua transcript
cục bộ, kiểm tra trong số đó cái nào **đã có sẵn ở bank đích** (nếu bank đích
đã tồn tại), dựng câu hỏi `reflect`. Khi có document đã có sẵn ở bank đích,
dry-run in thêm một dòng liệt kê — những document đó **không bao giờ** được
tính là "do script này tạo ra" (không tính vào xác nhận đã chép, không nằm
trong danh sách rollback ở mục 3), vì có thể đã tồn tại từ trước (ví dụ
chính plugin coding-agent tự ghi `gitlog:<repo>`), không phải do lần chạy
này.

Khi chạy thật, nếu bank đích đã tồn tại, script làm theo thứ tự:

1. **Chép chính xác** từng document trong "Transfer candidates" **chưa có ở
   bank đích** bằng `document-transfer/export` (bank nguồn) rồi
   `document-transfer?on_conflict=skip` (bank đích) — hai endpoint này **đã
   deprecated**, chạy bất đồng bộ (trả `operation_id`, script tự poll
   `.../operations/{id}` tối đa `HINDSIGHT_SEED_OPERATION_TIMEOUT` giây,
   mặc định 120s). Nếu tất cả candidate đã có sẵn ở bank đích từ trước thì
   bỏ qua bước này hoàn toàn (không gọi hai endpoint deprecated để chỉ nhận
   lại kết quả "skip" vô nghĩa).

   Sau khi operation báo **hoàn tất**, script tự kiểm tra lại — hỏi thẳng
   bank đích từng document_id vừa định chép — để biết **chính xác** cái nào
   thật sự xuất hiện; **không bao giờ tin số đếm trong `result_metadata`
   của operation** (API tự ghi nhận trường này là nội bộ, có thể đổi dạng
   không báo trước).

   Có 3 kết quả khác nhau, ghi vào ledger qua trường `transfer_status`:
   - **`transferred`**: operation hoàn tất, ở trên là danh sách document đã
     xác nhận (`confirmed_document_ids`) — có thể là danh sách rỗng, nếu mọi
     candidate đều đã có sẵn từ trước.
   - **`skipped`**: operation lỗi thật (không phải hết thời gian chờ) — ví
     dụ endpoint deprecated trả lỗi hẳn. Script **không dừng**: bỏ qua bước
     chép, vẫn tiếp tục bước 2.
   - **`pending`**: hết `HINDSIGHT_SEED_OPERATION_TIMEOUT` mà operation vẫn
     chưa xong (chưa `completed`, chưa `failed`) — **kết quả chưa biết, khác
     hẳn với bị bỏ qua**: operation vẫn có thể hoàn tất ngay sau khi script
     thôi chờ. Ledger ghi bank + `operation_id` đang chạy; **lần chạy kế
     tiếp cho cùng repo sẽ tự kiểm tra lại operation đó trước khi làm gì
     khác** — nếu đã `completed` thì xác nhận danh sách document thật sự có
     và dùng luôn, không gửi lại export/import mới. Xem mục "Sự cố thường
     gặp" để biết cách tự kiểm tra operation đó sớm hơn nếu không muốn chờ
     lần chạy kế tiếp.
2. `reflect` trên bank nguồn với một bộ câu hỏi cố định về repo (quyết định +
   lý do, quy ước, kiến trúc/thành phần, việc dở dang, lỗi đã gặp), chỉ giữ
   thông tin gắn được với repo. Kết quả được `retain` vào bank đích thành
   document `migrated:<bank nguồn>:<repo>`, tag `project:<repo>` và
   `source:migration`, kèm `update_mode: replace` tường minh. Document này
   dùng `document_id` cố định nên **chạy lại luôn thay thế, không nhân bản**.
3. Ghi một dòng JSONL vào `server-setup/state/bank-seed-ledger.jsonl` (thư
   mục `state/` không commit — xem `.gitignore`): repo, thời điểm (giờ Việt
   Nam), bank nguồn/đích, `transfer_status`, `confirmed_document_ids` (danh
   sách thật — xem mục 1 bước 1), `attempted_confirmable_ids` (danh sách
   candidate script đã kiểm tra lần này, dùng khi lần chạy sau cần đối soát
   một operation còn `pending`), `pending_bank`/`pending_operation_id` (khi
   `transfer_status` là `pending`), `distill_document_id`, `dry_run: false`.
   Không ghi nội dung memory.

Script không bao giờ ghi hoặc xoá bất cứ gì trên **bank nguồn** — chỉ đọc.

## 2. Kiểm tra sau khi chạy thật

Chạy từ gốc repo (như mọi lệnh khác trong tài liệu này):

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

tail -1 server-setup/state/bank-seed-ledger.jsonl | python3 -m json.tool
```

Nếu dòng ledger vừa ghi có `"transfer_status": "pending"`, operation chép
document chưa xong lúc script thôi chờ — **không phải đã bỏ qua**. Tự kiểm
tra ngay (không cần chờ lần chạy kế tiếp):

```bash
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
  | curl -sS -K - "$API/v1/default/banks/<pending_bank từ ledger>/operations/<pending_operation_id từ ledger>"
```

`"status": "completed"` nghĩa là chạy lại script cho repo đó sẽ tự đối soát
(xác nhận document thật sự có, không gửi lại export/import) — xem mục 1
bước 1. Còn `"processing"`/`"pending"` thì chờ thêm rồi kiểm tra lại, hoặc cứ
chạy lại script — đối soát luôn thử trước, không hại gì.

Chạy lại script lần 2 cho cùng repo rồi lặp lại bước đếm document: số
document bank đích **không tăng thêm** vì phần "chép chính xác" dùng
`on_conflict=skip` và dòng ledger thứ hai sẽ có `confirmed_document_ids`
rỗng (không có gì MỚI để xác nhận — lần đầu đã xác nhận rồi) — đây là cách
xác nhận idempotent trên bank thật; ledger ghi đúng những gì đã xảy ra, chứ
không phải nguồn đếm chính (đếm chính luôn là `GET .../stats` ở trên).

## 3. Rollback (chỉ ở bank đích, không đụng bank nguồn)

**Dùng đúng danh sách ledger đã ghi, không tự suy ra lại bằng `--dry-run`.**
`--dry-run` cho danh sách *candidate* (mọi document có khả năng liên quan
đến repo), không phải danh sách *đã thật sự được script này tạo ra* — một
candidate có thể đã tồn tại ở bank đích từ trước (ví dụ `gitlog:<repo>` do
chính plugin coding-agent tự ghi, không phải do `seed-repo-bank.sh`), và
xoá nhầm document đó là xoá nhầm dữ liệu không thuộc về lần seed này. Ledger
đã phân biệt đúng việc này — lấy từ `confirmed_document_ids` của (các) dòng
ledger liên quan đến repo đó:

```bash
CFG=~/.hindsight/coding-agent.json
TOKEN=$(python3 -c "import json;print(json.load(open('$CFG'))['apiToken'])")
API=$(python3 -c "import json;print(json.load(open('$CFG'))['apiUrl'])")
REPO="<repo-basename>"
DST="coding-agent::$REPO"

# Toàn bộ document_id ledger xác nhận ĐÃ TẠO cho repo này, qua mọi lần chạy
# (confirmed_document_ids gộp theo từng dòng; distill_document_id cố định)
# -- KHÔNG bao gồm bất cứ candidate nào ledger không xác nhận.
python3 -c "
import json
ids = set()
distill_id = None
for line in open('server-setup/state/bank-seed-ledger.jsonl'):
    rec = json.loads(line)
    if rec['repo'] != '$REPO':
        continue
    ids.update(rec.get('confirmed_document_ids') or [])
    distill_id = rec['distill_document_id']
if distill_id:
    ids.add(distill_id)
print('\n'.join(sorted(ids)))
" > /tmp/rollback-ids.txt
cat /tmp/rollback-ids.txt   # xem lại trước khi xoá

while read -r DOC_ID; do
  [ -n "$DOC_ID" ] || continue
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$DOC_ID")
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
    | curl -sS -K - -X DELETE "$API/v1/default/banks/$DST/documents/$ENC"
done < /tmp/rollback-ids.txt
rm -f /tmp/rollback-ids.txt
```

Nếu có dòng ledger `transfer_status: pending` chưa được đối soát (mục 2),
chạy lại script một lần trước khi rollback để nó tự cập nhật
`confirmed_document_ids` — tránh rollback dựa trên thông tin còn thiếu.

Tag `source:migration` (trên document `migrated:*`) là cách lọc riêng
document chưng cất nếu `reflect` trộn nhầm repo mà chỉ muốn xoá phần đó,
không đụng phần chép chính xác.

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
bỏ qua — ký ức của nó vẫn còn nguyên trong `user-hieu` (không có bank
archive riêng — xem mục 0).

## 5. Tra lại `user-hieu` cho một session cũ

Bank chung `user-hieu` không bị xoá hay sửa bởi script này. Máy này đã bật
per-repo (phase 2) — client mặc định dùng `coding-agent::{gitProject}`, không
còn `user-hieu`. Muốn **một phiên** Claude Code/Codex tạm tra lại trực tiếp
`user-hieu` mà không đổi cấu hình đã cài, theo đúng quy trình trong
`docs/CLIENT_SETUP.md` (file cấu hình có ưu tiên cao hơn biến môi trường nên
phải tạo bản cấu hình tạm bỏ hai khoá chọn bank):

```bash
tmp=$(mktemp)
python3 - "$tmp" <<'PY'
import json, pathlib, sys
config = json.loads((pathlib.Path.home() / '.hindsight/coding-agent.json').read_text())
config.pop('bankId', None)
config.pop('dynamicBankId', None)
pathlib.Path(sys.argv[1]).write_text(json.dumps(config))
PY
HINDSIGHT_CONFIG="$tmp" HINDSIGHT_BANK_ID=user-hieu HINDSIGHT_DYNAMIC_BANK_ID=false codex
rm -f "$tmp"
```

Thay `codex` bằng `claude` nếu cần. Hoặc hỏi trực tiếp qua API bất cứ lúc
nào, chỉ đọc (đã dry-trace thật ở trên, `user-hieu` hiện có 633 document,
7160 fact — mốc đông lạnh ở mục 0):

```bash
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$TOKEN" \
  | curl -sS -K - -X POST -d '{"query":"<câu hỏi>"}' "$API/v1/default/banks/user-hieu/memories/recall"
```

## 6. Tiêu chí nghỉ hưu `user-hieu` (phase 5 — chưa làm trong PR này)

Chỉ cân nhắc khi **đồng thời**:

1. mọi repo hoạt động trong 30 ngày gần nhất đã có dòng trong ledger;
2. `user-hieu` không nhận document mới kể từ mốc đếm ở mục 0 (so `GET
   /v1/default/banks/user-hieu/stats` — `total_documents`/`total_nodes` —
   với mốc 633/7160 đó);
3. bạn xác nhận không còn cần tra trực tiếp `user-hieu` cho việc hiện tại.

Khi đó: đổi mô tả `user-hieu` thành "archive, chỉ đọc" (bank chính nó vẫn
giữ nguyên — không có bank clone riêng, xem mục 0). **Giữ tối thiểu 90 ngày**
sau khi nghỉ hưu — tính từ bản backup/R2 gần mốc nghỉ hưu nhất, không phải
từ lúc viết runbook này — trước khi cân nhắc xoá. Quyết định xoá nằm ngoài
phạm vi runbook này, làm riêng sau khi đã xác nhận không cần nữa.

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| `destination bank ... does not exist yet` | Bank đích chưa được plugin tạo — mở repo một lần trong Claude Code/Codex rồi chạy lại |
| `no API token` | Thiếu `HINDSIGHT_API_TOKEN` và không có `apiToken` hợp lệ trong `~/.hindsight/coding-agent.json` |
| `document-transfer failed; skipping it` | Endpoint deprecated trả lỗi hẳn (không phải hết thời gian chờ) — script vẫn chạy xong phần chưng cất; xem `transfer_status: "skipped"` trong ledger, có thể thử lại sau |
| `document-transfer outcome unknown ... recorded as pending` | Hết `HINDSIGHT_SEED_OPERATION_TIMEOUT` mà operation chưa xong — **chưa biết kết quả, khác với bị bỏ qua**. Xem mục 2 để tự kiểm tra operation đó, hoặc chạy lại script sau để nó tự đối soát |
| `Transfer candidates (0)` ở dry-run | Không có `gitlog:<repo>` và không hội thoại nào map được qua transcript cục bộ — bình thường với repo ít hoạt động trước khi bật per-repo; phần chưng cất vẫn chạy khi chạy thật |
| `(N ... already exist in the destination bank ...)` ở dry-run | Bình thường trên một rerun, hoặc khi bank đích đã có document trùng id từ nguồn khác (ví dụ plugin tự ghi `gitlog:<repo>`) — những document này không bị script này động vào, không tính vào xác nhận hay rollback |
| Ledger không có dòng mới | Script dừng trước bước ghi ledger (ví dụ bank đích thiếu, hoặc `reflect`/`retain` lỗi) — xem log lỗi stderr |
