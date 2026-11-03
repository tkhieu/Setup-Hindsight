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
  ps)
    shift
    case "\$*" in
      # verify_on_version's image check: report whatever version.env
      # currently pins, same as a real running container would after a
      # real \`hs up -d\` against that env file.
      *--format*) echo "ghcr.io/vectorize-io/hindsight:\$(grep '^HINDSIGHT_VERSION=' "$TB/version.env" | cut -d= -f2)" ;;
      *) ;;  # --services --status running -> nothing running (stop verified)
    esac
    exit 0 ;;
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

# ============================================================================
# Scenario D: the rollback's OWN `sed -i` (reverting version.env to the old
# version) fails. Before this fix, do_auto_rollback ran that sed unchecked
# (inside an `if`, where set -e is suspended) and would go on to print
# "AUTO-ROLLBACK OK" / exit 2 even though version.env still pinned the new
# version. Must now exit 3 and never claim success. A fake `sed` on PATH
# fails only the revert-to-old-version invocation; the step-5 bump (to the
# NEW version) must still go through normally via the real sed.
# ============================================================================
TD="$(mktemp -d)"
setup_common "$TD"
mkdir -p "$TD/fakebin"

REAL_SED="$(command -v sed)"
cat > "$TD/fakebin/sed" <<EOF
#!/bin/sh
case "\$*" in
  *"HINDSIGHT_VERSION=1.1.0"*) echo "fake sed: simulated failure reverting version.env" >&2; exit 1 ;;
  *) exec "$REAL_SED" "\$@" ;;
esac
EOF
chmod +x "$TD/fakebin/sed"

HS_LOG_D="$TD/hs.log"
: > "$HS_LOG_D"

cat > "$TD/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_D"
case "\$1" in
  pull) exit 0 ;;
  stop) exit 0 ;;
  ps) exit 0 ;;
  exec)
    shift
    case "\$*" in
      *pg_dump*) cat "$TD/fixture.sql" ;;
    esac
    exit 0 ;;
  up) exit 1 ;;  # new version never comes up -> triggers rollback
  ready) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TD/bin/hs"

cd "$TD"
set +e
outD="$(PATH="$TD/fakebin:$TD/bin:$PATH" ./bin/upgrade.sh --yes --auto-rollback 1.1.1 </dev/null 2>&1)"
rcD=$?
set -e
cd "$HERE"

[ "$rcD" -eq 3 ] || { echo "$outD"; echo "FAIL: expected upgrade.sh to exit 3 when the rollback's own sed fails, got $rcD"; exit 1; }
printf '%s\n' "$outD" | grep -q "AUTO-ROLLBACK OK" && { echo "$outD"; echo "FAIL: must not claim 'AUTO-ROLLBACK OK' when reverting version.env failed"; exit 1; }
printf '%s\n' "$outD" | grep -qi "could not revert version.env" || { echo "$outD"; echo "FAIL: missing the version.env-revert-failed error"; exit 1; }
grep -q '^HINDSIGHT_VERSION=1.1.1$' "$TD/version.env" \
  || { echo "FAIL: expected version.env to still read the FAILED-to-revert new version 1.1.1:"; cat "$TD/version.env"; exit 1; }

rm -rf "$TD"
echo "ok - upgrade.sh --auto-rollback exits 3 when the rollback's own sed silently fails"

# ============================================================================
# Scenario E1: the image pull itself fails, INTERACTIVE mode (no flags at
# all). Pull happens BEFORE stop, so hindsight is still running, untouched
# — must behave EXACTLY as it always did before this script ever trapped
# the pull step: bare exit 1, no `hs up -d` call (nothing to restart), no
# verify, no extra "restarted"/"verified" noise.
# ============================================================================
TE1="$(mktemp -d)"
setup_common "$TE1"

HS_LOG_E1="$TE1/hs.log"
: > "$HS_LOG_E1"

cat > "$TE1/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_E1"
case "\$1" in
  pull) exit 1 ;;  # cold pull / network failure
  *) exit 0 ;;
esac
EOF
chmod +x "$TE1/bin/hs"

cd "$TE1"
set +e
# No --yes: must answer the interactive confirmation prompt (the pull
# itself comes right after it) — "y" so the run reaches and fails on pull.
outE1="$(printf 'y\n' | PATH="$TE1/bin:$PATH" ./bin/upgrade.sh 1.1.1 2>&1)"
rcE1=$?
set -e
cd "$HERE"

[ "$rcE1" -eq 1 ] || { echo "$outE1"; echo "FAIL: expected plain interactive upgrade.sh to exit 1 after a pull failure, got $rcE1"; exit 1; }
grep -q '^up\b\| up ' "$HS_LOG_E1" && { echo "FAIL: 'hs up' must never be called after an interactive pull failure (nothing was stopped):"; cat "$HS_LOG_E1"; exit 1; }
printf '%s\n' "$outE1" | grep -qi "verif\|restart" && { echo "$outE1"; echo "FAIL: plain interactive mode must not print verify/restart noise for a pull failure"; exit 1; }
grep -q '^HINDSIGHT_VERSION=1.1.0$' "$TE1/version.env" \
  || { echo "FAIL: version.env must be unchanged (still 1.1.0) after a pull failure:"; cat "$TE1/version.env"; exit 1; }

rm -rf "$TE1"
echo "ok - interactive (no flags) pull failure -> plain exit 1, no 'hs up -d', unchanged from before this script trapped the pull step"

# ============================================================================
# Scenario E2: same pull failure, but with --yes --auto-rollback (the
# bin/check-upstream.sh calling convention). Must exit 2 after VERIFYING
# hindsight is still fine on the unchanged CUR version — and still must
# NEVER call `hs up -d` (there is nothing to restart; the pull happens
# before hindsight is ever stopped).
# ============================================================================
TE2="$(mktemp -d)"
setup_common "$TE2"

HS_LOG_E2="$TE2/hs.log"
: > "$HS_LOG_E2"

cat > "$TE2/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_E2"
case "\$1" in
  pull) exit 1 ;;  # cold pull / network failure
  ps)
    shift
    case "\$*" in
      *--format*) echo "ghcr.io/vectorize-io/hindsight:\$(grep '^HINDSIGHT_VERSION=' "$TE2/version.env" | cut -d= -f2)" ;;
      *) ;;
    esac
    exit 0 ;;
  ready) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TE2/bin/hs"

cd "$TE2"
set +e
outE2="$(PATH="$TE2/bin:$PATH" ./bin/upgrade.sh --yes --auto-rollback 1.1.1 </dev/null 2>&1)"
rcE2=$?
set -e
cd "$HERE"

[ "$rcE2" -eq 2 ] || { echo "$outE2"; echo "FAIL: expected upgrade.sh to exit 2 after a pull failure in auto mode (verified, not restarted), got $rcE2"; exit 1; }
printf '%s\n' "$outE2" | grep -qi "verif" || { echo "$outE2"; echo "FAIL: missing a verify message"; exit 1; }
grep -q '^up\b\| up ' "$HS_LOG_E2" && { echo "FAIL: 'hs up' must never be called after a pull failure (nothing was ever stopped), got:"; cat "$HS_LOG_E2"; exit 1; }
grep -q '^HINDSIGHT_VERSION=1.1.0$' "$TE2/version.env" \
  || { echo "FAIL: version.env must be unchanged (still 1.1.0) after a pull failure:"; cat "$TE2/version.env"; exit 1; }

rm -rf "$TE2"
echo "ok - auto (--yes --auto-rollback) pull failure -> exit 2, verified only, never calls 'hs up -d'"

# ============================================================================
# Scenario F: the pre-upgrade backup fails AFTER hindsight was already
# stopped (fake `hs exec ... pg_dump` fails). Must restart hindsight on the
# unchanged CUR version, VERIFY it, and exit 2 — same contract as a pull
# failure, just one step later and with something to actually restart.
# ============================================================================
TF="$(mktemp -d)"
setup_common "$TF"

HS_LOG_F="$TF/hs.log"
: > "$HS_LOG_F"

cat > "$TF/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_F"
case "\$1" in
  pull) exit 0 ;;
  stop) exit 0 ;;
  ps)
    shift
    case "\$*" in
      *--format*) echo "ghcr.io/vectorize-io/hindsight:\$(grep '^HINDSIGHT_VERSION=' "$TF/version.env" | cut -d= -f2)" ;;
      *) ;;
    esac
    exit 0 ;;
  exec)
    shift
    case "\$*" in
      *pg_dump*) echo "fake pg_dump: connection to database failed" >&2; exit 1 ;;
    esac
    exit 0 ;;
  up) exit 0 ;;
  ready) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TF/bin/hs"

cd "$TF"
set +e
outF="$(PATH="$TF/bin:$PATH" ./bin/upgrade.sh --yes --auto-rollback 1.1.1 </dev/null 2>&1)"
rcF=$?
set -e
cd "$HERE"

[ "$rcF" -eq 2 ] || { echo "$outF"; echo "FAIL: expected upgrade.sh to exit 2 after a post-stop backup failure (restart verified), got $rcF"; exit 1; }
printf '%s\n' "$outF" | grep -qi "VERIFIED healthy" || { echo "$outF"; echo "FAIL: missing the verified-healthy restart message"; exit 1; }
grep -q '^HINDSIGHT_VERSION=1.1.0$' "$TF/version.env" \
  || { echo "FAIL: version.env must be unchanged (still 1.1.0) after a backup failure:"; cat "$TF/version.env"; exit 1; }
[ -z "$(find "$TF/backups" -maxdepth 1 -name '*-db.sql.gz' 2>/dev/null)" ] \
  || { echo "FAIL: no real dump should exist — pg_dump itself failed"; exit 1; }

rm -rf "$TF"
echo "ok - upgrade.sh exits 2 (restart verified) when the backup fails after hindsight was stopped"

# ============================================================================
# Scenario G: during auto-rollback, the rollback's OWN `hs up -d` call hangs
# (a fake that just sleeps) instead of failing outright. Must be bounded by
# $HINDSIGHT_HS_TIMEOUT (set tiny here so the test is fast), time out, and
# exit 3 — a hang in recovery must never just hang forever.
# ============================================================================
TG="$(mktemp -d)"
setup_common "$TG"

HS_LOG_G="$TG/hs.log"
UP_COUNT_G="$TG/.up_count"
: > "$HS_LOG_G"

cat > "$TG/bin/restore-db.sh" <<EOF
#!/bin/sh
exit 0
EOF
chmod +x "$TG/bin/restore-db.sh"

cat > "$TG/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_G"
case "\$1" in
  pull) exit 0 ;;
  stop) exit 0 ;;
  ps) exit 0 ;;
  exec)
    shift
    case "\$*" in
      *pg_dump*) cat "$TG/fixture.sql" ;;
    esac
    exit 0 ;;
  up)
    n=0
    [ -f "$UP_COUNT_G" ] && n="\$(cat "$UP_COUNT_G")"
    n=\$((n + 1))
    echo "\$n" > "$UP_COUNT_G"
    # First "up" (the new version) fails normally, triggering rollback.
    # Second "up" (the rollback's OWN restart) hangs instead of returning —
    # this is the one that must be caught by the outer \`timeout\`.
    [ "\$n" = 1 ] && exit 1
    sleep 30
    exit 0 ;;
  ready) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TG/bin/hs"

cd "$TG"
set +e
START_G="$(date +%s)"
outG="$(PATH="$TG/bin:$PATH" HINDSIGHT_HS_TIMEOUT=2 ./bin/upgrade.sh --yes --auto-rollback 1.1.1 </dev/null 2>&1)"
rcG=$?
END_G="$(date +%s)"
set -e
cd "$HERE"

[ "$rcG" -eq 3 ] || { echo "$outG"; echo "FAIL: expected upgrade.sh to exit 3 when the rollback's own 'hs up -d' hangs/times out, got $rcG"; exit 1; }
[ $((END_G - START_G)) -le 20 ] \
  || { echo "FAIL: upgrade.sh took $((END_G - START_G))s — the stalled 'hs up -d' was not bounded by HINDSIGHT_HS_TIMEOUT"; exit 1; }
printf '%s\n' "$outG" | grep -q "AUTO-ROLLBACK OK" && { echo "$outG"; echo "FAIL: must not claim 'AUTO-ROLLBACK OK' when 'hs up -d' hung"; exit 1; }

rm -rf "$TG"
echo "ok - a stalled 'hs up -d' during auto-rollback is bounded by \$HINDSIGHT_HS_TIMEOUT and exits 3"

# ============================================================================
# Scenario H: the INITIAL `hs stop hindsight` (step 3/7) itself hangs past
# $HINDSIGHT_HS_TIMEOUT, before version.env is ever bumped. STOPPED must be
# marked BEFORE this call is even attempted — an attempted stop counts as
# "touched" even if it times out, since docker may finish stopping it right
# after `timeout` gives up. Must go through the restart-and-verify path
# (calling `hs up -d`), NOT the "nothing touched" path (which never calls
# `hs up -d` at all) — and exit 2 once that restart is verified healthy.
# ============================================================================
TH="$(mktemp -d)"
setup_common "$TH"

HS_LOG_H="$TH/hs.log"
: > "$HS_LOG_H"

cat > "$TH/bin/hs" <<EOF
#!/bin/sh
echo "\$*" >> "$HS_LOG_H"
case "\$1" in
  pull) exit 0 ;;
  stop) sleep 30 ;;  # hangs well past HINDSIGHT_HS_TIMEOUT below
  ps)
    shift
    case "\$*" in
      *--format*) echo "ghcr.io/vectorize-io/hindsight:\$(grep '^HINDSIGHT_VERSION=' "$TH/version.env" | cut -d= -f2)" ;;
      *) ;;
    esac
    exit 0 ;;
  up) exit 0 ;;
  ready) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TH/bin/hs"

cd "$TH"
set +e
START_H="$(date +%s)"
outH="$(PATH="$TH/bin:$PATH" HINDSIGHT_HS_TIMEOUT=2 ./bin/upgrade.sh --yes --auto-rollback 1.1.1 </dev/null 2>&1)"
rcH=$?
END_H="$(date +%s)"
set -e
cd "$HERE"

[ "$rcH" -eq 2 ] || { echo "$outH"; echo "FAIL: expected upgrade.sh to exit 2 (restart attempted + verified) when the initial 'hs stop' itself hangs, got $rcH"; exit 1; }
[ $((END_H - START_H)) -le 20 ] \
  || { echo "FAIL: upgrade.sh took $((END_H - START_H))s — the stalled 'hs stop' was not bounded by HINDSIGHT_HS_TIMEOUT"; exit 1; }
grep -q '^up\b\| up ' "$HS_LOG_H" \
  || { echo "FAIL: 'hs up' must have been called (STOPPED=1 before the attempt means this goes through the restart path), got:"; cat "$HS_LOG_H"; exit 1; }
printf '%s\n' "$outH" | grep -qi "RECOVERY_KIND: restarted" \
  || { echo "$outH"; echo "FAIL: a timed-out stop must take the 'restarted' recovery path, not 'untouched'"; exit 1; }

rm -rf "$TH"
echo "ok - a stalled initial 'hs stop' is treated as touched (restart+verify attempted), not 'nothing touched'"
