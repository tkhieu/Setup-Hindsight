#!/bin/sh
# bin/upgrade.sh's new flags (bin/check-upstream.sh's scripted-caller
# contract):
#   --yes            never reads stdin, even on the full success path.
#   --smoke          runs bin/smoke.sh after /health is ready.
#   --auto-rollback  on a failure AFTER version.env was bumped, runs the
#                    exact rollback commands (stop, revert version.env,
#                    bin/restore-db.sh --yes --no-start <pre-upgrade dump>,
#                    up, ready) instead of only printing them, and still
#                    exits non-zero.
# Interactive behaviour (no flags) is covered implicitly: every fake below
# only ever sees the flags this test passes, so a regression that started
# calling `ask`/reading stdin unconditionally would hang on `</dev/null`
# (read -r -p returns immediately with an empty answer -> "aborted", which
# the assertions below would catch as a wrong exit/output).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"

# A dump shaped enough to pass bin/lib/dump.sh's structural check (same
# fixture shape used by the restore-db.sh tests).
FIXTURE_SQL='--
-- PostgreSQL database dump
--

\restrict FAKEKEY00000000000000000000000000000000000000000000000000000

SET statement_timeout = 0;
SET client_encoding = '"'"'UTF8'"'"';

--
-- PostgreSQL database dump complete
--

\unrestrict FAKEKEY00000000000000000000000000000000000000000000000000000'

setup_common() {  # setup_common <dir>
  dir="$1"
  mkdir -p "$dir/bin/lib" "$dir/backups"
  cp "$SS/bin/upgrade.sh" "$dir/bin/upgrade.sh"
  cp "$SS/bin/backup.sh" "$dir/bin/backup.sh"
  cp "$SS/bin/lib/env.sh" "$dir/bin/lib/env.sh"
  cp "$SS/bin/lib/dump.sh" "$dir/bin/lib/dump.sh"
  cp "$SS/bin/lib/lock.sh" "$dir/bin/lib/lock.sh"
  chmod +x "$dir/bin/upgrade.sh" "$dir/bin/backup.sh"

  cat > "$dir/version.env" <<'EOF'
HINDSIGHT_VERSION=1.1.0
EOF
  cat > "$dir/base.env" <<'EOF'
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=hindsight_db
EOF
  # No secrets.env: upgrade.sh then skips the best-effort R2 snapshot
  # entirely (see its step 4b) — nothing R2-related needs faking here.

  printf '%s\n' "$FIXTURE_SQL" > "$dir/fixture.sql"
}

# ============================================================================
# Scenario A: full success with --yes --auto-rollback --smoke, stdin closed.
# Must never prompt (no "aborted" from a stdin-starved `ask`), must run
# smoke.sh, and must exit 0.
# ============================================================================
TA="$(mktemp -d)"
setup_common "$TA"

HS_LOG_A="$TA/hs.log"
SMOKE_LOG_A="$TA/smoke.log"
: > "$HS_LOG_A"
: > "$SMOKE_LOG_A"

cat > "$TA/bin/smoke.sh" <<EOF
#!/bin/sh
echo "smoke called with: \$*" >> "$SMOKE_LOG_A"
exit 0
EOF
chmod +x "$TA/bin/smoke.sh"

cat > "$TA/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_A"
case "\$1" in
  pull) exit 0 ;;
  stop) exit 0 ;;
  ps) exit 0 ;;  # no stdout -> "running_services" is empty -> stop verified
  exec)
    shift
    case "\$*" in
      *pg_dump*) cat "$TA/fixture.sql" ;;
    esac
    exit 0 ;;
  up) exit 0 ;;
  ready) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TA/bin/hs"

cd "$TA"
if ! outA="$(PATH="$TA/bin:$PATH" ./bin/upgrade.sh --yes --auto-rollback --smoke 1.1.1 </dev/null 2>&1)"; then
  echo "$outA"
  echo "FAIL: expected --yes --auto-rollback --smoke to succeed end to end"
  exit 1
fi
printf '%s\n' "$outA" | grep -qi "aborted" && { echo "$outA"; echo "FAIL: upgrade.sh prompted (saw 'aborted') despite --yes and a closed stdin"; exit 1; }
printf '%s\n' "$outA" | grep -q "Upgraded 1.1.0 -> 1.1.1" || { echo "$outA"; echo "FAIL: missing success line"; exit 1; }
[ -s "$SMOKE_LOG_A" ] || { echo "FAIL: --smoke was given but bin/smoke.sh was never called"; exit 1; }
grep -q '^HINDSIGHT_VERSION=1.1.1$' "$TA/version.env" || { echo "FAIL: version.env was not bumped"; exit 1; }
cd "$HERE"
rm -rf "$TA"
echo "ok - upgrade.sh --yes --auto-rollback --smoke succeeds without reading stdin"

# ============================================================================
# Scenario B: --auto-rollback on a failure AFTER version.env was bumped (the
# fake hs fails the FIRST `up -d` — i.e. the new version never comes up —
# then succeeds on the second `up`/`ready`, which is the rollback's own
# up+ready on the OLD version). Must call bin/restore-db.sh with exactly
# `--yes --no-start <the pre-upgrade dump just created>`, revert
# version.env back to the old version, and exit non-zero regardless of the
# rollback's own outcome.
# ============================================================================
TB="$(mktemp -d)"
setup_common "$TB"

HS_LOG_B="$TB/hs.log"
RESTORE_LOG_B="$TB/restore.log"
UP_COUNT_B="$TB/.up_count"
: > "$HS_LOG_B"
: > "$RESTORE_LOG_B"

cat > "$TB/bin/restore-db.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$RESTORE_LOG_B"
exit 0
EOF
chmod +x "$TB/bin/restore-db.sh"

cat > "$TB/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_B"
case "\$1" in
  pull) exit 0 ;;
  stop) exit 0 ;;
  ps) exit 0 ;;
  exec)
    shift
    case "\$*" in
      *pg_dump*) cat "$TB/fixture.sql" ;;
    esac
    exit 0 ;;
  up)
    n=0
    [ -f "$UP_COUNT_B" ] && n="\$(cat "$UP_COUNT_B")"
    n=\$((n + 1))
    echo "\$n" > "$UP_COUNT_B"
    # First "up" is the NEW version coming up -> fail it so VERSION_BUMPED=1
    # and FAILED=1 reach the trap. Every later "up" (the rollback's own) succeeds.
    [ "\$n" = 1 ] && exit 1
    exit 0 ;;
  ready) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TB/bin/hs"

cd "$TB"
set +e
outB="$(PATH="$TB/bin:$PATH" ./bin/upgrade.sh --yes --auto-rollback 1.1.1 </dev/null 2>&1)"
rcB=$?
set -e
cd "$HERE"

[ "$rcB" -eq 2 ] || { echo "$outB"; echo "FAIL: expected upgrade.sh to exit 2 (rollback succeeded) after the up -d failure, got $rcB"; exit 1; }
printf '%s\n' "$outB" | grep -q "AUTO-ROLLBACK OK" || { echo "$outB"; echo "FAIL: missing 'AUTO-ROLLBACK OK'"; exit 1; }

PRE_DUMP_B="$(find "$TB/backups" -maxdepth 1 -name '*-db.sql.gz' | head -1)"
[ -n "$PRE_DUMP_B" ] || { echo "FAIL: no pre-upgrade dump was created under $TB/backups"; exit 1; }

grep -qF -- "--yes --no-start $PRE_DUMP_B" "$RESTORE_LOG_B" \
  || { echo "FAIL: expected restore-db.sh called with '--yes --no-start $PRE_DUMP_B', got:"; cat "$RESTORE_LOG_B"; exit 1; }
grep -q '^HINDSIGHT_VERSION=1.1.0$' "$TB/version.env" \
  || { echo "FAIL: version.env was not reverted to the old version 1.1.0:"; cat "$TB/version.env"; exit 1; }

rm -rf "$TB"
echo "ok - upgrade.sh --auto-rollback restores the exact pre-upgrade dump and the old version"

# ============================================================================
# Scenario C: --auto-rollback where the rollback ITSELF fails (fake
# restore-db.sh exits non-zero). Must exit 3 (distinct from the exit-2
# "rollback succeeded" case) and must never claim "AUTO-ROLLBACK OK".
# ============================================================================
TC="$(mktemp -d)"
setup_common "$TC"

HS_LOG_C="$TC/hs.log"
: > "$HS_LOG_C"

cat > "$TC/bin/restore-db.sh" <<'EOF'
#!/bin/sh
echo "fake restore-db.sh: trial import failed" >&2
exit 1
EOF
chmod +x "$TC/bin/restore-db.sh"

cat > "$TC/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_C"
case "\$1" in
  pull) exit 0 ;;
  stop) exit 0 ;;
  ps) exit 0 ;;
  exec)
    shift
    case "\$*" in
      *pg_dump*) cat "$TC/fixture.sql" ;;
    esac
    exit 0 ;;
  up) exit 1 ;;  # new version never comes up -> triggers rollback
  ready) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TC/bin/hs"

cd "$TC"
set +e
outC="$(PATH="$TC/bin:$PATH" ./bin/upgrade.sh --yes --auto-rollback 1.1.1 </dev/null 2>&1)"
rcC=$?
set -e
cd "$HERE"

[ "$rcC" -eq 3 ] || { echo "$outC"; echo "FAIL: expected upgrade.sh to exit 3 when the rollback itself fails, got $rcC"; exit 1; }
printf '%s\n' "$outC" | grep -q "AUTO-ROLLBACK OK" && { echo "$outC"; echo "FAIL: must not claim 'AUTO-ROLLBACK OK' when restore-db.sh failed"; exit 1; }
printf '%s\n' "$outC" | grep -qi "restore-db.sh failed" || { echo "$outC"; echo "FAIL: missing the rollback-failed error"; exit 1; }

rm -rf "$TC"
echo "ok - upgrade.sh --auto-rollback exits 3 when the rollback itself fails"
