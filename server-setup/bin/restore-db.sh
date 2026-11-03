#!/usr/bin/env bash
# Single source of truth for restoring the Hindsight Postgres database — a
# real restore (replaces the live DB) and a drill (throwaway DB, never
# touches the live DB or app) both go through this script, and both go
# through the SAME trial-import check before anything destructive: a dump
# that is gzip-valid SQL but fails to import, or imports but is missing
# core tables, must never reach the real database. The real-restore path
# runs that exact check into its own throwaway DB first — it is not
# "trust gzip -t and go".
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
#               assert core Hindsight tables exist and 'banks' has rows
#               (HINDSIGHT_DRILL_MIN_ROWS, default 1; others are
#               existence-only), then always drop it again — never touches
#               the real database or app.
# --drill-full  on top of --drill: also boot a temporary hindsight container
#               against the drill database on a spare 127.0.0.1 port, wait
#               for /health, and compare its bank count to the live instance's.
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/dump.sh"
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
TRIAL_DB=""
TRIAL_CREATED=0
DRILL_CID=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup_restore() {
  local status=$?
  if [ -n "$DRILL_CID" ]; then
    docker rm -f "$DRILL_CID" >/dev/null 2>&1 || echo "WARNING: could not remove drill-full container $DRILL_CID — remove it manually: docker rm -f $DRILL_CID" >&2
  fi
  if [ "$TRIAL_CREATED" = 1 ]; then
    if ! "$HS" exec -T db dropdb -U "$DB_USER" --if-exists "$TRIAL_DB"; then
      echo "ERROR: dropping $TRIAL_DB failed — drop it manually: hs exec -T db dropdb -U $DB_USER $TRIAL_DB" >&2
      status=1
    fi
  fi
  if ! rm -f "$TMP"; then
    echo "ERROR: removing temporary dump $TMP failed" >&2
    status=1
  fi
  if [ "$DRILL" = 1 ] && [ "$status" -eq 0 ]; then
    echo
    echo "Drill OK — $TRIAL_DB dropped."
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

say "Validating dump structure"
# gzip -t only proves the bytes are a valid gzip stream — a gzip-valid file
# full of plain-text garbage (not SQL at all) passes that and nothing else
# catches it before this. assert_valid_pg_dump (bin/lib/dump.sh) checks the
# exact pg_dump completion trailer instead of trusting the compression
# layer alone.
assert_valid_pg_dump "$TMP" \
  || { echo "ERROR: dump is not a complete pg_dump output (missing/mismatched completion trailer) — refusing to import it anywhere, including a trial." >&2; exit 1; }
echo "    ok: looks like a complete pg_dump"

# ---- core-table check shared by the drill path and the real path's own
# mandatory trial import (see trial_import_and_check below) -----------------
# Confirmed table names and schema: hindsight_api/models.py
# __tablename__ = banks/memory_units/entities/documents.
#
# Existence is checked unconditionally for all four — that catches a
# corrupt dump or a schema mismatch regardless of how much data is in it.
# This is the ONLY check applied to memory_units/entities/documents: all
# three are existence-only, never row-count gated, because every one of
# them can be legitimately empty on a perfectly healthy dump —
#   - memory_units: PUT /v1/default/banks/{id} creates a bank with zero
#     memories; PLAYBOOK.md documents this as expected, not broken.
#   - entities: Entity rows come from a separate extraction step over
#     memory_units' content (models.py: Entity.bank_id, UnitEntity join
#     table) — content that yields no identifiable named entities is
#     normal.
#   - documents: MemoryUnit.document_id is nullable with no NOT NULL
#     constraint tying every memory unit to a document row.
#
# 'banks' is the one exception, and the ONLY row-count gate in this check:
# HINDSIGHT_DRILL_MIN_ROWS (default 1) is the minimum number of banks a
# dump must have — the "does this look like a used instance" check. Set it
# to 0 for a genuinely fresh install that has never had a bank created;
# there is no other knob here, and no other table is ever compared
# against it. Applies identically whether this runs as part of --drill or
# as part of the real restore's own mandatory pre-flight check below.
check_core_tables() {  # check_core_tables <db-name>
  local db="$1" table count min_rows banks_count=0
  min_rows="${HINDSIGHT_DRILL_MIN_ROWS:-1}"
  for table in banks memory_units entities documents; do
    count="$("$HS" exec -T db psql -U "$DB_USER" -d "$db" -tAc "SELECT count(*) FROM $table;" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$count" ]; then
      echo "ERROR: table '$table' missing or unreadable in the restored dump" >&2
      return 1
    fi
    echo "    $table: $count rows"
    [ "$table" = banks ] && banks_count="$count"
  done
  if [ "$banks_count" -lt "$min_rows" ]; then
    echo "ERROR: 'banks' has $banks_count row(s) (< HINDSIGHT_DRILL_MIN_ROWS=$min_rows) — restored dump looks like an unused instance (set HINDSIGHT_DRILL_MIN_ROWS=0 for a genuinely fresh install)" >&2
    return 1
  fi
}

# Imports $TMP into a brand-new throwaway `restoretest_<ts>_<pid>` database
# and runs check_core_tables against it. Sets TRIAL_DB/TRIAL_CREATED (the
# EXIT trap above drops it on any exit, including an unexpected one) —
# callers that want it gone sooner than script-exit drop it explicitly
# themselves afterward. Never touches anything but its own throwaway db.
trial_import_and_check() {
  TRIAL_DB="restoretest_$(date +%s)_$$"
  say "Trial import -> $TRIAL_DB (throwaway, never the real database)"

  "$HS" exec -T db createdb -U "$DB_USER" "$TRIAL_DB" || return 1
  TRIAL_CREATED=1

  if ! gunzip -c "$TMP" | "$HS" exec -T db psql -v ON_ERROR_STOP=1 -1 -f - -U "$DB_USER" -d "$TRIAL_DB" -q; then
    echo "ERROR: trial import into $TRIAL_DB failed" >&2
    return 1
  fi

  say "Checking core tables"
  check_core_tables "$TRIAL_DB"
}

if [ "$DRILL" = 1 ]; then
  # ---- drill: restore into a throwaway DB; real DB/app untouched ---------
  trial_import_and_check || exit 1

  if [ "$DRILL_FULL" = 1 ]; then
    say "Drill-full: booting a temporary hindsight against $TRIAL_DB"
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
    export HINDSIGHT_API_DATABASE_URL="postgresql://${DB_USER}:${HINDSIGHT_DB_PASSWORD}@db:5432/${TRIAL_DB}"
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

# ---- 3. ensure db is up (NOT the app) — needed for the trial import below -
# A truly cold restore (fresh server, nothing ever started, or recovering
# after a crash with nothing up) would otherwise fail right here: `hs exec`
# into a stopped/nonexistent db container errors out before anything is
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

# ---- 4. mandatory trial import — before ANYTHING destructive --------------
# A gzip-valid, structurally-plausible dump can still be invalid SQL (or SQL
# that imports but is missing core tables) — the only way to know for sure
# is to actually import it. This runs the exact same check --drill does,
# into its own throwaway database, and the live database/app are not
# touched by any of the steps below (stop, backup, DROP DATABASE, restore)
# unless this succeeds.
if ! trial_import_and_check; then
  echo "ERROR: trial import failed — the live database and hindsight are untouched." >&2
  exit 1
fi
echo "Trial import OK — the live database and hindsight are still untouched; proceeding with the real restore."
if ! "$HS" exec -T db dropdb -U "$DB_USER" --if-exists "$TRIAL_DB"; then
  echo "WARNING: could not drop trial db $TRIAL_DB — drop it manually: hs exec -T db dropdb -U $DB_USER $TRIAL_DB" >&2
fi
TRIAL_CREATED=0

# ---- 5. confirm -------------------------------------------------------------
echo
echo "About to REPLACE database '$DB_NAME' from: ${R2_KEY:-$LOCAL_PATH}"
if [ "$YES" != 1 ]; then
  ask "Continue?" || { echo "aborted (nothing changed)."; exit 1; }
fi

# ---- 6. stop hindsight and verify it's actually stopped --------------------
# Stopped BEFORE the backup below, not after: backing up first would leave
# a window where a write lands after the dump but before the app actually
# stops — gone for good the moment the next step drops the database, and
# not in the "pre-restore" dump either. Stopping first makes that dump
# provably the exact final state, matching the same ordering bin/upgrade.sh
# uses for its own pre-upgrade backup.
say "Stopping hindsight"
"$HS" stop hindsight
running_services="$("$HS" ps --services --status running)"
if printf '%s\n' "$running_services" | grep -qx hindsight; then
  echo "ERROR: hindsight is still running after 'hs stop hindsight'" >&2
  exit 1
fi

# ---- 7. local backup — must succeed, or the whole script aborts here ------
say "Local backup (pre-restore) — required before touching anything"
backup_out="$("$CONFIG_DIR/bin/backup.sh" pre-restore)"
echo "$backup_out"
PRE_RESTORE_DUMP="$(env_get <(printf '%s\n' "$backup_out") BACKUP_PREFIX)-db.sql.gz"

# ---- 8. recreate the database -----------------------------------------------
say "Recreating database $DB_NAME"
"$HS" exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);" \
  -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

# ---- 9. restore --------------------------------------------------------------
# Already proven to import cleanly by the trial above — this should not
# fail, but the same careful handling (single transaction, no silent
# partial state) applies regardless.
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
    # a container that already exists) — a truly cold restore (step 3
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
partial/unknown state (the DROP DATABASE above already ran). This should
not happen given the trial import above already proved this exact dump
imports cleanly — investigate the db container itself (disk space, etc.)
before retrying.

To retry, restore again from the pre-restore backup this run just made:
  bin/restore-db.sh $([ "$NO_START" = 1 ] && printf -- '--no-start ')$PRE_RESTORE_DUMP
TXT
  exit 1
fi
