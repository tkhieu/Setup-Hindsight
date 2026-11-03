#!/usr/bin/env bash
# Single source of truth for restoring the Hindsight Postgres database — a
# real restore (replaces the live DB) and a drill (throwaway DB, never
# touches the live DB or app) both go through this script. Fail-closed:
# fetches and verifies the dump BEFORE touching anything, and does not
# start hindsight back up if the restore itself fails.
#
# Usage:
#   bin/restore-db.sh [--yes] [--no-start] <source>
#   bin/restore-db.sh --drill [--drill-full] <source>
#
# <source> is one of:
#   r2:latest[:6h|daily|weekly|monthly]   newest snapshot in that R2 tier (default: 6h)
#   r2:<key>                              exact R2 object key, e.g. r2:db/weekly/20260901T000000Z.sql.gz
#   <path>                                local *-db.sql.gz file
#
# --yes         skip the confirmation prompt (for scripted/rollback use)
# --no-start    restore but leave hindsight stopped (used by bin/upgrade.sh's
#               rollback, which starts the OLD image itself afterwards)
# --drill       restore into a throwaway `restoretest_<ts>_<pid>` database,
#               assert core Hindsight tables exist with sane row counts, then
#               always drop it again — never touches the real database or app.
# --drill-full  on top of --drill: also boot a temporary hindsight container
#               against the drill database on a spare 127.0.0.1 port, wait
#               for /health, and compare its bank count to the live instance's.
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
HS="$CONFIG_DIR/bin/hs"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ask() { read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }

YES=0
NO_START=0
DRILL=0
DRILL_FULL=0
SOURCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --no-start) NO_START=1 ;;
    --drill) DRILL=1 ;;
    --drill-full) DRILL=1; DRILL_FULL=1 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) SOURCE="$1" ;;
  esac
  shift
done
[ -n "$SOURCE" ] || { echo "usage: restore-db.sh [--yes] [--no-start] <source>   (or --drill [--drill-full] <source>)" >&2; exit 1; }

set -a
# shellcheck disable=SC1091
. "$CONFIG_DIR/base.env"
# shellcheck disable=SC1091
[ -f "$CONFIG_DIR/secrets.env" ] && . "$CONFIG_DIR/secrets.env"
set +a

DB_USER="${HINDSIGHT_DB_USER:-hindsight_user}"
DB_NAME="${HINDSIGHT_DB_NAME:-hindsight_db}"

# ---- resolve <source> to an R2 key or a local path ------------------------
R2_KEY=""
LOCAL_PATH=""
case "$SOURCE" in
  r2:*)
    RCLONE="${RCLONE_BIN:-$HOME/.local/bin/rclone}"
    [ -x "$RCLONE" ] || { echo "rclone not found at $RCLONE — run bin/install-systemd.sh" >&2; exit 1; }
    for v in R2_BUCKET RCLONE_CONFIG_R2_ENDPOINT RCLONE_CONFIG_R2_ACCESS_KEY_ID RCLONE_CONFIG_R2_SECRET_ACCESS_KEY; do
      [ -n "${!v:-}" ] || { echo "missing required var: $v (see secrets.env.example)" >&2; exit 1; }
    done
    case "$SOURCE" in
      r2:latest | r2:latest:*)
        tier="${SOURCE#r2:latest}"
        tier="${tier#:}"
        tier="${tier:-6h}"
        case "$tier" in
          6h | daily | weekly | monthly) ;;
          *) echo "invalid tier: $tier (want 6h|daily|weekly|monthly)" >&2; exit 1 ;;
        esac
        name="$("$RCLONE" lsf "r2:$R2_BUCKET/db/$tier/" --files-only --include '*.sql.gz' 2>/dev/null | sort | tail -1)"
        [ -n "$name" ] || { echo "no snapshot found under db/$tier/" >&2; exit 1; }
        R2_KEY="db/$tier/$name"
        ;;
      *)
        R2_KEY="${SOURCE#r2:}"
        ;;
    esac
    ;;
  *)
    LOCAL_PATH="$SOURCE"
    [ -f "$LOCAL_PATH" ] || { echo "not found: $LOCAL_PATH" >&2; exit 1; }
    ;;
esac

# ---- 1. fetch to a temp file (always cleaned up) --------------------------
TMP="$(mktemp)"
DRILL_DB=""
DRILL_CREATED=0
DRILL_CID=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup_restore() {
  local status=$?
  if [ -n "$DRILL_CID" ]; then
    docker rm -f "$DRILL_CID" >/dev/null 2>&1 || echo "WARNING: could not remove drill-full container $DRILL_CID — remove it manually: docker rm -f $DRILL_CID" >&2
  fi
  if [ "$DRILL_CREATED" = 1 ]; then
    if ! "$HS" exec -T db dropdb -U "$DB_USER" --if-exists "$DRILL_DB"; then
      echo "ERROR: dropping $DRILL_DB failed — drop it manually: hs exec -T db dropdb -U $DB_USER $DRILL_DB" >&2
      status=1
    fi
  fi
  if ! rm -f "$TMP"; then
    echo "ERROR: removing temporary dump $TMP failed" >&2
    status=1
  fi
  if [ "$DRILL" = 1 ] && [ "$status" -eq 0 ]; then
    echo
    echo "Drill OK — $DRILL_DB dropped."
  fi
  exit "$status"
}
trap cleanup_restore EXIT

if [ -n "$R2_KEY" ]; then
  say "Fetching r2:$R2_BUCKET/$R2_KEY"
  "$RCLONE" copyto "r2:$R2_BUCKET/$R2_KEY" "$TMP"
else
  say "Using local file $LOCAL_PATH"
  cp "$LOCAL_PATH" "$TMP"
fi

# ---- 2. verify BEFORE touching anything ------------------------------------
[ -s "$TMP" ] || { echo "ERROR: fetched file is empty" >&2; exit 1; }
gunzip -t "$TMP" || { echo "ERROR: dump is corrupt (gunzip -t failed)" >&2; exit 1; }
echo "    ok: $(stat -c%s "$TMP") bytes, gzip-valid"

if [ "$DRILL" = 1 ]; then
  # ---- drill: restore into a throwaway DB; real DB/app untouched ---------
  # Unique name per run so this can never collide with (and drop) a
  # pre-existing database of the same name.
  DRILL_DB="restoretest_$(date +%s)_$$"
  say "Drill restore -> $DRILL_DB (real database and hindsight untouched)"

  "$HS" exec -T db createdb -U "$DB_USER" "$DRILL_DB"
  DRILL_CREATED=1

  if ! gunzip -c "$TMP" | "$HS" exec -T db psql -v ON_ERROR_STOP=1 -1 -f - -U "$DB_USER" -d "$DRILL_DB" -q; then
    echo "ERROR: drill import into $DRILL_DB failed" >&2
    exit 1
  fi

  say "Checking core tables"
  # Confirmed table names and schema: hindsight_api/models.py
  # __tablename__ = banks/memory_units/entities/documents.
  #
  # Existence is checked unconditionally for all four — that catches a
  # corrupt dump or a schema mismatch regardless of how much data is in it.
  #
  # Non-zero is asserted more narrowly, justified from the v1.1.0 schema:
  #   - banks: a dump worth protecting with backups should have at least
  #     one, so this is the real "does this look like a used instance"
  #     check (override with HINDSIGHT_DRILL_MIN_ROWS=0 for a genuinely
  #     fresh install that has never had a bank created).
  #   - memory_units: only required non-zero when banks has data — a bank
  #     can legitimately exist with nothing retained into it yet
  #     (PUT /v1/default/banks/{id} creates one with zero memories), so
  #     banks>0 with memory_units=0 is only suspicious, not definitionally
  #     broken, but banks>0 while the dump otherwise looks totally empty of
  #     content is exactly the "truncated dump" shape this check exists for.
  #   - entities: Entity rows come from a separate extraction step over
  #     memory_units' content (models.py: Entity.bank_id, UnitEntity join
  #     table) — content that yields no identifiable named entities is
  #     normal, so zero entities does not mean the dump is broken.
  #   - documents: MemoryUnit.document_id is nullable with no NOT NULL
  #     constraint tying every memory unit to a document row, so this
  #     table being empty does not by itself prove anything is missing
  #     either.
  MIN_ROWS="${HINDSIGHT_DRILL_MIN_ROWS:-1}"
  banks_count=0
  memory_units_count=0
  for table in banks memory_units entities documents; do
    count="$("$HS" exec -T db psql -U "$DB_USER" -d "$DRILL_DB" -tAc "SELECT count(*) FROM $table;" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$count" ]; then
      echo "ERROR: table '$table' missing or unreadable in the restored dump" >&2
      exit 1
    fi
    echo "    $table: $count rows"
    case "$table" in
      banks) banks_count="$count" ;;
      memory_units) memory_units_count="$count" ;;
    esac
  done

  if [ "$banks_count" -lt "$MIN_ROWS" ]; then
    echo "ERROR: 'banks' has $banks_count row(s) (< $MIN_ROWS) — restored dump looks like an unused instance (override with HINDSIGHT_DRILL_MIN_ROWS=0 for a genuinely fresh install)" >&2
    exit 1
  fi
  if [ "$banks_count" -gt 0 ] && [ "$memory_units_count" -eq 0 ]; then
    echo "ERROR: 'banks' has $banks_count bank(s) but 'memory_units' has 0 rows — looks like a truncated/incomplete dump" >&2
    exit 1
  fi

  if [ "$DRILL_FULL" = 1 ]; then
    say "Drill-full: booting a temporary hindsight against $DRILL_DB"
    PORT="${HINDSIGHT_DRILL_PORT:-18888}"
    api_key="${HINDSIGHT_API_TENANT_API_KEY:-}"
    [ -n "$api_key" ] || { echo "ERROR: HINDSIGHT_API_TENANT_API_KEY not set — needed to query bank counts" >&2; exit 1; }

    # Header goes to curl via a `-K -` config file read from stdin, never
    # as a `-H` argv token — argv is visible to every local user via
    # `ps`/`/proc/<pid>/cmdline`, stdin is not. Backslash/quote are escaped
    # because curl's config-file parser treats a bare `"`/`\` in the value
    # as syntax (would both break parsing and — if a specially-crafted key
    # ever managed to inject a second `header =` line — forge an extra
    # header), not because an API key is expected to contain them.
    bank_total() {  # bank_total <base-url>
      local esc_key
      esc_key=$(printf '%s' "$api_key" | sed 's/\\/\\\\/g; s/"/\\"/g')
      printf 'header = "Authorization: Bearer %s"\n' "$esc_key" \
        | curl -fsS --max-time 5 -K - "$1/v1/default/banks?limit=1" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])'
    }

    live_url="$("$HS" url)"
    live_total="$(bank_total "$live_url")" || { echo "ERROR: could not read bank count from the live instance ($live_url)" >&2; exit 1; }
    echo "    live bank count ($live_url): $live_total"

    # The drill DB's connection string (carries HINDSIGHT_DB_PASSWORD) is
    # exported as a real shell/process env var and referenced in `-e` by
    # NAME ONLY — `docker compose run -e NAME=value` would otherwise put
    # the password straight into this process's argv (visible via `ps`).
    export HINDSIGHT_API_DATABASE_URL="postgresql://${DB_USER}:${HINDSIGHT_DB_PASSWORD}@db:5432/${DRILL_DB}"
    DRILL_CID="$(docker compose -f "$CONFIG_DIR/compose.yaml" \
      --env-file "$CONFIG_DIR/version.env" --env-file "$CONFIG_DIR/base.env" --env-file "$CONFIG_DIR/secrets.env" \
      run --rm -d --no-deps -p "127.0.0.1:${PORT}:8888" \
      -e HINDSIGHT_API_DATABASE_URL \
      hindsight)"
    unset HINDSIGHT_API_DATABASE_URL

    drill_url="http://127.0.0.1:${PORT}"
    echo "    waiting for $drill_url/health"
    ok=0
    for _ in $(seq 1 30); do
      curl -fsS --max-time 3 "$drill_url/health" >/dev/null 2>&1 && { ok=1; break; }
      sleep 2
    done
    [ "$ok" = 1 ] || { echo "ERROR: drill-full container never became healthy — see: docker logs $DRILL_CID" >&2; exit 1; }

    drill_total="$(bank_total "$drill_url")" || { echo "ERROR: could not read bank count from the drill container" >&2; exit 1; }
    echo "    drill bank count ($drill_url): $drill_total"

    if [ "$drill_total" != "$live_total" ]; then
      echo "ERROR: bank count mismatch — live=$live_total drill=$drill_total" >&2
      echo "        (expected if banks were created after this dump was taken — re-run against a newer snapshot to confirm)" >&2
      exit 1
    fi
    echo "    bank counts match ($live_total)"
  fi

  exit 0
fi

# ---- 3. confirm -------------------------------------------------------------
echo
echo "About to REPLACE database '$DB_NAME' from: ${R2_KEY:-$LOCAL_PATH}"
if [ "$YES" != 1 ]; then
  ask "Continue?" || { echo "aborted (nothing changed)."; exit 1; }
fi

# ---- 4. ensure db is up (NOT the app) — bin/backup.sh needs a running db --
# A truly cold restore (fresh server, nothing ever started, or recovering
# after a crash with nothing up) would otherwise fail right here: `hs exec`
# into a stopped/nonexistent db container errors out before any backup is
# even attempted. `up -d db` is idempotent either way — a no-op if db is
# already running.
say "Ensuring db is up (hindsight itself is untouched for now)"
"$HS" up -d db
for _ in $(seq 1 30); do
  "$HS" exec -T db pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 && break
  sleep 1
done
"$HS" exec -T db pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 \
  || { echo "ERROR: db did not become ready" >&2; exit 1; }

# ---- 5. local backup first — must succeed, or the whole script aborts here -
say "Local backup (pre-restore) — required before touching anything"
backup_out="$("$CONFIG_DIR/bin/backup.sh" pre-restore)"
echo "$backup_out"
PRE_RESTORE_DUMP="$(env_get <(printf '%s\n' "$backup_out") BACKUP_PREFIX)-db.sql.gz"

# ---- 6. stop hindsight and verify it's actually stopped --------------------
say "Stopping hindsight"
"$HS" stop hindsight
running_services="$("$HS" ps --services --status running)"
if printf '%s\n' "$running_services" | grep -qx hindsight; then
  echo "ERROR: hindsight is still running after 'hs stop hindsight'" >&2
  exit 1
fi

# ---- 7. recreate the database -----------------------------------------------
say "Recreating database $DB_NAME"
"$HS" exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);" \
  -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

# ---- 8. restore --------------------------------------------------------------
# -1/--single-transaction only takes effect alongside -f (or -c) — hence
# `-f -` to read the script from stdin instead of relying on plain
# redirection, so a failure partway through rolls the whole restore back.
say "Restoring"
if gunzip -c "$TMP" | "$HS" exec -T db psql -v ON_ERROR_STOP=1 -1 -f - -U "$DB_USER" -d "$DB_NAME"; then
  rm -f "$TMP"
  if [ "$NO_START" = 1 ]; then
    echo "Restore OK. --no-start given: leaving hindsight stopped."
  else
    say "Starting hindsight"
    # `up -d` (create-if-missing + start), not `start` (which can only start
    # a container that already exists) — a truly cold restore (step 4
    # above) can run against a stack where hindsight's container was never
    # created at all, e.g. after `hs down` or on a fresh server; `start`
    # would silently do nothing in that case and `hs ready` would then
    # time out against nothing listening. `up -d` is a no-op either way
    # when the container already exists and is already running.
    "$HS" up -d hindsight
    "$HS" ready
  fi
else
  rm -f "$TMP"
  cat >&2 <<TXT

ERROR: restore failed — hindsight NOT restarted. The database is in a
partial/unknown state (the DROP DATABASE above already ran).

To retry, restore again from the pre-restore backup this run just made:
  bin/restore-db.sh $([ "$NO_START" = 1 ] && printf -- '--no-start ')$PRE_RESTORE_DUMP
TXT
  exit 1
fi
