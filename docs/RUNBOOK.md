# RUNBOOK: seed bank theo repo (tách dần khỏi `user-hieu`)

Quy trình chạy tay để chuyển ký ức từ bank chung `user-hieu` sang bank riêng
`coding-agent::<repo>` cho từng repo, theo thiết kế "tách dần" (không chép
hội thoại thô, không xoá gì ở `user-hieu`). Script: `server-setup/bin/seed-repo-bank.sh`.
Không tự động chạy theo lịch — bạn chạy từng repo khi nhớ hoặc theo nhịp
kiểm tra hằng tuần ở mục 4.

Script này chạy trên **máy dev** (không phải trên server), dùng token trong
`~/.hindsight/coding-agent.json` (hoặc biến môi trường `HINDSIGHT_API_TOKEN`).
Với lần seed thật, dùng SSH forward theo mục 1 để tránh giới hạn thời gian
chờ của Cloudflare tunnel trên `https://hindsight-api.hieutk.dev`.

## 0. Điều kiện trước

1. **Có bản backup đã xác minh khôi phục được.** Phase 1 ban đầu định dùng
   `POST .../banks/user-hieu/clone` để có một bản archive dạng bank, nhưng
   **lệnh clone đó OOM trên server** (máy chỉ có ~6 GiB RAM, nhân bản cả bank
   vượt quá bộ nhớ). Quyết định cuối: **không có bank
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

   Lệnh `--drill` ở trên đã từng fail trên chính bản dump này (2026-11-11)
   vì `/dev/shm` mặc định 64MiB của container `db` không đủ cho restore —
   xem cảnh báo `shm_size` ở `docs/PLAYBOOK.md` mục 6. Cách áp dụng
   (`bin/hs up -d db`) tạo lại container `db` và gây gián đoạn ngắn thật
   sự (xem cảnh báo downtime cùng chỗ) — không chạy giữa lúc đang seed
   hoặc có ai đang dùng Hindsight; chạy xong rồi mới `--drill` lại.

   **Không bao giờ chạy `POST .../banks/<bank_id>/clone`, và không bao giờ
   chạy `document-transfer`/`transfer` xuất toàn bộ `user-hieu` (export
   không giới hạn `document_id`), trên server này** — cùng nguyên nhân OOM
   đã xảy ra, bank quá lớn so với RAM máy. Script `seed-repo-bank.sh` không
   bao giờ làm việc này — nó chỉ export đúng tập document nhỏ cần seed cho
   một repo (`document_id` liệt kê rõ trong "Transfer candidates" ở mục 1),
   không bao giờ export cả bank.
2. **Kiểm tra trạng thái bank nguồn** (phase 2 đã bật trên máy này):
   `user-hieu` **vẫn nhận ghi mới**. Số liệu lịch sử: 633 document/7160 fact
   ngày 2026-11-09; đến 2026-11-11 là 673 document/7605 fact. Chưa điều tra
   nguồn ghi; chủ hệ thống quyết định tiếp tục cho ghi và di chuyển dần.
   Có thể đọc số liệu hiện tại bằng:

   ```bash
   CFG=~/.hindsight/coding-agent.json
   TOKEN=$(python3 -c "import json;print(json.load(open('$CFG'))['apiToken'])")
   API=$(python3 -c "import json;print(json.load(open('$CFG'))['apiUrl'])")
   printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - "$API/v1/default/banks/user-hieu/stats"
   # -> total_documents, total_nodes (= fact)
   ```

   Số đếm chỉ để quan sát; không dùng làm điều kiện seed hay nghỉ hưu bank.
3. **Repo đã mở ít nhất một lần** trong Claude Code hoặc Codex với per-repo
   bank đã bật (phase 2 — đã bật trên máy này, xem `~/.hindsight/coding-agent.json`:
   `dynamicBankId: true`, `bankIdTemplate: "coding-agent::{gitProject}"`) —
   đây là cách bank đích `coding-agent::<repo>` được plugin tự tạo. Script
   **không bao giờ tự tạo bank** — thấy bank đích chưa có thì dừng và báo
   đúng việc này.

## 1. Quy trình cho một repo

**Các lệnh seed ở mục này chạy từ gốc repo `Setup-Hindsight`** (không
`cd server-setup` trước). Đường dẫn `server-setup/bin/...` và
`server-setup/state/...` đều tương đối theo gốc repo.

Lần `reflect` duy nhất trên `user-hieu` đã mất khoảng 250 giây cho
`reflect` + `retain` vào 2026-11-11. Cloudflare tunnel của URL công khai
trả HTTP 524 sau khoảng 100 giây; chỉ tăng `HINDSIGHT_SEED_HTTP_TIMEOUT`
không giải quyết được. Chạy qua SSH forward tới cổng API trên host
(`127.0.0.1:8888`, theo `server-setup/compose.yaml`). Thay `your-ssh-host`
và `repo-basename` trước khi chạy; các lệnh sau chạy từ gốc repo:

```bash
(
  set -e
  SERVER=your-ssh-host
  REPO=repo-basename
  # Nếu SSH IdentityAgent cần XDG_RUNTIME_DIR mà phiên này chưa có:
  # export XDG_RUNTIME_DIR=/run/user/1000  # thay UID cho đúng máy dev
  ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:18888:127.0.0.1:8888 "$SERVER" &
  forward_pid=$!
  seed_config=
  trap 'kill "$forward_pid" 2>/dev/null || true; [ -z "$seed_config" ] || rm -f "$seed_config"' EXIT
  curl -fsS --retry 5 --retry-connrefused --retry-delay 1 http://127.0.0.1:18888/health

  seed_config=$(mktemp)
  chmod 600 "$seed_config"  # trước khi ghi token vào file tạm
  python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); c["apiUrl"]="http://127.0.0.1:18888"; json.dump(c,open(sys.argv[2],"w"))' \
    "$HOME/.hindsight/coding-agent.json" "$seed_config"

  HINDSIGHT_CODING_AGENT_CONFIG="$seed_config" HINDSIGHT_SEED_HTTP_TIMEOUT=900 \
    server-setup/bin/seed-repo-bank.sh "$REPO" --dry-run

  # Kiểm tra RAM trên host trước lần ghi thật; dừng nếu available < 1,5 GiB.
  memory_report=$(ssh "$SERVER" free -m)
  printf '%s\n' "$memory_report"
  available_mib=$(printf '%s\n' "$memory_report" | awk '$1 == "Mem:" {print $7}')
  case "$available_mib" in ''|*[!0-9]*) echo 'Không đọc được RAM available' >&2; exit 1;; esac
  if [ "$available_mib" -lt 1536 ]; then
    echo 'RAM available dưới 1,5 GiB; dừng seed' >&2
    exit 1
  fi
  HINDSIGHT_CODING_AGENT_CONFIG="$seed_config" HINDSIGHT_SEED_HTTP_TIMEOUT=900 \
    server-setup/bin/seed-repo-bank.sh "$REPO"
)
```

Subshell và `trap` luôn dừng SSH forward, xoá cấu hình tạm khi kết thúc hoặc
gặp lỗi. Lệnh Python chỉ ghi JSON vào file đã đặt quyền `0600`, không in token.
`HINDSIGHT_CODING_AGENT_CONFIG` chỉ đổi đường dẫn cấu hình API; script lấy
`CONFIG_DIR` từ vị trí `seed-repo-bank.sh`, nên ledger mặc định vẫn là
`server-setup/state/bank-seed-ledger.jsonl`, **không** chuyển sang `/tmp`.
Nếu đã tự đặt `HINDSIGHT_SEED_LEDGER_FILE` từ trước, trỏ nó về cùng file
ledger này trước khi seed để giữ dữ liệu rollback ở một chỗ.

`<repo-basename>` là tên thư mục của **main worktree** (không phải tên một
linked worktree) — đúng tên repo bạn thấy trong `coding-agent::<repo>`.

**Danh sách "Transfer candidates" chỉ gồm document hội thoại
(`conversation:<session_id>`) — `gitlog:<repo>` không bao giờ nằm trong đó.**
Chính plugin coding-agent tự tạo và tự làm mới `gitlog:<repo>` (và trang
survey-baseline) trong bất kỳ bank nào nó quản lý — xác nhận bằng cách đọc
mã nguồn plugin thật (`~/.hindsight/coding-agents/dist/*.js`, hàm
`gitLogIsCurrent`/`GITLOG_HEAD` trong `src/core/git.ts`): nó tự kiểm tra và
tự "deepen" lại `gitlog:<repo>` ở bank đang dùng, không quan tâm bank đó đã
có gì sẵn. Script này chép document đó vào cũng là ghi vào đúng một
document_id mà **plugin coi là của nó** — tạo ra một cuộc giành quyền ghi
(ownership race) không cần thiết. Document hội thoại thì không có chủ nào
khác: id của nó gắn với một session đã kết thúc từ trước, không ai (kể cả
plugin) có thể tạo lại đúng id đó.

Ví dụ thật (dry-run cho repo pilot `Setup-Hindsight`, lúc viết runbook này —
sau khi phase 2 đã bật — bank đích đã tồn tại, chưa có hội thoại nào map
được qua transcript cục bộ cho repo này):

```
$ server-setup/bin/seed-repo-bank.sh Setup-Hindsight --dry-run
seed-repo-bank: repo=Setup-Hindsight source=user-hieu destination=coding-agent::Setup-Hindsight

DRY RUN -- no API writes, no ledger write.

Destination bank status: exists

Transfer candidates (0) -- conversation documents only, gitlog:Setup-Hindsight is never transferred:
  (none found)

Reflect query (against user-hieu):
  ...

Distill target: coding-agent::Setup-Hindsight document "migrated:user-hieu:Setup-Hindsight" (tags: project:Setup-Hindsight, source:migration)

Ledger (not written): .../server-setup/state/bank-seed-ledger.jsonl
```

Dry-run chỉ đọc (không cần cân nhắc an toàn): kiểm tra bank đích có tồn tại
chưa, tìm các hội thoại map được qua transcript cục bộ, kiểm tra trong số đó
cái nào **đã có sẵn ở bank đích** (nếu bank đích đã tồn tại — nghĩa là một
lần chạy trước đã chép rồi), dựng câu hỏi `reflect`. Khi có document đã có
sẵn, dry-run in thêm một dòng liệt kê — những document đó **không bao giờ**
được tính là "do lần chạy này tạo ra" (không tính vào xác nhận đã chép,
không nằm trong danh sách rollback ở mục 3).

Khi chạy thật, nếu bank đích đã tồn tại, script làm theo thứ tự — **ghi
ledger cho bước 1 ngay sau khi biết kết quả, trước khi làm bước 2**, để một
lần `reflect`/`retain` lỗi ở bước 2 không bao giờ làm mất bản ghi quyền sở
hữu document của bước 1:

1. **Chép chính xác** từng document hội thoại trong "Transfer candidates"
   **chưa có ở bank đích** bằng `document-transfer/export` (bank nguồn) rồi
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

   Khi đang chờ operation, bất kỳ lỗi không dứt khoát nào — timeout, lỗi
   mạng, `429`, `5xx` — đều **không** bị coi là thất bại; script thử lại cho
   đến hết `HINDSIGHT_SEED_OPERATION_TIMEOUT`. Chỉ khi **server trả thẳng**
   `failed`/`cancelled`/`not_found` mới coi là lỗi thật.

   Ghi vào ledger một dòng JSONL riêng (`"stage": "transfer"`) ngay lúc này,
   với một trong các `transfer_status`:
   - **`transferred`**: operation hoàn tất (hoặc đã đối soát xong từ một lần
     `pending` trước — xem dưới), kèm danh sách document đã xác nhận
     (`confirmed_document_ids`) — có thể là danh sách rỗng, nếu mọi
     candidate đều đã có sẵn từ trước.
   - **`skipped`**: server trả thẳng lỗi thật (không phải hết thời gian chờ,
     không phải lỗi mạng/429/5xx). Script **không dừng**: bỏ qua bước chép,
     vẫn tiếp tục bước 2.
   - **`pending`**: hết `HINDSIGHT_SEED_OPERATION_TIMEOUT` mà vẫn chưa biết
     kết quả thật — **khác hẳn với bị bỏ qua**: operation vẫn có thể hoàn
     tất ngay sau khi script thôi chờ. Ledger ghi bank + `operation_id` +
     danh sách candidate đã kiểm tra (`attempted_confirmable_ids`). **Lần
     chạy kế tiếp cho cùng repo (cùng `--source`) sẽ tự kiểm tra lại operation
     đó trước khi làm gì khác** — nếu đã `completed` thì xác nhận đúng danh
     sách `attempted_confirmable_ids` đó (không dùng lại
     pre-existing-check mới của lần chạy này, vì ngay lúc đó document vừa
     mới xuất hiện, dễ bị coi nhầm là "có từ trước"), ghi dòng ledger mới
     với `"reconciles": "<operation_id>"` để đánh dấu dòng `pending` cũ đã
     được giải quyết — **một dòng `pending` chỉ được đối soát đúng một lần**,
     dòng nào đã có một dòng `reconciles` nó rồi thì các lần chạy sau không
     xét lại nữa. Xem mục "Sự cố thường gặp" để tự kiểm tra operation đó sớm
     hơn nếu không muốn chờ lần chạy kế tiếp.
2. `reflect` trên bank nguồn với một bộ câu hỏi cố định về repo (quyết định +
   lý do, quy ước, kiến trúc/thành phần, việc dở dang, lỗi đã gặp), chỉ giữ
   thông tin gắn được với repo. Kết quả được `retain` vào bank đích thành
   document `migrated:<bank nguồn>:<repo>`, tag `project:<repo>` và
   `source:migration`, kèm `update_mode: replace` tường minh. Document này
   dùng `document_id` cố định nên **chạy lại luôn thay thế, không nhân bản**.
   Ghi dòng ledger thứ hai (`"stage": "distill"`), riêng với dòng ở bước 1.

Thư mục `server-setup/state/` không commit (xem `.gitignore`); không dòng
ledger nào ghi nội dung memory, chỉ repo/counts/ids. Script không bao giờ
ghi hoặc xoá bất cứ gì trên **bank nguồn** — chỉ đọc.

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

# 2 dòng mới nhất: dòng transfer rồi dòng distill của lần chạy vừa xong
tail -2 server-setup/state/bank-seed-ledger.jsonl | python3 -c "import sys,json; [print(json.dumps(json.loads(l), indent=2)) for l in sys.stdin]"
```

Nếu dòng ledger `stage: "transfer"` vừa ghi có `"transfer_status": "pending"`,
chưa biết kết quả thật lúc script thôi chờ — **không phải đã bỏ qua**. Tự
kiểm tra ngay (không cần chờ lần chạy kế tiếp):

```bash
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
  | curl -sS -K - "$API/v1/default/banks/<pending_bank từ ledger>/operations/<pending_operation_id từ ledger>"
```

`"status": "completed"` nghĩa là chạy lại script cho repo đó (với cùng
`--source`) sẽ tự đối soát (xác nhận đúng `attempted_confirmable_ids` của
dòng `pending` đó thật sự có, không gửi lại export/import, và ghi dòng mới
với `"reconciles"` chỉ đúng dòng `pending` này — không đối soát lại lần
thứ hai) — xem mục 1 bước 1. Còn `"processing"`/`"pending"` thì chờ thêm rồi
kiểm tra lại, hoặc cứ chạy lại script — đối soát luôn thử trước, không hại
gì.

Chạy lại script lần 2 cho cùng repo rồi lặp lại bước đếm document: số
document bank đích **không tăng thêm** vì phần "chép chính xác" dùng
`on_conflict=skip` và dòng ledger `transfer` thứ hai sẽ có
`confirmed_document_ids` rỗng (không có gì MỚI để xác nhận — lần đầu đã xác
nhận rồi) — đây là cách xác nhận idempotent trên bank thật; ledger ghi đúng
những gì đã xảy ra, chứ không phải nguồn đếm chính (đếm chính luôn là
`GET .../stats` ở trên).

## 3. Rollback (chỉ ở bank đích, không đụng bank nguồn)

**Dùng đúng danh sách ledger đã ghi, không tự suy ra lại bằng `--dry-run`.**
`--dry-run` cho danh sách *candidate* (mọi document có khả năng liên quan
đến repo), không phải danh sách *đã thật sự được script này tạo ra* trong
bank đích — xoá theo danh sách candidate là xoá nhầm dữ liệu không thuộc về
lần seed nào cả. Ledger đã phân biệt đúng việc này.

Repo có thể đã được seed nhiều lần với `--source` khác nhau (bank đích vẫn
chỉ có một) — rollback phải thu đúng **mọi** document đã tạo cho repo đó,
không chỉ từ `--source` mặc định `user-hieu`. Dùng `jq` thu cả hai loại
document ledger xác nhận đã tạo — distill (`stage: "distill"`, mọi nguồn)
và transfer đã xác nhận (`stage: "transfer"`, `transfer_status:
"transferred"`, `confirmed_document_ids`):

```bash
CFG=~/.hindsight/coding-agent.json
TOKEN=$(python3 -c "import json;print(json.load(open('$CFG'))['apiToken'])")
API=$(python3 -c "import json;print(json.load(open('$CFG'))['apiUrl'])")
REPO="<repo-basename>"
DST="coding-agent::$REPO"

jq -r --arg repo "$REPO" '
  select(.repo == $repo) |
  if .stage == "distill" then .distill_document_id
  elif .stage == "transfer" and .transfer_status == "transferred" then (.confirmed_document_ids // [])[]
  else empty end
' server-setup/state/bank-seed-ledger.jsonl | sort -u > /tmp/rollback-ids.txt
cat /tmp/rollback-ids.txt   # xem lại trước khi xoá

while read -r DOC_ID; do
  [ -n "$DOC_ID" ] || continue
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$DOC_ID")
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
    | curl -sS -K - -X DELETE "$API/v1/default/banks/$DST/documents/$ENC"
done < /tmp/rollback-ids.txt
rm -f /tmp/rollback-ids.txt
```

Nếu có dòng ledger `stage: "transfer"`, `transfer_status: "pending"` chưa
được đối soát (mục 2), chạy lại script một lần trước khi rollback để nó tự
đối soát và ghi dòng `confirmed_document_ids` thật — tránh rollback dựa
trên thông tin còn thiếu.

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

### Seed lại định kỳ

Vì `user-hieu` tiếp tục thay đổi và chưa rõ nguồn ghi, mỗi tuần kiểm tra và
seed lại repo còn hoạt động khi chưa xác nhận lần seed gần nhất đã bao phủ
các ghi mới liên quan. Đối chiếu thời điểm ghi mới với các dòng ledger;
chỉ có tên repo trong ledger chưa chứng minh dữ liệu đã cập nhật. Chạy lại
mục 1: các document hội thoại
đã có ở bank đích được bỏ qua theo ID, còn document chưng cất
`migrated:user-hieu:<repo>` giữ cùng ID và được `retain` với
`update_mode: replace`, nên cập nhật thay vì tạo bản trùng.

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
nào, chỉ đọc (số liệu lịch sử ở mục 0 không phản ánh số hiện tại):

```bash
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$TOKEN" \
  | curl -sS -K - -X POST -d '{"query":"<câu hỏi>"}' "$API/v1/default/banks/user-hieu/memories/recall"
```

## 6. Tiêu chí nghỉ hưu `user-hieu` (phase 5 — chưa làm trong PR này)

Chỉ cân nhắc khi **đồng thời**:

1. mọi repo hoạt động trong 30 ngày gần nhất đã được seed hoặc seed lại
   **sau lần ghi gần nhất của repo đó vào `user-hieu`**; kiểm tra thời điểm
   ghi và ledger, không chỉ kiểm tra repo có tên trong ledger;
2. chủ hệ thống xác nhận không còn cần tra trực tiếp `user-hieu` cho việc hiện tại.

Khi đó: ghi nhận `user-hieu` là bank cũ để tra cứu (bank chính nó vẫn
giữ nguyên — không có bank clone riêng, xem mục 0). **Giữ tối thiểu 90 ngày
tính từ lúc nghỉ hưu** (không phải từ lúc viết runbook này) trước khi cân
nhắc xoá. Không xoá từng document khỏi `user-hieu`; nếu xoá thì xoá **toàn bộ
bank**, theo quyết định riêng sau khi đã xác nhận không cần nữa.

**Backup thường kỳ không tự đủ 90 ngày.** Theo `docs/PLAYBOOK.md` mục 4.3,
lifecycle rule trên bucket R2 hết hạn theo tầng: `db/6h/` **7 ngày**,
`db/daily/` **30 ngày**, `db/weekly/` **90 ngày** (đúng ngay biên, có thể
hết hạn cùng ngày tính mốc), chỉ `db/monthly/` mới chắc **"giữ lâu hơn hoặc
vô thời hạn"**; bản local (`backups/`) chỉ giữ 14 bản gần nhất
(`docs/PLAYBOOK.md` mục 3, `HINDSIGHT_BACKUP_KEEP`). Không có bản nào trong
số này **chắc chắn** còn sau 90 ngày trừ `db/monthly/`.

Vì vậy, **ngay lúc nghỉ hưu**, cần một bước riêng: copy bản backup gần nhất
sang một prefix R2 **không nằm trong bất kỳ lifecycle rule nào** (lifecycle
rule hiện chỉ áp cho 4 prefix cố định `db/6h|daily|weekly|monthly/` —
`archive/` không khớp prefix nào trong số đó, nhưng **phải xác nhận lại
trên Cloudflare dashboard** là bucket chưa có rule mới khớp `archive/` trước
khi tin điều này, vì cấu hình lifecycle có thể đã đổi từ lúc viết runbook).
Dùng đúng kỹ thuật `rclone copyto` server-side mà `bin/backup-r2.sh` đã dùng
cho daily/weekly/monthly (copy giữa hai prefix cùng bucket, không tải lại
byte nào):

```bash
# Chạy trên server (~/hindsight/server-setup), SAU KHI xác nhận trên
# Cloudflare dashboard rằng bucket không có lifecycle rule khớp archive/.
# Đây là bước ops riêng khi nghỉ hưu user-hieu -- KHÔNG tự chạy lệnh này,
# để người vận hành (hoặc orchestrator) chạy như một bước ops độc lập.
# Thao tác hoàn toàn trên R2 (rclone copyto server-side, không tải byte về
# máy) -- cùng kỹ thuật `newest()` + copyto mà bin/backup-r2.sh đã dùng cho
# daily/weekly/monthly, không phải file trong backups/ local (tên file local
# và tên object db/6h/ trên R2 không giống nhau -- backups/ dùng giờ Việt
# Nam + label, db/6h/ dùng stamp UTC riêng của backup-r2.sh).
cd ~/hindsight/server-setup
set -a; . ./base.env; [ -f ./secrets.env ] && . ./secrets.env; set +a
RCLONE="${RCLONE_BIN:-$HOME/.local/bin/rclone}"
DEST="r2:$R2_BUCKET"
SRC="$("$RCLONE" lsf "$DEST/db/6h" --files-only --include '*.sql.gz' | sort | tail -1)"
[ -n "$SRC" ] || { echo "no db/6h snapshot found on R2" >&2; exit 1; }
"$RCLONE" copyto "$DEST/db/6h/$SRC" "$DEST/archive/user-hieu-retirement-$SRC"
```

Mốc 90 ngày tính **từ lúc nghỉ hưu** (ngày chạy copy này), không phải từ
ngày của file dump được chọn.

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| `destination bank ... does not exist yet` | Bank đích chưa được plugin tạo — mở repo một lần trong Claude Code/Codex rồi chạy lại |
| `no API token` | Thiếu `HINDSIGHT_API_TOKEN` và không có `apiToken` hợp lệ trong `~/.hindsight/coding-agent.json` |
| `document-transfer failed; skipping it` | **Server trả thẳng** lỗi (không phải timeout, không phải lỗi mạng/429/5xx — những cái đó thành `pending`) — script vẫn chạy xong phần chưng cất; xem `transfer_status: "skipped"` trong dòng ledger `stage: "transfer"`, có thể thử lại sau |
| `document-transfer outcome unknown ... recorded as pending` | Hết `HINDSIGHT_SEED_OPERATION_TIMEOUT` mà vẫn chưa biết kết quả thật (timeout, hoặc mọi lần poll đều lỗi mạng/429/5xx) — **khác với bị bỏ qua**. Xem mục 2 để tự kiểm tra operation đó, hoặc chạy lại script (cùng `--source`) sau để nó tự đối soát — đúng một lần, không đối soát lại dòng đã có `reconciles` trỏ tới |
| `Transfer candidates (0)` ở dry-run | Không hội thoại nào map được qua transcript cục bộ cho repo này — bình thường với repo ít hoạt động trước khi bật per-repo. `gitlog:<repo>` không bao giờ là candidate (mục 1) nên không tính ở đây; phần chưng cất vẫn chạy khi chạy thật |
| `(N ... already exist in the destination bank ...)` ở dry-run | Bình thường trên một rerun (một lần chạy trước đã chép những document đó) — không tính vào xác nhận hay rollback của lần chạy này |
| Ledger không có dòng mới | Script dừng trước khi ghi được dòng `transfer` đầu tiên (ví dụ bank đích thiếu, hoặc lỗi liệt kê document nguồn) — xem log lỗi stderr. Nếu đã có dòng `transfer` nhưng không có dòng `distill` theo sau, `reflect`/`retain` đã lỗi — dòng `transfer` vẫn giữ nguyên, không bị mất |
