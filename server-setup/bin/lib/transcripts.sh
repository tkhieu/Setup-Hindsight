# shellcheck shell=bash
# Map a coding-agent session id to the git repo it ran in, by reading the
# local harness transcript for that session. Used by bin/seed-repo-bank.sh
# to decide which conversation documents in the source bank belong to the
# repo being seeded.

# resolve_cwd_for_session <session_id> <claude_projects_dir> <codex_sessions_dir>
# -> prints the session's cwd and returns 0, or returns 1 if no local
# transcript for this session id can be found.
#
# Claude Code: the transcript file is named exactly "<session_id>.jsonl"
# under some per-project directory (the directory name itself is not used).
# Codex: the rollout file is named "rollout-<timestamp>-<session_id>.jsonl";
# its first line is a {"type":"session_meta","payload":{"id":...,"cwd":...}}
# record, checked against the session id again (not just the filename) before
# trusting its cwd.
resolve_cwd_for_session() {
  local session_id="$1" claude_dir="$2" codex_dir="$3" f cwd

  f="$(find "$claude_dir" -mindepth 2 -maxdepth 2 -type f -name "${session_id}.jsonl" -print -quit 2>/dev/null)"
  if [ -n "$f" ]; then
    # Each line of a Claude Code transcript is a standalone JSON object;
    # grep -m1 finds the first one that carries a "cwd" field without
    # reading a possibly large file in full.
    cwd="$(grep -m1 '"cwd":"' "$f" 2>/dev/null | python3 -I -c '
import sys, json
try:
    d = json.loads(sys.stdin.readline())
except Exception:
    sys.exit(0)
print(d.get("cwd") or "")
' 2>/dev/null)" || cwd=""
    if [ -n "$cwd" ]; then
      printf '%s\n' "$cwd"
      return 0
    fi
  fi

  f="$(find "$codex_dir" -mindepth 1 -maxdepth 4 -type f -name "rollout-*-${session_id}.jsonl" -print -quit 2>/dev/null)"
  if [ -n "$f" ]; then
    cwd="$(head -1 "$f" 2>/dev/null | python3 -I -c '
import sys, json
want = sys.argv[1]
try:
    d = json.loads(sys.stdin.readline())
except Exception:
    sys.exit(0)
payload = d.get("payload") or {}
if payload.get("id") == want:
    print(payload.get("cwd") or "")
' "$session_id" 2>/dev/null)" || cwd=""
    if [ -n "$cwd" ]; then
      printf '%s\n' "$cwd"
      return 0
    fi
  fi

  return 1
}

# repo_basename_for_cwd <cwd> -> prints the basename of the main worktree
# directory <cwd> belongs to and returns 0; returns 1 if <cwd> no longer
# exists on disk or isn't inside a git repo. `git rev-parse --git-common-dir`
# resolves a linked worktree back to the main repo's .git directory, so a
# session run from a worktree still maps to the main checkout's name.
repo_basename_for_cwd() {
  local cwd="$1" common_dir
  [ -d "$cwd" ] || return 1
  common_dir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common_dir" in
    /*) ;;
    *) common_dir="$cwd/$common_dir" ;;
  esac
  basename "$(dirname "$common_dir")"
}

# resolve_repo_for_session <session_id> <claude_projects_dir> <codex_sessions_dir>
# -> prints the repo basename and returns 0, or returns 1 if the session
# can't be mapped to a repo at all.
resolve_repo_for_session() {
  local session_id="$1" claude_dir="$2" codex_dir="$3" cwd
  cwd="$(resolve_cwd_for_session "$session_id" "$claude_dir" "$codex_dir")" || return 1
  repo_basename_for_cwd "$cwd"
}
