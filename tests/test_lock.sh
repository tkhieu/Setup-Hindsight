#!/bin/sh
# bin/lib/lock.sh (the shared server-setup/.ops.lock flock used by
# check-upstream/upgrade/backup/backup-r2/restore-db):
#   - contention: a second holder waiting on an already-locked lock file
#     times out (HINDSIGHT_OPS_LOCK_TIMEOUT), fails loud, exits non-zero —
#     and does so close to the timeout, not instantly and not forever.
#   - re-entrancy: a process that inherits HINDSIGHT_OPS_LOCK_HELD=1 (set by
#     an ancestor that already holds the lock) returns immediately WITHOUT
#     actually flock-ing again, even while another process genuinely holds
#     the real flock on the same file — proving it never tries to flock a
#     second time (which would otherwise self-deadlock or block until the
#     ancestor's timeout, not return instantly).
#
# All fd-200-style flock plumbing below runs inside explicit `bash -c`
# children (never the fd directly in this script) — this file's own
# shebang is /bin/sh, and a file descriptor above 9 is only guaranteed to
# work in bash, not in every POSIX sh (e.g. dash), which is what tests/run.sh
# actually invokes this file with.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOCK_FILE="$TMP/.ops.lock"

# ============================================================================
# Scenario A: contention. A holder process grabs the lock and sits on it;
# a second, independent process (HINDSIGHT_OPS_LOCK_HELD unset) must wait,
# then fail loud once HINDSIGHT_OPS_LOCK_TIMEOUT elapses — not hang forever.
# ============================================================================
HOLD_SECONDS=5
TIMEOUT_SECONDS=1

# Holder: a plain flock in the background (not acquire_ops_lock itself —
# this must be a genuinely separate process holding the lock independently
# of this test script, the same shape as a real backup.sh/restore-db.sh run).
bash -c "exec 200>'$LOCK_FILE'; flock 200; sleep $HOLD_SECONDS" &
HOLDER_PID=$!

# Readiness wait: poll flock -n against the same file from a throwaway fd
# until it reports busy (i.e. the background holder above actually has it),
# so the contender below doesn't race a holder that hasn't locked yet.
i=0
while [ "$i" -lt 100 ]; do
  if bash -c "exec 201>'$LOCK_FILE'; flock -n 201"; then
    i=$((i + 1))
    sleep 0.05
  else
    break
  fi
done

START="$(date +%s)"
set +e
out_a="$(
  cd "$TMP" && HINDSIGHT_OPS_LOCK_TIMEOUT="$TIMEOUT_SECONDS" bash -c "
    . '$SS/bin/lib/lock.sh'
    acquire_ops_lock '$TMP'
    echo UNEXPECTED_SUCCESS
  " 2>&1
)"
rc_a=$?
set -e
END="$(date +%s)"
elapsed=$((END - START))

wait "$HOLDER_PID" 2>/dev/null || true

[ "$rc_a" -ne 0 ] || { echo "$out_a"; echo "FAIL: expected a contended acquire to fail (holder still had the lock)"; exit 1; }
printf '%s\n' "$out_a" | grep -qi "could not acquire" \
  || { echo "$out_a"; echo "FAIL: expected a clear 'could not acquire' message, got:"; exit 1; }
printf '%s\n' "$out_a" | grep -q "UNEXPECTED_SUCCESS" \
  && { echo "FAIL: acquire_ops_lock returned success while the holder still held the lock"; exit 1; }
# Bounded wait: must not return instantly (it genuinely waited ~TIMEOUT_SECONDS)
# and must not hang well past it either (flock -w actually bounds it).
[ "$elapsed" -ge "$TIMEOUT_SECONDS" ] \
  || { echo "FAIL: contended acquire returned in ${elapsed}s, before its own ${TIMEOUT_SECONDS}s timeout"; exit 1; }
[ "$elapsed" -le $((TIMEOUT_SECONDS + 5)) ] \
  || { echo "FAIL: contended acquire took ${elapsed}s — flock -w did not bound the wait"; exit 1; }

echo "ok - contended acquire_ops_lock waits up to HINDSIGHT_OPS_LOCK_TIMEOUT then fails loud"

# ============================================================================
# Scenario B: re-entrancy. With the SAME lock file still held by a holder
# (new one, since scenario A's already exited), a process that already has
# HINDSIGHT_OPS_LOCK_HELD=1 exported (as a child of the process that first
# acquired it would) must return immediately — it must never call flock
# again, so it is NOT blocked by the unrelated holder and does not wait out
# any timeout at all.
# ============================================================================
bash -c "exec 200>'$LOCK_FILE'; flock 200; sleep $HOLD_SECONDS" &
HOLDER_PID_B=$!

i=0
while [ "$i" -lt 100 ]; do
  if bash -c "exec 201>'$LOCK_FILE'; flock -n 201"; then
    i=$((i + 1))
    sleep 0.05
  else
    break
  fi
done

START_B="$(date +%s)"
set +e
out_b="$(
  cd "$TMP" && HINDSIGHT_OPS_LOCK_HELD=1 HINDSIGHT_OPS_LOCK_TIMEOUT=3600 bash -c "
    . '$SS/bin/lib/lock.sh'
    acquire_ops_lock '$TMP'
    echo REENTRANT_OK
  " 2>&1
)"
rc_b=$?
set -e
END_B="$(date +%s)"
elapsed_b=$((END_B - START_B))

kill "$HOLDER_PID_B" 2>/dev/null || true
wait "$HOLDER_PID_B" 2>/dev/null || true

[ "$rc_b" -eq 0 ] || { echo "$out_b"; echo "FAIL: expected a re-entrant acquire (HINDSIGHT_OPS_LOCK_HELD=1) to succeed"; exit 1; }
printf '%s\n' "$out_b" | grep -q "REENTRANT_OK" \
  || { echo "$out_b"; echo "FAIL: re-entrant acquire did not reach past acquire_ops_lock"; exit 1; }
[ "$elapsed_b" -le 2 ] \
  || { echo "FAIL: re-entrant acquire took ${elapsed_b}s — it must return instantly, never flock again"; exit 1; }

echo "ok - acquire_ops_lock is re-entrant (HINDSIGHT_OPS_LOCK_HELD=1 skips flock, returns instantly)"
