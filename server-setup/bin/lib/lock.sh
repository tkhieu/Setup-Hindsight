# shellcheck shell=bash
# Shared single-instance lock for every script that touches the Hindsight
# database or app state: bin/backup.sh, bin/backup-r2.sh, bin/restore-db.sh
# (including --drill), bin/upgrade.sh, bin/check-upstream.sh and
# bin/reembed.sh --yes. Acquiring
# it serializes all of them against each other — a backup can never start
# mid-restore, a restore can never start mid-upgrade, etc.
#
# Re-entrant across one process tree: bin/check-upstream.sh can run
# bin/upgrade.sh as a child, which can in turn run bin/backup.sh or (on
# --auto-rollback) bin/restore-db.sh as ITS child — all sharing the same
# lock file. Once a process acquires it, HINDSIGHT_OPS_LOCK_HELD=1 is
# exported, which every child process inherits; a descendant that sources
# this file sees the flag already set and returns immediately instead of
# trying to flock the same lock file again (which would otherwise either
# self-deadlock — the ancestor still holds its own fd open — or, with
# flock's single-process-reentrant semantics on some systems, silently do
# nothing useful either way). The lock is released when the outermost
# holder's fd 200 closes, i.e. when that top-level process exits — which
# is exactly when every synchronous descendant has already finished.
acquire_ops_lock() {  # acquire_ops_lock <config-dir>
  local config_dir="$1" timeout="${HINDSIGHT_OPS_LOCK_TIMEOUT:-3600}" lock_file
  [ -z "${HINDSIGHT_OPS_LOCK_HELD:-}" ] || return 0
  lock_file="$config_dir/.ops.lock"
  exec 200>"$lock_file"
  if ! flock -w "$timeout" 200; then
    echo "$(basename "$0"): could not acquire $lock_file within ${timeout}s — another backup/restore/upgrade/check-upstream run is in progress." >&2
    exit 1
  fi
  export HINDSIGHT_OPS_LOCK_HELD=1
}
