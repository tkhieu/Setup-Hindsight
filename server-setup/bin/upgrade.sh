#!/usr/bin/env bash
# Safe upgrade. Usage: bin/upgrade.sh [--yes] [--auto-rollback] [--smoke] 1.2.0
# (no leading "v" — matches version.env; see its comment on why the
# published image tag drops the "v" that the upstream git tag has)
#
# --yes            skip both confirmation prompts (the commit-diff pause and
#                   the final "continue?") and never read stdin. For
#                   scripted callers (bin/check-upstream.sh) — interactive
#                   behaviour is unchanged when this is omitted.
# --auto-rollback   on any failure AFTER version.env has been bumped, instead
#                   of just printing the rollback commands, run them: stop
#                   hindsight, revert version.env to the old version, restore
#                   the exact pre-upgrade dump via bin/restore-db.sh --yes
#                   --no-start, start hindsight back up on the old version
#                   and VERIFY it (version.env pin + the running container's
#                   own image tag + /health). A failure BEFORE version.env
#                   was bumped never needed a dump-restore rollback:
#                     - if hindsight was already stopped (the pre-upgrade
#                       backup itself failed), this restarts it on the
#                       unchanged old version and verifies the same way;
#                     - if hindsight was never even stopped (the image pull
#                       itself failed), there is nothing to restart — this
#                       only VERIFIES it is still fine, exactly as it was.
#                   Either way, exit code distinguishes the outcome:
#                     2 = upgrade failed, but hindsight is VERIFIED healthy
#                         on the OLD version afterward (a real auto-rollback,
#                         a restart, or just re-confirming nothing changed)
#                     3 = that verification FAILED (unknown/bad state —
#                         manual action needed now; see the log for exactly
#                         which step failed, and the pre-upgrade dump path
#                         if one was taken)
#                   Without --auto-rollback, a failure after version.env was
#                   bumped keeps exiting 1 (unchanged) and only prints the
#                   rollback commands instead of running them; a failure
#                   before that point behaves exactly as it always has
#                   (restart-if-stopped, or a bare exit 1 if the pull itself
#                   failed — no verification, no extra noise either way).
# --smoke           after /health is ready, also run bin/smoke.sh, bounded
#                   by $HINDSIGHT_SMOKE_TIMEOUT (default 600s). A smoke
#                   failure OR timeout is treated the same as a failed
#                   /health wait (triggers --auto-rollback if given).
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# server-setup/ is always one level under the repo root in this layout
# (confirmed: docs/, tests/, README.md, .gitignore all live next to
# server-setup/) — resolved for real here instead of assumed, so the git
# commands this script prints at the end work regardless of the operator's
# actual shell cwd (docs/PLAYBOOK.md has them working from ~/hindsight/server-setup).
REPO_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/lock.sh"
HS="$CONFIG_DIR/bin/hs"

# Generous but FINITE bounds on the steps below that can otherwise hang
# indefinitely while this script holds the shared ops lock (bin/lib/lock.sh)
# — hindsight-upgrade-check.service has TimeoutStartSec=infinity precisely
# because it trusts these, not systemd, to eventually give up. See
# docs/PLAYBOOK.md §8b.
PULL_TIMEOUT="${HINDSIGHT_PULL_TIMEOUT:-600}"       # cold docker image pull
BACKUP_TIMEOUT="${HINDSIGHT_BACKUP_TIMEOUT:-900}"   # bin/backup.sh / bin/backup-r2.sh
RESTORE_TIMEOUT="${HINDSIGHT_RESTORE_TIMEOUT:-900}" # bin/restore-db.sh, auto-rollback
HS_TIMEOUT="${HINDSIGHT_HS_TIMEOUT:-120}"           # hs stop/up -d/ps — normally near-instant
# Extra margin added ON TOP of $HS_TIMEOUT whenever wrapping `hs ready`: that
# subcommand already has its own internal retry budget (HINDSIGHT_READY_TIMEOUT,
# default 60s, governing the curl loop inside bin/hs) — this outer `timeout`
# exists only to catch a hang in something BEFORE that loop even starts (e.g.
# `docker compose port`, which `hs ready` calls first to resolve the URL).
# `timeout` kills the whole `hs ready` process tree the same way regardless
# of where it got stuck, so this only needs to be "bigger than the inner
# budget", not an exact match.
READY_OUTER_MARGIN="${HINDSIGHT_READY_OUTER_MARGIN:-30}"
# Whole bin/smoke.sh run (--smoke): create bank + LLM-backed retain + recall
# + cleanup. Its own curl calls carry --max-time 30 each, but `hs url`
# (docker compose port) does not, and the total is unbounded without this.
# A smoke timeout is a smoke FAILURE (-> auto-rollback path + ops-notify notification).
SMOKE_TIMEOUT="${HINDSIGHT_SMOKE_TIMEOUT:-600}"

YES=0
AUTO_ROLLBACK=0
SMOKE=0
NEW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --auto-rollback) AUTO_ROLLBACK=1 ;;
    --smoke) SMOKE=1 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) NEW="$1" ;;
  esac
  shift
done
[ -n "$NEW" ] || { echo "usage: upgrade.sh [--yes] [--auto-rollback] [--smoke] <target-version>, e.g. 1.2.0" >&2; exit 1; }

# Guards against a typo/garbage argument being embedded verbatim into sed
# below (this doubles as the rollback text).
[[ "$NEW" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "invalid version: $NEW" >&2; exit 1; }

# Before touching anything: serializes against backup/restore-drill/another
# upgrade, and is a no-op if a parent (bin/check-upstream.sh) already holds
# it — see bin/lib/lock.sh.
acquire_ops_lock "$CONFIG_DIR"

CUR="$(env_get "$CONFIG_DIR/version.env" HINDSIGHT_VERSION)"
[ -n "$CUR" ] || { echo "missing HINDSIGHT_VERSION in $CONFIG_DIR/version.env" >&2; exit 1; }

set -a
# shellcheck disable=SC1091
. "$CONFIG_DIR/base.env"
set +a

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ask() { read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }

[ "$CUR" != "$NEW" ] || { echo "already at $NEW."; exit 0; }

say "1/7 Changes $CUR -> $NEW"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh api "repos/vectorize-io/hindsight/compare/v$CUR...v$NEW" \
    --jq '.commits[] | .sha[0:7] + "  " + (.commit.message | split("\n")[0])' 2>/dev/null \
    || echo "(couldn't fetch the commit diff via gh — check https://github.com/vectorize-io/hindsight/releases manually)"
else
  echo "(gh not available/authenticated — check https://github.com/vectorize-io/hindsight/releases manually)"
fi

if [ "$YES" != 1 ]; then
  echo
  ask "Diff above OK — continue upgrading $CUR -> $NEW?" || { echo "aborted (nothing changed yet)."; exit 1; }
fi

# Arm the trap NOW, BEFORE the pull below — not after it. A pull failure
# leaves the running stack and version.env untouched, but with --auto-rollback
# it must still be verified-and-reported the same way any other failure is
# (this is exactly what makes "image pull failure -> exit 2" a meaningful,
# tested contract for bin/check-upstream.sh, instead of a bare untrapped
# `exit 1`). Without --auto-rollback (plain interactive use, no flags), a
# pull failure is reported identically to how it always was: nothing was
# touched, so on_exit just re-raises the original exit status — no `hs up
# -d`, no verify, no extra noise.
# VERSION_BUMPED distinguishes the two recoveries the trap can give: before
# version.env is touched, after it's the full dump-restore rollback below.
# STOPPED further splits the "before" case: if hindsight was never actually
# stopped (the pull itself failed), `hs up -d` is not just unnecessary, it's
# the wrong thing to run — there is nothing to restart, and running it
# anyway only adds a pointless docker call to a state that was never
# touched. Once the outcome IS checked, it's VERIFIED (version.env + the
# running container's own image tag + a real /health check), not just
# assumed from a command's exit status — see verify_on_version.
FAILED=1
VERSION_BUMPED=0
STOPPED=0
print_rollback() {
  cat >&2 <<TXT

ROLLBACK — run in this exact order (do not start $CUR before the database is
back to matching it: migrations run on startup and are not reversible, so
starting the old image against a database $NEW may already have migrated
would be exactly backwards):

  1. $CONFIG_DIR/bin/hs stop hindsight
  2. sed -i 's|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=$CUR|' $CONFIG_DIR/version.env
  3. $CONFIG_DIR/bin/restore-db.sh --yes --no-start $PRE_DUMP
  4. $CONFIG_DIR/bin/hs up -d
  5. $CONFIG_DIR/bin/hs ready

$PRE_DUMP is the exact state right before this upgrade's version switch —
hindsight was already stopped when it was taken, so nothing written after
it is lost by restoring it. Step 3 fetches nothing (it's already a local
path), verifies the dump, takes its own extra pre-restore backup, recreates
the database, and leaves hindsight stopped either way — it will say clearly
if the restore itself failed, in which case do not proceed to step 4.
TXT
}
# verify_on_version <expected-version> -- the ONLY source of truth for "is
# hindsight actually back on <expected-version> and healthy": version.env's
# pin, the RUNNING container's own image tag (`hs ps` — catches a sed that
# silently no-opped, or a container docker never actually recreated), and a
# real /health check. All three must agree; printing "OK" on the strength
# of a command merely exiting 0 is exactly how this used to lie.
verify_on_version() {
  local expected="$1" env_ver image ps_out ps_rc suffix
  env_ver="$(env_get "$CONFIG_DIR/version.env" HINDSIGHT_VERSION)"
  if [ "$env_ver" != "$expected" ]; then
    echo "ERROR: version.env pins '$env_ver', expected '$expected'." >&2
    return 1
  fi
  # The tag compose actually runs is version + image suffix (default
  # "-slim", empty = full image) — see image_suffix in bin/lib/env.sh.
  suffix="$(image_suffix "$CONFIG_DIR/version.env")"
  # Captured with its OWN exit status (not piped into tail inside a
  # conditional, where the pipeline status would be tail's): a timed-out or
  # failed `hs ps` FAILS verification even if it printed a matching image
  # line before dying — partial output from a command that did not finish
  # is not evidence.
  ps_rc=0
  ps_out="$(timeout "$HS_TIMEOUT" "$HS" ps --format '{{.Image}}' hindsight 2>/dev/null)" || ps_rc=$?
  if [ "$ps_rc" -ne 0 ]; then
    echo "ERROR: 'hs ps' failed (exit $ps_rc; 124 = exceeded ${HS_TIMEOUT}s) — cannot verify the running image." >&2
    return 1
  fi
  image="$(printf '%s\n' "$ps_out" | tail -n1)"
  case "$image" in
    *":${expected}${suffix}") ;;
    *)
      echo "ERROR: running hindsight container's image is '${image:-<none>}', expected a tag ending ':${expected}${suffix}'." >&2
      return 1
      ;;
  esac
  if ! timeout "$((HS_TIMEOUT + READY_OUTER_MARGIN))" "$HS" ready; then
    echo "ERROR: hindsight on $expected did not answer /health (or 'hs ready' itself hung)." >&2
    return 1
  fi
  return 0
}
# Runs the exact commands print_rollback above only prints, for --auto-rollback.
# Returns 0 ONLY if verify_on_version confirms hindsight ended up back on
# $CUR and healthy, 1 if any step (including that verification) failed —
# on_exit below turns that into the distinct exit code 2 / 3 documented at
# the top of this file. Every step is explicitly checked: this function
# only ever runs inside an `if`, where set -e is suspended for everything
# it calls, so an unchecked command failing here would be silently ignored.
do_auto_rollback() {
  echo "AUTO-ROLLBACK: restoring $CUR from $PRE_DUMP" >&2
  if ! timeout "$HS_TIMEOUT" "$HS" stop hindsight; then
    echo "WARNING: 'hs stop hindsight' failed (or exceeded ${HS_TIMEOUT}s) during auto-rollback — continuing anyway." >&2
  fi
  if ! sed -i "s|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=$CUR|" "$CONFIG_DIR/version.env"; then
    echo "ERROR: auto-rollback could not revert version.env to $CUR — hindsight is left STOPPED. Manual intervention required; pre-upgrade dump: $PRE_DUMP" >&2
    return 1
  fi
  if ! timeout "$RESTORE_TIMEOUT" "$CONFIG_DIR/bin/restore-db.sh" --yes --no-start "$PRE_DUMP"; then
    echo "ERROR: auto-rollback's restore-db.sh failed (or exceeded ${RESTORE_TIMEOUT}s) — hindsight is left STOPPED. Manual intervention required; pre-upgrade dump: $PRE_DUMP" >&2
    return 1
  fi
  if ! timeout "$HS_TIMEOUT" "$HS" up -d; then
    echo "ERROR: auto-rollback could not start hindsight on $CUR (command failed or exceeded ${HS_TIMEOUT}s) — run manually: $HS up -d" >&2
    return 1
  fi
  if ! verify_on_version "$CUR"; then
    echo "ERROR: auto-rollback brought hindsight up but could not VERIFY it is back on $CUR and healthy — manual intervention required; pre-upgrade dump: $PRE_DUMP" >&2
    return 1
  fi
  echo "AUTO-ROLLBACK OK — hindsight is back on $CUR and healthy (verified version.env + image + /health)." >&2
  return 0
}
on_exit() {
  local status=$?
  [ "$FAILED" = 1 ] || exit "$status"
  if [ "$VERSION_BUMPED" = 1 ]; then
    if [ "$AUTO_ROLLBACK" = 1 ]; then
      if do_auto_rollback; then
        exit 2
      else
        exit 3
      fi
    fi
    print_rollback
    exit "$status"
  elif [ "$STOPPED" = 1 ]; then
    # Hindsight WAS actually stopped (or a stop was at least attempted and
    # may have timed out mid-way — the backup step failed, `hs stop` itself
    # timed out, or it reported success but hindsight was somehow still
    # up) — unlike a pull failure below, there is something real to
    # restart here. RECOVERY_KIND is a machine-readable marker (not prose
    # that could get reworded) bin/check-upstream.sh greps for in the log
    # to pick the right notification title/body — never both "RECOVERY_KIND:" and
    # the other branch's marker will appear in the same run.
    echo "RECOVERY_KIND: restarted" >&2
    echo >&2
    echo "Upgrade aborted before version.env changed — still at $CUR, nothing in the database to roll back (no pre-upgrade dump exists yet either), but hindsight was stopped (or a stop was attempted)." >&2
    echo "Restarting hindsight on $CUR..." >&2
    if [ "$AUTO_ROLLBACK" = 1 ]; then
      if timeout "$HS_TIMEOUT" "$HS" up -d && verify_on_version "$CUR"; then
        echo "hindsight restarted on $CUR and VERIFIED healthy (version.env + image + /health)." >&2
        exit 2
      else
        echo "ERROR: could not VERIFY hindsight is back up and healthy on $CUR — run manually: $HS up -d; $HS ready; check: $HS logs hindsight" >&2
        exit 3
      fi
    else
      if timeout "$HS_TIMEOUT" "$HS" up -d; then
        echo "hindsight restarted on $CUR." >&2
      else
        echo "ERROR: could not restart hindsight automatically (command failed or exceeded ${HS_TIMEOUT}s) — run manually: $HS up -d" >&2
      fi
      exit "$status"
    fi
  else
    # Hindsight was NEVER stopped (the image pull itself failed) — it
    # should still be running untouched. Running `hs up -d` here would be
    # pointless at best (nothing to restart) and is simply the wrong
    # action for a state that was never touched, so this never calls it —
    # with --auto-rollback, only VERIFY that it's still fine; without any
    # flags, behave exactly as before this script ever had a trap for the
    # pull step: just re-raise the original exit status, no extra noise.
    if [ "$AUTO_ROLLBACK" = 1 ]; then
      echo "RECOVERY_KIND: untouched" >&2
      echo >&2
      echo "Upgrade aborted before anything was touched (e.g. the image pull failed) — verifying hindsight is still fine on $CUR, untouched..." >&2
      if verify_on_version "$CUR"; then
        echo "hindsight is still healthy on $CUR (verified, nothing was ever stopped or changed)." >&2
        exit 2
      else
        echo "ERROR: could not VERIFY hindsight is healthy on $CUR — check: $HS logs hindsight" >&2
        exit 3
      fi
    fi
    exit "$status"
  fi
}
trap on_exit EXIT

say "2/7 Pull target image ($NEW) before changing anything"
# Via shell env override (Compose gives shell env precedence over
# --env-file for interpolation), NOT version.env yet: a bad version or
# network failure here leaves the running stack and version.env untouched
# AND unstopped (STOPPED is still 0) — on_exit's VERSION_BUMPED=0 branch
# treats that as "nothing to restart", never calling `hs up -d`. Bounded
# by $PULL_TIMEOUT — a cold pull is already the single slowest step in
# this script and must not hang forever.
HINDSIGHT_VERSION="$NEW" timeout "$PULL_TIMEOUT" "$HS" pull hindsight

say "3/7 Stopping hindsight (db stays up) so the backup below is final"
# Taking the backup BEFORE stopping (an earlier version of this script did
# this) leaves a window where writes after the dump but before the stack
# actually stops are lost if that dump is ever used for a rollback.
# Stopping first means the dump taken in the next step is provably the
# exact state the old version left behind — nothing written after it,
# nothing missing from it.
# STOPPED is set BEFORE attempting the stop, not after it succeeds: an
# ATTEMPTED stop already counts as "touched" — if this command itself
# times out, docker may well finish stopping the container just after
# `timeout` kills this script's wait on it, leaving hindsight down. Setting
# STOPPED=1 only on success would then take on_exit's "nothing touched"
# branch (no restart, no `hs up -d`) and could report healthy without ever
# checking. Marking it touched up front means a stop timeout instead goes
# through the restart-and-verify path and only exits 2 if that verification
# actually passes.
STOPPED=1
timeout "$HS_TIMEOUT" "$HS" stop hindsight
running_services="$(timeout "$HS_TIMEOUT" "$HS" ps --services --status running)"
if printf '%s\n' "$running_services" | grep -qx hindsight; then
  echo "ERROR: hindsight is still running after 'hs stop hindsight' — aborting before touching anything else." >&2
  exit 1
fi

say "4/7 Final backup (the only rollback path — migrations are forward-only)"
backup_out="$(timeout "$BACKUP_TIMEOUT" "$CONFIG_DIR/bin/backup.sh" "pre-$NEW")"
echo "$backup_out"
PRE_DUMP="$(env_get <(printf '%s\n' "$backup_out") BACKUP_PREFIX)-db.sql.gz"
[ -f "$PRE_DUMP" ] || { echo "couldn't determine the pre-upgrade dump path — aborting before touching anything else." >&2; exit 1; }
echo "pre-upgrade dump (hindsight was already stopped when this was taken): $PRE_DUMP"

if [ -f "$CONFIG_DIR/secrets.env" ]; then
  say "4b/7 R2 6h snapshot of that same state (best-effort)"
  timeout "$BACKUP_TIMEOUT" "$CONFIG_DIR/bin/backup-r2.sh" 6h || echo "R2 backup failed/skipped (or exceeded ${BACKUP_TIMEOUT}s) — the local backup above still covers rollback." >&2
else
  echo
  echo "no secrets.env — skipping R2 snapshot (local backup above still covers rollback)."
fi

say "5/7 Bump version.env"
sed -i "s|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=$NEW|" "$CONFIG_DIR/version.env"
grep -E '^HINDSIGHT_VERSION=' "$CONFIG_DIR/version.env"
VERSION_BUMPED=1

say "6/7 Up"
timeout "$HS_TIMEOUT" "$HS" up -d

say "7/7 Waiting for ready (up to 5 min)"
if ! HINDSIGHT_READY_TIMEOUT=300 timeout "$((300 + READY_OUTER_MARGIN))" "$HS" ready; then
  echo "NOT ready after 5 minutes (or 'hs ready' itself hung). Check: hs logs hindsight" >&2
  exit 1
fi

if [ "$SMOKE" = 1 ]; then
  say "7b/7 Smoke test"
  # -k 30: if smoke.sh ignores the TERM (e.g. stuck in its cleanup trap),
  # KILL it 30s later — the timeout itself must be final. timeout signals
  # its whole process group, so smoke.sh's `hs url`/curl children go too.
  if ! timeout -k 30 "$SMOKE_TIMEOUT" "$CONFIG_DIR/bin/smoke.sh"; then
    echo "Smoke test failed (or exceeded ${SMOKE_TIMEOUT}s) after upgrading to $NEW." >&2
    exit 1
  fi
fi

FAILED=0
echo
echo "Upgraded $CUR -> $NEW."
echo
if [ "$YES" != 1 ]; then
  echo "Commit + push version.env (from any cwd — these use the resolved repo"
  echo "root, $REPO_ROOT, not a path relative to where you happen to be):"
  echo "  git -C \"$REPO_ROOT\" add server-setup/version.env"
  echo "  git -C \"$REPO_ROOT\" commit -m \"chore: bump hindsight to $NEW\""
  echo "  git -C \"$REPO_ROOT\" push"
fi
[ "$SMOKE" = 1 ] || echo "Smoke test: bin/smoke.sh"
echo
echo "Pre-upgrade dump kept at: $PRE_DUMP"
