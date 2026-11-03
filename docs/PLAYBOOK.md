# Hindsight Self-Host — Playbook vận hành

Tài liệu để **vận hành** server Hindsight (agent memory của Vectorize) trên
`hieu@100.77.187.94`, cùng máy với Multica và Omnigent. Dùng chung khuôn với
`Setup-Multica/server-setup/RUNBOOK.md` và `Setup-Omnigent/docs/RUNBOOK.md`.

Kết nối agent trên máy dev (Claude Code, Codex, …) vào Hindsight qua MCP:
xem `workstation/` (đang làm ở PR khác trong cùng repo) — không lặp lại ở đây.

---

## 1. Kiến trúc trong 1 phút

```
        INTERNET                        UBUNTU 100.77.187.94  (~/hindsight)
 agent/MCP ─► hindsight-api.…dev ─┐    ┌───────────────────────────────────┐
 browser   ─► hindsight.…dev ───┐ │    │ cloudflared-hindsight (QUIC, out) │
                                │ │    │   │                               │
            Cloudflare edge ────┴─┴───►│   ├─► 127.0.0.1:8888  hindsight   │
             (Access trước UI)         │   └─► 127.0.0.1:9999  hindsight   │
                                       │        (API + UI, 1 container)    │
                                       │        postgres (pgvector)        │
                                       │   KHÔNG mở port inbound nào       │
                                       └───────────────────────────────────┘
```

| Thành phần | Ở đâu | Ghi chú |
|---|---|---|
| 2 container | server, project `hindsight` (`hindsight-hindsight-1`, `hindsight-db-1`) | `hindsight` (API :8888 + UI :9999 trong 1 image), `db` (pgvector/pgvector) |
| `cloudflared-hindsight` | server, systemd **user** service, binary host (không phải trong Docker) | không cần sudo, có linger |
| Config | `~/hindsight/server-setup` (git) | = thư mục này |
| Repo | `github.com/tkhieu/Setup-Hindsight` (private) | |
| Dữ liệu persistent | volume `hindsight_pgdata` (Postgres), `hindsight_hf_cache` (model local), `hindsight_chatgpt_credentials` (OAuth) | attachment lưu native trong Postgres (BYTEA) |

**Vì sao không cần checkout upstream riêng:** Hindsight không có file
`docker-compose.yaml` cần sửa tại chỗ như Multica/Omnigent — `compose.yaml`
ở đây là compose của chính chúng ta, viết dựa theo ví dụ `external-pg` chính
thức của Vectorize (đã đối chiếu với source tag `v1.1.0`), cộng thêm:
bind `127.0.0.1`, bật xác thực API key, volume cache model, log rotation,
healthcheck.

**LLM provider:** `chatgpt` mặc định, dùng gói ChatGPT Pro qua OAuth, không
cần OpenAI API key. Model mặc định `gpt-6-luna`. Có thể đổi về `openai` bằng
một dòng trong `base.env` và key trong `secrets.env` (§4.2). Embedding + reranker vẫn
dùng model local mặc định của Hindsight (`bge-small-en-v1.5` +
`ms-marco-MiniLM-L-6-v2`, đã nướng sẵn trong image) — đó là lý do có volume
`hf_cache`: không có nó, mỗi lần tạo lại container sẽ tải lại model.

---

## 2. Truy cập

| Đường | URL / lệnh | Dùng khi |
|---|---|---|
| API (agents/MCP) | https://hindsight-api.hieutk.dev | header `Authorization: Bearer <HINDSIGHT_API_TENANT_API_KEY>` |
| UI | https://hindsight.hieutk.dev | login bằng `HINDSIGHT_CP_ACCESS_KEY` — **đặt Cloudflare Access trước hostname này** (Zero Trust → Access → Applications), access key không phải là lớp bảo vệ duy nhất |
| Admin | `ssh hieu@100.77.187.94` → `cd ~/hindsight/server-setup` | chạy `bin/hs` |
| Break-glass | `ssh -L 8888:127.0.0.1:8888 -L 9999:127.0.0.1:9999 hieu@100.77.187.94` | khi Cloudflare hỏng |

Hai secret khác nhau, đừng nhầm:

- `HINDSIGHT_API_TENANT_API_KEY` — API key cho agent/MCP/HTTP client, dùng
  được ở mọi endpoint `/v1/...` và `/mcp`.
- `HINDSIGHT_CP_ACCESS_KEY` — mật khẩu đăng nhập UI (control plane), hoàn
  toàn tách biệt. UI dùng chính API key ở trên (qua
  `HINDSIGHT_CP_DATAPLANE_API_KEY`, set giống nhau trong `compose.yaml`) để
  tự gọi API cho chính nó — không phải thứ bạn gõ khi login.

---

## 3. Lệnh hằng ngày

Chạy trên server, trong `~/hindsight/server-setup`:

| Việc | Lệnh |
|---|---|
| Trạng thái | `bin/hs ps` |
| Health check | `bin/hs ready` |
| Log | `bin/hs logs -f hindsight` |
| **Áp dụng đổi env** | `bin/hs up -d` |
| Backup tay | `bin/backup.sh` |
| Smoke test (tạo bank, retain, recall) | `bin/smoke.sh` |
| Cloudflare tunnel | `systemctl --user status cloudflared-hindsight` |
| Lịch backup/drill | `systemctl --user list-timers 'hindsight-backup@*' hindsight-restore-drill.timer` |

> ⚠️ **`bin/hs restart` KHÔNG đọc lại env.** Đổi `base.env`/`secrets.env` thì
> luôn dùng `bin/hs up -d`. Container restart, config cũ giữ nguyên — lỗi im
> lặng giống hệt Multica (xem RUNBOOK §8 bên đó).

### Đổi tên Compose project từ `server-setup` (một lần)

Chạy sau khi cập nhật repo trên server, **trước** lệnh `bin/hs up -d` đầu
tiên với compose mới. Project cũ trùng tên với OneAIHub; kiểm tra dry run
trước, rồi chạy migration có chủ đích:

```bash
cd ~/hindsight/server-setup
bin/migrate-project-name.sh --dry-run
bin/migrate-project-name.sh --yes
bin/hs ps
bin/hs ready
bin/smoke.sh
bin/restore-db.sh --drill r2:latest
docker ps --format '{{.Names}}'
```

Hai container mới phải có tên `hindsight-*`; các container OneAIHub vẫn
chạy. Script backup DB trước khi dừng đúng hai container cũ, sao chép ba
volume, chờ `/health`, giữ nguyên volume cũ và network `server-setup_default`.
**Không bao giờ dùng `--remove-orphans`** với project `server-setup` vì sẽ
xóa container của OneAIHub.

Nếu cần quay lại: kiểm tra label `com.docker.compose.project.working_dir`
của `hindsight-db-1` và `hindsight-hindsight-1` trỏ tới thư mục này; chỉ
`docker stop` rồi `docker rm` đúng hai container đó. Sau đó chạy
`COMPOSE_PROJECT_NAME=server-setup bin/hs up -d` và
`COMPOSE_PROJECT_NAME=server-setup bin/hs ready`. Không dùng `compose down`.
Sau khi đã xác minh bản mới và backup, dọn ba volume cũ bằng đúng lệnh:

```bash
docker volume rm server-setup_pgdata server-setup_hf_cache server-setup_chatgpt_credentials
```

Không xóa volume `server-setup_hub-db-data`,
`server-setup_hub-db-timescale-data` hay network `server-setup_default`.

---

## 4. Cài lần đầu (một lần)

### 4.1 Clone + bootstrap

```bash
ssh hieu@100.77.187.94
mkdir -p ~/hindsight && cd ~/hindsight
git clone git@github.com:tkhieu/Setup-Hindsight.git .
git pull --ff-only
cd server-setup
bin/bootstrap.sh
```

`bootstrap.sh` tự sinh `HINDSIGHT_DB_PASSWORD`, `HINDSIGHT_API_TENANT_API_KEY`,
`HINDSIGHT_CP_ACCESS_KEY` (bằng `openssl rand -hex 32`) vào `secrets.env`
(chmod 600); nếu file đã tồn tại, script điền các secret tự sinh còn thiếu hoặc trống.
Lần đầu với `chatgpt`, `bootstrap.sh`
nhắc cài credential và dừng trước khi khởi động API. Làm §4.2 rồi chạy lại
`bin/bootstrap.sh` (giữ nguyên secret đã sinh).

Chạy xong, `bootstrap.sh` tự `pull` + `up -d` + chờ `/health`. API key và
UI password nằm trong `secrets.env`; script không in giá trị. **Backup
`secrets.env` ra ngoài server ngay**
(password manager / máy khác) — mất `HINDSIGHT_API_TENANT_API_KEY` nghĩa là
phải cấp lại key cho mọi agent/MCP client đang dùng.

### 4.2 Đăng nhập ChatGPT trên máy dev

Không cài Python package toàn hệ thống. Máy dev có `uvx`; ép Python 3.11
vì dependency ONNX của v1.1.0 chưa hỗ trợ Python 3.15:

```bash
uvx --python 3.11 --from hindsight-api-slim==1.1.0 hindsight-admin chatgpt login
uvx --python 3.11 --from hindsight-api-slim==1.1.0 hindsight-admin chatgpt status
```

Browser quay về `http://127.0.0.1:1455/auth/callback` **trên máy dev**.
Đồng ý quyền dùng ChatGPT plan. Nếu từ chối, chạy lại `login
--enable-plan-usage`. File `~/.hindsight/chatgpt/credentials.json` được ghi
mode 0600. Chuyển qua stdin từ máy dev, không lưu file trung gian trên host
server (script dùng container chạy một lần để cài credential):

```bash
ssh hieu@100.77.187.94 '~/hindsight/server-setup/bin/chatgpt-login.sh' < ~/.hindsight/chatgpt/credentials.json
ssh hieu@100.77.187.94 '~/hindsight/server-setup/bin/chatgpt-login.sh --status'
uvx --python 3.11 --from hindsight-api-slim==1.1.0 hindsight-admin chatgpt logout --local-only
```

**Chỉ dùng `logout --local-only` trên máy dev.** `logout` thường thu hồi
session trên server. Token refresh xoay vòng nên sau khi chuyển, chỉ server
được dùng bản credential này. Volume `chatgpt_credentials` phải ghi được;
`chatgpt-volume-init` cấp quyền UID 1000 của image. Chạy lại
`bin/bootstrap.sh` để xác nhận status và `/health`.

Đổi sang OpenAI API key: sửa **chỉ** `HINDSIGHT_API_LLM_PROVIDER=openai`
trong `base.env`, điền `HINDSIGHT_API_LLM_API_KEY` trong `secrets.env`, rồi
`bin/hs up -d`. Quay lại ChatGPT: đổi dòng đó thành `chatgpt`, chạy
`bin/hs up -d`; nếu volume mất, đăng nhập và chuyển lại như trên.

### 4.3 Bucket R2 + lifecycle rule + token scoped

1. Cloudflare dashboard → R2 → tạo bucket `hindsight-hieutk-dev-backups`
   (khớp `R2_BUCKET` trong `base.env`; đổi tên thì sửa cả hai).
2. Lifecycle rule trên bucket đó (không cần prefix `staging/` — `backup-r2.sh`
   dump ra file tạm trên đĩa local, validate xong mới upload thẳng vào
   `db/6h/`, không còn bước trung gian nào trên R2):
   - prefix `db/6h/` → expire sau ví dụ **7 ngày**.
   - prefix `db/daily/` → **30 ngày**, `db/weekly/` → **90 ngày**,
     `db/monthly/` → giữ lâu hơn hoặc vô thời hạn, theo nhu cầu.
3. Tạo R2 API token **scoped theo đúng bucket này**, quyền Object Read &
   Write — không cần quyền account-level.
4. Điền vào `secrets.env`: `RCLONE_CONFIG_R2_ENDPOINT`,
   `RCLONE_CONFIG_R2_ACCESS_KEY_ID`, `RCLONE_CONFIG_R2_SECRET_ACCESS_KEY`.

### 4.4 Cài rclone + systemd timer + cloudflared

```bash
bin/install-systemd.sh --dry-run   # xem trước, không đụng gì
bin/install-systemd.sh
```

Script này:

- cài rclone (static binary, `~/.local/bin/rclone`, không cần sudo);
- cài các unit trong `systemd/` vào `~/.config/systemd/user/`, enable +
  start 4 timer backup + 1 timer diễn tập restore;
- copy `cloudflared/config.yml` → `~/.cloudflared/hindsight-config.yml`
  (chỉ copy nếu chưa có — không đè file bạn đã sửa);
- kiểm tra `loginctl ... Linger` — bắt buộc để timer sống qua logout/reboot;
  tự `loginctl enable-linger` nếu chưa bật, báo lỗi rõ nếu cần `sudo` làm
  thay.

`cloudflared-hindsight.service` được **enable nhưng không start** — nó cần
tunnel UUID + file credentials chưa tồn tại. Tạo tunnel:

```bash
cloudflared tunnel login                 # một lần, mở browser xác thực
cloudflared tunnel create hindsight      # in ra UUID + ghi credentials JSON
```

Sửa `~/.cloudflared/hindsight-config.yml`: thay hai chỗ
`REPLACE_WITH_HINDSIGHT_TUNNEL_UUID` bằng UUID vừa tạo (đúng ở cả `tunnel:`
và đường dẫn `credentials-file:`). Rồi trên Cloudflare dashboard (Zero
Trust → Networks → Tunnels → hindsight → Public hostnames), hoặc bằng
`cloudflared tunnel route dns hindsight hindsight-api.hieutk.dev` +
`... hindsight.hieutk.dev`, trỏ hai hostname về tunnel này — ingress rule
bên trong `config.yml` sẽ định tuyến tiếp vào `127.0.0.1:8888`/`:9999`.

```bash
systemctl --user start cloudflared-hindsight
systemctl --user status cloudflared-hindsight
```

Đặt Cloudflare Access trước `hindsight.hieutk.dev` (Zero Trust → Access →
Applications → Self-hosted) — xem §2.

### 4.5 Kiểm tra

```bash
bin/hs ready
bin/smoke.sh
```

---

## 5. Backup

```bash
bin/backup.sh                 # pg_dump local, giữ 14 bản (đổi bằng HINDSIGHT_BACKUP_KEEP)
ls backups/
```

Chỉ cần backup Postgres — attachment Hindsight lưu native trong Postgres
(`BYTEA`, xác nhận trong `hindsight_api/config.py`:
`DEFAULT_FILE_STORAGE_TYPE = "native"`), không có volume uploads riêng. Volume
`hf_cache` chỉ chứa model weight tải lại được, không backup.
Volume `chatgpt_credentials` **không backup lên R2** vì backup R2 hiện không
mã hóa. Mất server thì đăng nhập ChatGPT và chuyển credential lại (§4.2).

### Backup lên R2

Tự động qua systemd user timer (`Persistent=true` nên chạy bù lần bị lỡ khi
máy reboot — vòng lặp sleep trong container không có cơ chế này).

⚠️ **`OnCalendar=` trong các file `.timer` không có hậu tố timezone, nên
systemd hiểu nó theo giờ LOCAL của hệ thống** — có thể là UTC hoặc đã là
Asia/Saigon, tuỳ máy được cài thế nào. Kiểm tra trước khi tin bảng dưới:

```bash
timedatectl   # xem dòng "Time zone:"
```

Bảng dưới ghi theo hai giả định — đọc đúng dòng khớp với output `timedatectl`
của bạn:

| Timer | Nếu server = UTC (literal = UTC) | Nếu server = Asia/Saigon (literal = ICT) | Prefix |
|---|---|---|---|
| `@6h` | 00:15/06:15/12:15/18:15 UTC = 07:15/13:15/19:15/01:15 ICT | 00:15/06:15/12:15/18:15 ICT trực tiếp | `db/6h/` — dump thật |
| `@daily` | 01:05 UTC = 08:05 ICT | 01:05 ICT trực tiếp | `db/daily/` — promote server-side |
| `@weekly` | CN 01:20 UTC = CN 08:20 ICT | CN 01:20 ICT trực tiếp | `db/weekly/` |
| `@monthly` | mùng 1, 01:35 UTC = mùng 1, 08:35 ICT | mùng 1, 01:35 ICT trực tiếp | `db/monthly/` |
| `hindsight-upgrade-check` | CN 02:00 UTC = CN 09:00 ICT | CN 02:00 ICT trực tiếp | không phải backup — kiểm bản mới (§8b) |

Muốn một giờ ICT cụ thể (ví dụ chạy `@daily` đúng 01:05 sáng giờ Việt Nam)
mà server lại đang set UTC: sửa `OnCalendar=` trong file `.timer` tương ứng
trừ đi 7 giờ (01:05 ICT = 18:05 UTC hôm trước), rồi `bin/install-systemd.sh`
lại để cài file đã sửa. `systemd-analyze calendar --iterations=5
'<OnCalendar của bạn>'` in ra lần chạy kế tiếp theo giờ LOCAL hệ thống —
dùng nó để xác nhận trước khi tin bất kỳ con số nào ở đây.

(Lệch 5-15 phút so với timer cùng tên của Multica/Omnigent, tính theo cùng
giờ local của server — xem §9 nếu cả ba có vẻ chạy cùng lúc mà bạn không
ngờ tới.)

```bash
systemctl --user list-timers 'hindsight-backup@*'
journalctl --user -u 'hindsight-backup@6h' -n 30
systemctl --user start hindsight-backup@6h     # chạy ngay
bin/backup-r2.sh 6h                            # chạy tay, xem output trực tiếp
```

**Script không bao giờ xoá.** Hết hạn do R2 lifecycle rule lo (§4.3), nên
server bị chiếm cũng không xoá được lịch sử.

**Dump hợp lệ được xác định bằng cấu trúc, không phải kích thước.**
`bin/backup.sh` và `bin/backup-r2.sh` đều kiểm `gzip -t` + có đúng dòng
chân trang `-- PostgreSQL database dump complete` của `pg_dump`
(`bin/lib/dump.sh`) — **không** còn ngưỡng byte tối thiểu. Một DB mới khởi
tạo, chưa chạy migration nào, dump ra chỉ ~400 byte (đã đo thật) nhưng vẫn
là dump hợp lệ; ngưỡng byte cũ (2048) từng làm chính bước backup an toàn
trước khi restore (§6) fail trên đúng server mới cài.

⚠️ **`RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true` là bắt buộc.** Token R2 scoped
theo bucket không có quyền `CreateBucket`, mà rclone mặc định gọi nó để
kiểm tra bucket tồn tại trước khi upload → mọi lần ghi fail với
`CreateBucket 403 AccessDenied`. Lỗi này trông hệt như credential sai.

---

## 6. Restore (thật)

`bin/restore-db.sh` là **nguồn sự thật duy nhất** cho restore — cả restore
thật và diễn tập đều đi qua nó.

```bash
bin/restore-db.sh r2:latest              # bản 6h mới nhất trên R2
bin/restore-db.sh r2:latest:weekly       # bản weekly mới nhất
bin/restore-db.sh r2:db/daily/20260901T010500Z.sql.gz   # key chính xác
bin/restore-db.sh backups/20260901-120000-manual-db.sql.gz   # file local
```

Thứ tự thực hiện (fail-closed — mọi bước fetch/verify/**import thử** chạy
TRƯỚC khi đụng gì tới DB thật hay dừng app; destructive thật sự chỉ bắt
đầu từ bước 8):

1. Tải bản dump (hoặc copy file local) vào file tạm.
2. Verify: không rỗng, `gunzip -t` qua được.
3. **Validate cấu trúc** (`bin/lib/dump.sh`): phải có đúng header
   `\restrict <key>` + banner `-- PostgreSQL database dump` + ít nhất một
   dòng `SET `, và trailer khớp key `\unrestrict <key>` — không chỉ
   `gunzip -t` (file gzip hợp lệ nhưng toàn rác KHÔNG phải SQL vẫn qua được
   `gunzip -t`).
4. **`bin/hs up -d db`** — đảm bảo riêng `db` đang chạy (KHÔNG động vào
   `hindsight`). Đây là restore "lạnh" thật sự: server mới, chưa chạy gì,
   hoặc đang hồi phục sau sự cố mà không có gì đang chạy.
5. **Import thử vào DB tạm `restoretest_<ts>_<pid>`** — đúng logic
   `--drill` (xem §7): import toàn bộ dump, kiểm 4 bảng cốt lõi. SQL hợp lệ
   về cú pháp gzip nhưng sai (hoặc dump thiếu bảng cốt lõi) bị bắt NGAY ĐÂY,
   trước khi DB thật hay `hindsight` bị động tới. Cần đĩa trống ≈ bằng
   kích thước DB thật (import thêm một bản sao đầy đủ, tạm thời) — kiểm
   trước khi restore dump lớn:
   ```bash
   bin/hs exec -T db psql -U hindsight_user -d hindsight_db \
     -tAc "SELECT pg_size_pretty(pg_database_size('hindsight_db'));"
   df -h /var/lib/docker   # hoặc nơi Docker lưu volume trên server bạn
   ```
6. Xoá DB tạm (`dropdb`). **Xoá fail cũng dừng script** (không chỉ cảnh
   báo) — DB thật và `hindsight` vẫn chưa bị đụng, nhưng dropdb fail là
   dấu hiệu bất thường ở container `db` đáng dừng lại kiểm tra, không nên
   âm thầm tiếp tục.
7. Hỏi xác nhận (bỏ qua bằng `--yes`) — chỉ tới đây mới hỏi, sau khi đã
   biết chắc dump import được.
8. `bin/hs stop hindsight`, xác nhận đã dừng thật (không chỉ tin lệnh
   stop) — làm TRƯỚC bước backup, không phải sau: backup trước rồi mới
   dừng để lại khoảng hở, ghi dữ liệu giữa hai mốc đó vừa không có trong
   bản pre-restore vừa mất luôn khi `DROP DATABASE` ở bước 10.
9. **Backup pre-restore local** — bắt buộc phải thành công, nếu không
   script dừng tại đây (hindsight đã dừng nhưng DB thật chưa bị đụng gì).
10. `DROP DATABASE ... WITH (FORCE); CREATE DATABASE ...`
11. Restore (`psql -1 -f -` — một transaction, lỗi giữa đường thì rollback
    toàn bộ, không để DB ở trạng thái nửa vời — dù ở điểm này gần như không
    thể fail nữa, vì bước 5 đã chứng minh đúng bản dump này import sạch).
12. `bin/hs up -d hindsight` + `bin/hs ready` — dùng `up -d`, không phải
    `start`, vì `start` chỉ khởi động được container ĐÃ TỒN TẠI; sau `hs down`
    hoặc trên server chưa từng chạy, container đó chưa được tạo, `start` sẽ
    im lặng không làm gì và `hs ready` sẽ timeout vào chỗ không có gì đang
    chạy. Bỏ qua bước này bằng `--no-start`, dùng trong rollback của
    `upgrade.sh` — image cũ tự lên lại ở bước sau.

Nếu bước 11 fail: hindsight **không** được start lại, script in sẵn lệnh
restore lại từ bản pre-restore vừa tạo ở bước 9.

---

## 7. Diễn tập restore

### Thế nào là diễn tập

```bash
bin/restore-db.sh --drill r2:latest
```

Restore vào DB tạm `restoretest_<timestamp>_<pid>` (tên duy nhất mỗi lần
chạy — không thể trùng và xoá nhầm DB có sẵn), kiểm tra 4 bảng cốt lõi
(`banks`, `memory_units`, `entities`, `documents`) **tồn tại** (bắt buộc,
không điều kiện — bắt lỗi schema/dump hỏng).

Số dòng tối thiểu **chỉ áp dụng cho một bảng duy nhất: `banks`**, qua
`HINDSIGHT_DRILL_MIN_ROWS` (mặc định `1`) — không có knob nào khác, không
bảng nào khác bị so với nó:

- `banks` phải ≥ `HINDSIGHT_DRILL_MIN_ROWS` — phép kiểm "có phải backup của
  instance đã dùng thật không"; set `HINDSIGHT_DRILL_MIN_ROWS=0` nếu server
  mới cài chưa từng tạo bank nào.
- `memory_units`, `entities`, `documents` **chỉ cần tồn tại, không bắt số
  dòng tối thiểu** — cả ba đều hợp lệ khi bằng 0: một bank có thể chưa
  retain gì (`PUT /v1/default/banks/{id}` tạo bank ngay, memory bằng 0,
  bình thường, không phải lỗi); entity là sản phẩm của một bước trích xuất
  riêng trên nội dung đã retain (`models.py: Entity.bank_id`, bảng nối
  `unit_entities`) — nội dung không sinh ra entity nào là bình thường;
  `memory_units.document_id` cũng không có ràng buộc NOT NULL buộc mọi
  memory phải thuộc một document.

Sau đó **luôn xoá** `restoretest_*` dù thành công hay thất bại. **Không bao
giờ đụng tới DB thật hoặc dừng `hindsight`.**

```bash
bin/restore-db.sh --drill --drill-full r2:latest
```

Thêm một bước: dựng tạm 1 container `hindsight` trỏ vào DB tạm, trên port
rảnh `127.0.0.1:18888` (đổi bằng `HINDSIGHT_DRILL_PORT`), chờ `/health`, so
`total` của `GET /v1/default/banks` giữa container tạm và instance đang
sống. Container tạm luôn bị xoá ở cuối (`docker rm -f`), dù kết quả gì.

### Lịch tự động

Timer `hindsight-restore-drill.timer` chạy `--drill r2:latest` (không có
`--drill-full`, vì nó cần mở thêm port và tốn thêm vài chục giây — không
cần chạy tự động hằng tháng), `OnCalendar=*-*-14 20:30:00` (`RandomizedDelaySec=900`).
**Đây là giờ LOCAL của server, cùng cảnh báo TZ ở §5** — kiểm tra
`timedatectl` trước khi tin giờ thật:

| Nếu server = UTC | Nếu server = Asia/Saigon |
|---|---|
| 20:30 ngày 14 UTC = **03:30 ICT ngày 15** | **20:30 ICT ngày 14** trực tiếp |

Muốn cố định một giờ ICT cụ thể bất kể server set TZ gì: sửa `OnCalendar=`
trong `systemd/hindsight-restore-drill.timer` rồi chạy lại
`bin/install-systemd.sh`, theo cách tính ở §5.

```bash
systemctl --user list-timers hindsight-restore-drill.timer
journalctl --user -u hindsight-restore-drill -n 50
systemctl --user start hindsight-restore-drill   # chạy ngay, không đợi lịch
```

### Đọc kết quả thế nào

- **Thành công:** journal in số dòng từng bảng + dòng cuối
  `Drill OK — restoretest_... dropped.` exit code 0.
- **Thất bại ở bước tải/verify dump:** dump trên R2 đang hỏng/rỗng — kiểm
  tra `bin/backup-r2.sh` có chạy đúng giờ không (§5), xem có phải
  `RCLONE_CONFIG_R2_NO_CHECK_BUCKET` thiếu không.
- **Thất bại "table ... missing":** schema trong dump không khớp — dump từ
  version cũ hơn trước một migration lớn, hoặc dump bị cắt giữa đường.
- **Thất bại "'banks' has N row(s) (< HINDSIGHT_DRILL_MIN_ROWS)":** dump
  trông như của một instance chưa ai dùng — có thể đúng (server mới, chưa
  tạo bank nào — set `HINDSIGHT_DRILL_MIN_ROWS=0` để qua bước này) hoặc sai
  (backup-r2.sh đang dump nhầm DB/schema). Đây là bảng DUY NHẤT bị so số
  dòng — `memory_units`/`entities`/`documents` chỉ cần tồn tại, một bank
  chưa retain gì (0 memory) không bao giờ làm fail bước này.
- **`--drill-full` báo "bank count mismatch":** có thể chỉ vì có bank mới
  tạo SAU thời điểm dump — chạy lại với `r2:latest` (bản mới nhất) để xác
  nhận; nếu vẫn lệch, nghi ngờ dump bị thiếu dữ liệu.
- Chạy tay bất cứ lúc nào để xác minh ngay sau một thay đổi lớn (migration,
  nâng version) thay vì đợi lịch hằng tháng.

---

## 8. Upgrade + Rollback

```bash
bin/upgrade.sh 1.2.0
```

Thứ tự: in diff commit giữa hai tag trên GitHub (`gh api ... compare`, bỏ
qua nếu không có `gh`) → hỏi xác nhận → **pull image đích** (CHƯA đổi gì
trên đĩa — pull lỗi thì không có gì phải rollback) → **dừng `hindsight`**
(giữ `db` sống) → **backup local** (bắt buộc — đây là bản dump duy nhất
dùng để rollback) → best-effort snapshot R2 `6h` của đúng bản đó → bump
`version.env` → `up -d` → chờ `/health` tối đa 5 phút.

**Vì sao dừng app TRƯỚC khi backup, không phải sau:** backup lấy *trước*
khi dừng app để lại một khoảng hở — mọi ghi dữ liệu xảy ra giữa lúc backup
xong và lúc app thực sự dừng sẽ mất nếu sau này phải rollback về bản đó.
Dừng app rồi mới backup đảm bảo bản dump là đúng-y trạng thái cuối cùng của
version cũ, không thiếu không dư.

Trap bắt lỗi được gắn **ngay trước** lệnh dừng `hindsight` — không phải sau
backup — nên mọi lỗi từ đó trở đi (dừng app fail, backup fail, hay bất cứ
gì sau đó) đều được xử lý, không exit im lặng bỏ app ở trạng thái dừng mà
không nói gì:

- **Nếu lỗi xảy ra TRƯỚC khi `version.env` bị đổi** (dừng app fail, backup
  fail, …): `version.env` vẫn còn version cũ, nên script tự chạy
  `hs up -d` để khởi động lại `hindsight` trên version cũ — không có gì
  trong DB cần rollback vì chưa đụng gì tới DB.
- **Nếu lỗi xảy ra SAU khi `version.env` đã đổi** (lên `up -d`/chờ
  `/health` fail): in lệnh rollback đúng thứ tự, nêu rõ tên file dump vừa
  tạo:

```bash
bin/hs stop hindsight
sed -i 's|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=<cũ>|' version.env
bin/restore-db.sh --yes --no-start <bản dump pre-upgrade>
bin/hs up -d
bin/hs ready
```

**Vì sao phải restore DB khi rollback:** Hindsight chạy migration khi
khởi động (`HINDSIGHT_API_RUN_MIGRATIONS_ON_STARTUP`, mặc định bật, migration
tự nhận là idempotent) — migration là **forward-only**. Khởi động lại image
cũ trên một DB mà image mới đã migrate là đi ngược, không phải là rollback.
`restore-db.sh` ở bước 3 phục hồi đúng bản dump lấy từ *trước* khi migration
mới chạy — và vì app đã dừng khi lấy bản đó (xem trên), phục hồi nó không
làm mất ghi dữ liệu nào.

Sau khi upgrade xong (dù rollback hay thành công): commit + push
`version.env` — script tự in sẵn lệnh đúng, dùng `git -C <repo-root>` nên
chạy được dù bạn đang ở cwd nào, không chỉ từ `~/hindsight/server-setup` —
rồi chạy `bin/smoke.sh`.

### 8b. Kiểm tra bản mới hằng tuần (tự động)

```bash
bin/check-upstream.sh             # chạy tay, giống hệt lịch tự động
bin/check-upstream.sh --dry-run   # chỉ đọc (release info, GHCR tag) — không upgrade/issue/push
```

**Tự động vs thủ công — HUMAN DECISION cố định trong script, không có cờ
nào đổi được:**

- **PATCH** (cùng MAJOR.MINOR, PATCH cao hơn, ví dụ `1.1.0 -> 1.1.1`): tự
  động chạy `bin/upgrade.sh --yes --auto-rollback --smoke <ver>`; thành
  công thì tự commit + push `version.env` (deploy key read-write đã cấu
  hình sẵn trên server, host alias `github-setup-hindsight`) và mở issue.
- **MINOR/MAJOR**: **không bao giờ** tự áp dụng — chỉ mở issue kèm link
  release + lệnh chạy tay (`bin/upgrade.sh <ver>`, vẫn hỏi xác nhận như
  bình thường).
- Prerelease/draft và version cũ hơn hiện tại: bỏ qua lặng lẽ (`exit 0`,
  không issue).
- Lỗi gọi API GitHub (403/5xx) hoặc không thấy tag trên GHCR: log lỗi,
  `exit 1`, **không** mở issue — tránh spam khi chính bước kiểm tra bị lỗi.
- Repo trên server dirty, hoặc không đang ở branch `main`, hoặc `main` lệch
  so với `origin/main` (không fast-forward được): không tự upgrade, mở
  issue "...auto-upgrade blocked (repo not clean)" thay vào đó.
- **Chống trùng issue:** mọi issue gắn label `hindsight-upgrade`; trước khi
  tạo mới, script tìm issue ĐANG OPEN có đúng title (REST API, không phải
  so gần đúng) — có rồi thì không tạo thêm. Tối đa 1 issue cho mỗi cặp
  (loại thông báo, version).

**Tạo token `GITHUB_ISSUE_TOKEN` (`secrets.env`):**
1. GitHub → Settings → Developer settings → **Fine-grained tokens** →
   Generate new token.
2. Resource owner: `tkhieu`. Repository access: **Only select
   repositories** → chọn đúng `Setup-Hindsight` (không chọn thêm repo nào).
3. Permissions → Repository permissions → **Issues: Read and write**.
   Không cấp quyền nào khác.
4. Generate, dán vào `GITHUB_ISSUE_TOKEN=` trong `secrets.env` trên server
   (không commit).
5. Để trống: script vẫn chạy đầy đủ, kể cả tự nâng patch — chỉ riêng bước
   tạo issue bị bỏ (log `NOTE:`/`WARNING:` thay vào đó).

Token này cũng được gửi kèm khi gọi API release của
`vectorize-io/hindsight` để có rate limit cao hơn (5000/h thay vì 60/h không
auth) — an toàn vì fine-grained token mặc định có quyền đọc MỌI repo
public, không chỉ repo chọn ở bước 2.

**Khoá chạy đơn:** script tự cầm `flock` riêng
(`server-setup/.check-upstream.lock`) — không dùng chung với
backup/restore-drill vì hai cái đó hiện chưa có khoá nào. Chạy tay khi timer
đang chạy sẽ thấy `another run is already in progress` và `exit 1` ngay,
không chờ.

**Auto-rollback hoạt động thế nào (và mất dữ liệu đến đâu):** giống đúng
quy trình rollback thủ công ở §8 — dừng `hindsight`, trả `version.env` về
version cũ, `bin/restore-db.sh --yes --no-start` đúng bản dump pre-upgrade,
`up -d` + chờ `/health` trên version cũ — chỉ khác là làm tự động thay vì
in lệnh ra cho người chạy tay. **Khoảng mất dữ liệu:** `bin/upgrade.sh` dừng
`hindsight` TRƯỚC khi lấy bản dump pre-upgrade (§8), nên bản dump đó là
đúng-y trạng thái cuối của version cũ — chưa mất gì tính đến lúc đó. Chỉ
những ghi dữ liệu xảy ra SAU khi version mới `up -d` trong CHÍNH lần chạy
auto-upgrade đó (và trước khi lỗi bị phát hiện) mới mất khi rollback — cửa
sổ này không tích lũy qua nhiều lần chạy, chỉ tồn tại trong một lần upgrade
đang thất bại.

**Đọc journal:**
```bash
journalctl --user -u hindsight-upgrade-check -n 100 --no-pager
systemctl --user list-timers hindsight-upgrade-check.timer
systemctl --user start hindsight-upgrade-check    # chạy ngay, không đợi lịch
```

**Issue nghĩa là gì:**

| Title | Nghĩa |
|---|---|
| `Hindsight auto-upgraded to X.Y.Z` | Patch đã tự nâng xong, smoke test pass, `version.env` đã commit + push. |
| `Hindsight auto-upgrade to X.Y.Z failed (rolled back)` | Patch tự nâng fail, đã auto-rollback về version cũ; `version.env` KHÔNG đổi, không commit/push. Log tail (đã redact secret) nằm trong issue. |
| `Hindsight X.Y.Z available (manual upgrade)` | Có bản MINOR/MAJOR mới — xem xét rồi tự chạy `bin/upgrade.sh X.Y.Z` khi sẵn sàng. |
| `Hindsight X.Y.Z available but auto-upgrade blocked (repo not clean)` | Có patch mới nhưng repo trên server dirty / lệch `origin/main` — dọn repo (`git status`, `git pull`) rồi chạy tay `bin/upgrade.sh X.Y.Z`. |

---

## 9. Triệu chứng → nguyên nhân

| Triệu chứng | Nguyên nhân thật | Xử lý |
|---|---|---|
| Đổi env mà không có tác dụng | dùng `restart` thay vì `up -d` | `bin/hs up -d` |
| `bin/hs ready` fail ngay sau `up -d` | container cần vài giây để migration chạy xong | mặc định chờ tới 60s; `HINDSIGHT_READY_TIMEOUT=180 bin/hs ready` nếu cần lâu hơn |
| `hs up` báo thiếu secret và dừng | `secrets.env` thiếu file, tenant/UI key trống, hoặc provider API-key thiếu `HINDSIGHT_API_LLM_API_KEY` | `bin/bootstrap.sh` (idempotent); với OpenAI điền key |
| `hs up` báo ChatGPT credentials thiếu | chưa chuyển credential hoặc plan scope chưa được cấp | làm lại §4.2; kiểm `bin/chatgpt-login.sh --status` |
| `hindsight-admin chatgpt login` báo `Fetching OpenAI JWKS returned HTTP 503` | OpenAI tạm thời không phục vụ JWKS | thử lại sau; kiểm `chatgpt status` thành công trên máy dev trước khi chuyển credential |
| Retain/recall báo refresh token invalid | session ChatGPT hết hiệu lực | đăng nhập lại trên máy dev, chuyển lại bằng `bin/chatgpt-login.sh`, sau đó `logout --local-only` trên máy dev |
| Retain/recall bị trì hoãn khi hết hạn mức Pro | ChatGPT plan đã hết usage trong chu kỳ | xem ChatGPT Settings → Usage; Hindsight hoãn retain/consolidation rồi thử lại sau 30 phút |
| Retain/recall lỗi với provider OpenAI | API key sai/hết quota | xem `bin/hs logs hindsight \| grep -i openai` |
| UI load được nhưng gọi API lỗi 401 | `HINDSIGHT_CP_DATAPLANE_API_KEY` lệch `HINDSIGHT_API_TENANT_API_KEY` | hai biến này PHẢI giống nhau trong `compose.yaml` (đã set cứng — nếu bạn tự sửa compose, đừng tách ra) |
| Container tạo lại xong, retain đầu tiên chậm hẳn | volume `hf_cache` bị xoá/mount sai, model tải lại từ HuggingFace | `docker volume inspect hindsight_hf_cache`; đừng `docker volume rm` volume này khi không cố ý |
| Cùng lúc 3 app backup, máy chậm hẳn lúc 01:00-01:35 (giờ local server, xem §5) | Multica/Omnigent/Hindsight timer gần giờ nhau (đã lệch 5-15 phút có chủ đích, nhưng `RandomizedDelaySec` vẫn có thể trùng ngẫu nhiên) | `systemctl --user list-timers` xem giờ chạy thật; không phải lỗi, chỉ là trùng xác suất thấp |
| `site trả 502/530` | cloudflared chết hoặc container down | `systemctl --user status cloudflared-hindsight` → `bin/hs ps` |
| Backup R2 fail với `CreateBucket 403` | thiếu `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`, hoặc token R2 sai scope | xem §5 |
| Timer không chạy sau khi SSH logout | chưa `loginctl enable-linger` | `bin/install-systemd.sh` tự kiểm tra, báo lỗi rõ nếu cần `sudo` làm thay |
| Diễn tập restore fail "table missing/empty" | xem §7 "Đọc kết quả thế nào" | |
| `check-upstream.sh` không tạo issue, chỉ log `NOTE/WARNING` | thiếu `GITHUB_ISSUE_TOKEN` trong `secrets.env` | tạo token theo §8b nếu muốn có issue; patch vẫn tự nâng dù thiếu token |
| `check-upstream.sh` báo "another run is already in progress" | một lần chạy khác (tay hoặc timer) đang giữ `.check-upstream.lock` | đợi lần đó xong; không phải lỗi |
| Patch mới nhưng issue báo "auto-upgrade blocked (repo not clean)" | repo trên server dirty hoặc `main` lệch `origin/main` | `git -C ~/hindsight status`, `git pull`/`git stash` rồi chạy tay `bin/upgrade.sh X.Y.Z` |
| Muốn xem compose đã resolve image/port/volume đúng chưa | `hs config` (không flag) in MỌI secret đã resolve ra stdout | chỉ dùng `hs config --services` hoặc `hs config --quiet` (validate, không in secret); hai flag này cố ý là lựa chọn DUY NHẤT được cho phép |

**Đọc log đúng chỗ:**
```bash
bin/hs logs --timestamps --since 10m hindsight | grep -iE 'ERR|WRN'
journalctl --user -u cloudflared-hindsight -n 50 --no-pager
journalctl --user -u 'hindsight-backup@*' -n 50 --no-pager
```

---

## 10. Không bao giờ commit

- `secrets.env` (API key OpenAI, API key Hindsight, mật khẩu Postgres, mật
  khẩu UI, credential R2).
- `backups/` (chứa dump DB — cùng mức nhạy cảm với chính DB).
- Credentials JSON của cloudflared (`~/.cloudflared/*.json`) — không nằm
  trong repo này, sống hẳn ngoài `~/hindsight`.
- `~/.cloudflared/hindsight-config.yml` **đã điền UUID thật** — bản trong
  git (`server-setup/cloudflared/config.yml`) chỉ là template với
  placeholder, không bao giờ sửa nó để chứa UUID/credentials thật rồi commit.

**Secret không bao giờ nằm trong argv của process** (đọc được bởi bất kỳ
user nào trên máy qua `ps`/`/proc/<pid>/cmdline`, không chỉ qua `git`):
`smoke.sh`/`restore-db.sh --drill-full` gửi API key cho `curl` qua `-K -`
(đọc config từ stdin) chứ không phải `-H`; mật khẩu Postgres cho
`docker compose run` qua `-e TEN_BIEN` (chỉ tên, giá trị lấy từ environment
của process, không phải `-e TEN_BIEN=giá_trị`). Nếu bạn thêm lệnh mới gọi
`curl`/`docker`/`psql`/`rclone` với một secret, giữ đúng hai khuôn này.

Repo là private (`github.com/tkhieu/Setup-Hindsight`), nhưng vẫn áp dụng
quy tắc như mọi repo secret khác: review `git status`/`git diff` trước khi
commit, đặc biệt sau khi chạy `bin/bootstrap.sh` hoặc sửa `secrets.env`.
