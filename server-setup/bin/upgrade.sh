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
#                   and verify /health. Exit code distinguishes the outcome:
#                     2 = upgrade failed, but the rollback itself succeeded
#                         (hindsight is back on the OLD version and healthy)
#                     3 = the rollback ALSO failed (unknown/bad state —
#                         manual action needed now; see the log for exactly
#                         which rollback step failed and the pre-upgrade
#                         dump path)
#                   Without --auto-rollback, a failure after version.env was
#                   bumped keeps exiting 1 (unchanged) and only prints the
#                   rollback commands instead of running them.
# --smoke           after /health is ready, also run bin/smoke.sh. A smoke
#                   failure is treated the same as a failed /health wait
#                   (triggers --auto-rollback if given).
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

say "2/7 Pull target image ($NEW) before changing anything"
# Via shell env override (Compose gives shell env precedence over
# --env-file for interpolation), NOT version.env yet: a bad version or
# network failure here leaves the running stack and version.env untouched,
# so there is nothing to roll back and no trap is needed above this line.
HINDSIGHT_VERSION="$NEW" "$HS" pull hindsight

# From here on, stopping the app is itself a state change worth recovering
# from automatically — arm the trap NOW, before the stop below, not after
# the backup that follows it. A failure anywhere from here on (stop itself,
# the backup, or anything after) must not exit silently and leave hindsight
# down with no guidance. VERSION_BUMPED distinguishes the two recoveries
# the trap can give: before version.env is touched, the fix is just
# "start hindsight back up on $CUR" (nothing else changed); after, it's the
# full dump-restore rollback below.
FAILED=1
VERSION_BUMPED=0
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
# Runs the exact commands print_rollback above only prints, for --auto-rollback.
# Returns 0 if hindsight ends up back on $CUR and healthy, 1 if any step of
# the rollback itself failed (unknown/bad state) — on_exit below turns that
# into the distinct exit code 2 / 3 documented at the top of this file.
do_auto_rollback() {
  echo "AUTO-ROLLBACK: restoring $CUR from $PRE_DUMP" >&2
  if ! "$HS" stop hindsight; then
    echo "WARNING: 'hs stop hindsight' failed during auto-rollback — continuing anyway." >&2
  fi
  sed -i "s|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=$CUR|" "$CONFIG_DIR/version.env"
  if ! "$CONFIG_DIR/bin/restore-db.sh" --yes --no-start "$PRE_DUMP"; then
    echo "ERROR: auto-rollback's restore-db.sh failed — hindsight is left STOPPED. Manual intervention required; pre-upgrade dump: $PRE_DUMP" >&2
    return 1
  fi
  if ! "$HS" up -d; then
    echo "ERROR: auto-rollback could not start hindsight on $CUR — run manually: $HS up -d" >&2
    return 1
  fi
  if ! "$HS" ready; then
    echo "ERROR: hindsight on $CUR did not become ready after auto-rollback — check: $HS logs hindsight" >&2
    return 1
  fi
  echo "AUTO-ROLLBACK OK — hindsight is back on $CUR and healthy." >&2
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
  else
    echo >&2
    echo "Upgrade aborted before version.env changed — still at $CUR, nothing in the database to roll back." >&2
    echo "Restarting hindsight on $CUR..." >&2
    if "$HS" up -d; then
      echo "hindsight restarted on $CUR." >&2
    else
      echo "ERROR: could not restart hindsight automatically — run manually: $HS up -d" >&2
    fi
    exit "$status"
  fi
}
trap on_exit EXIT

say "3/7 Stopping hindsight (db stays up) so the backup below is final"
# Taking the backup BEFORE stopping (an earlier version of this script did
# this) leaves a window where writes after the dump but before the stack
# actually stops are lost if that dump is ever used for a rollback.
# Stopping first means the dump taken in the next step is provably the
# exact state the old version left behind — nothing written after it,
# nothing missing from it.
"$HS" stop hindsight
running_services="$("$HS" ps --services --status running)"
if printf '%s\n' "$running_services" | grep -qx hindsight; then
  echo "ERROR: hindsight is still running after 'hs stop hindsight' — aborting before touching anything else." >&2
  exit 1
fi

say "4/7 Final backup (the only rollback path — migrations are forward-only)"
backup_out="$("$CONFIG_DIR/bin/backup.sh" "pre-$NEW")"
echo "$backup_out"
PRE_DUMP="$(env_get <(printf '%s\n' "$backup_out") BACKUP_PREFIX)-db.sql.gz"
[ -f "$PRE_DUMP" ] || { echo "couldn't determine the pre-upgrade dump path — aborting before touching anything else." >&2; exit 1; }
echo "pre-upgrade dump (hindsight was already stopped when this was taken): $PRE_DUMP"

if [ -f "$CONFIG_DIR/secrets.env" ]; then
  say "4b/7 R2 6h snapshot of that same state (best-effort)"
  "$CONFIG_DIR/bin/backup-r2.sh" 6h || echo "R2 backup failed/skipped — the local backup above still covers rollback." >&2
else
  echo
  echo "no secrets.env — skipping R2 snapshot (local backup above still covers rollback)."
fi

say "5/7 Bump version.env"
sed -i "s|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=$NEW|" "$CONFIG_DIR/version.env"
grep -E '^HINDSIGHT_VERSION=' "$CONFIG_DIR/version.env"
VERSION_BUMPED=1

say "6/7 Up"
"$HS" up -d

say "7/7 Waiting for ready (up to 5 min)"
if ! HINDSIGHT_READY_TIMEOUT=300 "$HS" ready; then
  echo "NOT ready after 5 minutes. Check: hs logs hindsight" >&2
  exit 1
fi

if [ "$SMOKE" = 1 ]; then
  say "7b/7 Smoke test"
  if ! "$CONFIG_DIR/bin/smoke.sh"; then
    echo "Smoke test failed after upgrading to $NEW." >&2
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
