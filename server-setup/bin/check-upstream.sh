#!/usr/bin/env bash
# Weekly check for a new Hindsight upstream release (vectorize-io/hindsight).
# PATCH bumps (same MAJOR.MINOR, higher PATCH, e.g. 1.1.0 -> 1.1.1) are
# upgraded AUTOMATICALLY via `bin/upgrade.sh --yes --auto-rollback --smoke`;
# MINOR/MAJOR bumps are never applied automatically, only reported. All
# notifications go to a GitHub issue on tkhieu/Setup-Hindsight, labeled
# `hindsight-upgrade`, deduped by exact title so this never spams. See
# docs/PLAYBOOK.md §8b for what each outcome/issue means and how to read it.
#
# Usage: bin/check-upstream.sh [--dry-run]
#   --dry-run   does the network reads (latest-release lookup, GHCR tag
#               check) but performs no upgrade, no git commit/push, and
#               opens no issue — prints what it would have done instead.
set -euo pipefail

# python3 is REQUIRED (all JSON parsing/encoding below goes through it, no
# sed/awk fallback — a real parser is the only safe way to scan a JSON
# array or build a JSON string literal). Confirmed present on the server;
# fail loud immediately instead of a confusing failure deep inside json.sh.
command -v python3 >/dev/null 2>&1 \
  || { echo "ERROR: python3 is required (JSON parsing against the GitHub/GHCR APIs) but was not found on PATH." >&2; exit 1; }

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
REPO_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/json.sh"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/lock.sh"

UPSTREAM_REPO="vectorize-io/hindsight"
ISSUE_REPO="tkhieu/Setup-Hindsight"
LABEL="hindsight-upgrade"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: check-upstream.sh [--dry-run]" >&2; exit 1 ;;
esac

say() { printf '\n==> %s\n' "$*"; }

# ---- shared lock --------------------------------------------------------
# Same lock as backup/backup-r2/restore-db/upgrade (bin/lib/lock.sh) — a
# full patch run below can take as long as bin/upgrade.sh itself (pull +
# stop + backup + up + wait-ready + smoke, or an auto-rollback on top of
# that), so this must never overlap any of them. Skipped entirely in
# --dry-run: it only does read-only network calls, never mutates anything,
# and must not even create the lock file (see its own usage comment above).
[ "$DRY_RUN" = 1 ] || acquire_ops_lock "$CONFIG_DIR"

set -a
# shellcheck disable=SC1091
. "$CONFIG_DIR/base.env"
# shellcheck disable=SC1091
[ -f "$CONFIG_DIR/secrets.env" ] && . "$CONFIG_DIR/secrets.env"
set +a

TOKEN="${GITHUB_ISSUE_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  echo "WARNING: GITHUB_ISSUE_TOKEN not set in secrets.env — issue notifications are disabled; would-be issues are only logged below. This does NOT block the patch auto-upgrade path itself (docs/PLAYBOOK.md §8b)." >&2
fi

# ---- GitHub REST API ---------------------------------------------------
# Token (when set) goes to curl via `-K -` on stdin, never argv — same
# convention as bin/smoke.sh / bin/restore-db.sh --drill-full.
GH_API_STATUS=""
GH_API_BODY=""
gh_api() {  # gh_api <method> <path> [body-file]
  local method="$1" path="$2" bodyfile="${3:-}" cfg out
  cfg='header = "Accept: application/vnd.github+json"
header = "X-GitHub-Api-Version: 2022-11-28"'
  if [ -n "$TOKEN" ]; then
    local esc
    esc=$(printf '%s' "$TOKEN" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cfg="$cfg
header = \"Authorization: Bearer $esc\""
  fi
  if [ -n "$bodyfile" ]; then
    out="$(printf '%s\n' "$cfg" | curl -sS --max-time 30 -w '\n%{http_code}' -K - \
      -X "$method" -H 'Content-Type: application/json' --data-binary "@$bodyfile" \
      "https://api.github.com$path")"
  else
    out="$(printf '%s\n' "$cfg" | curl -sS --max-time 30 -w '\n%{http_code}' -K - \
      -X "$method" "https://api.github.com$path")"
  fi
  GH_API_STATUS="${out##*$'\n'}"
  GH_API_BODY="${out%$'\n'*}"
}

# ---- GHCR anonymous tag check ------------------------------------------
# Token endpoint first (anonymous pull-scope token, short-lived, not a
# repo secret — still routed via -K - for consistency), then HEAD-style
# manifest check (-o /dev/null, we only care about the status code).
ghcr_tag_exists() {  # ghcr_tag_exists <bare-version, e.g. 1.2.1>
  local token status
  token="$(curl -fsS --max-time 15 \
    "https://ghcr.io/token?scope=repository:vectorize-io/hindsight:pull" | json_str token)"
  [ -n "$token" ] || return 1
  status="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json"\n' "$token" \
    | curl -s --max-time 15 -o /dev/null -w '%{http_code}' -K - \
      "https://ghcr.io/v2/vectorize-io/hindsight/manifests/$1")"
  [ "$status" = 200 ]
}

# ---- semver compare (plain X.Y.Z only — prerelease tags are filtered out
# before this is ever called) ---------------------------------------------
semver_compare() {  # semver_compare <cur> <new> -> prints: equal|patch|minor|major|older
  local cur="$1" new="$2" c_major c_minor c_patch n_major n_minor n_patch
  IFS=. read -r c_major c_minor c_patch <<<"$cur"
  IFS=. read -r n_major n_minor n_patch <<<"$new"
  if [ "$n_major" -gt "$c_major" ]; then echo major; return; fi
  if [ "$n_major" -lt "$c_major" ]; then echo older; return; fi
  if [ "$n_minor" -gt "$c_minor" ]; then echo minor; return; fi
  if [ "$n_minor" -lt "$c_minor" ]; then echo older; return; fi
  if [ "$n_patch" -gt "$c_patch" ]; then echo patch; return; fi
  if [ "$n_patch" -lt "$c_patch" ]; then echo older; return; fi
  echo equal
}

# ---- repo safety gate for the patch auto-upgrade path -------------------
git_ready_for_autoupgrade() {
  local branch local_sha remote_sha
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    echo "repo working tree is dirty ($REPO_ROOT)" >&2
    return 1
  fi
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  if [ "$branch" != main ]; then
    echo "not on branch main (currently on '$branch')" >&2
    return 1
  fi
  if ! git -C "$REPO_ROOT" fetch --quiet origin main; then
    echo "git fetch origin main failed" >&2
    return 1
  fi
  local_sha="$(git -C "$REPO_ROOT" rev-parse main)"
  remote_sha="$(git -C "$REPO_ROOT" rev-parse origin/main)"
  if [ "$local_sha" != "$remote_sha" ]; then
    echo "local main ($local_sha) is not fast-forwardable onto origin/main ($remote_sha)" >&2
    return 1
  fi
}

# ---- best-effort secret redaction for a log tail posted to an issue -----
redact_log() {  # redact_log <file>
  local f="$1" v script=""
  for v in "${HINDSIGHT_DB_PASSWORD:-}" "${HINDSIGHT_API_TENANT_API_KEY:-}" "${HINDSIGHT_CP_ACCESS_KEY:-}" \
           "${HINDSIGHT_API_LLM_API_KEY:-}" "${RCLONE_CONFIG_R2_ACCESS_KEY_ID:-}" \
           "${RCLONE_CONFIG_R2_SECRET_ACCESS_KEY:-}" "${TOKEN:-}"; do
    [ -n "$v" ] || continue
    script="${script}s/$(printf '%s' "$v" | sed -e 's/[.[\^$*/\\]/\\&/g')/[REDACTED]/g;"
  done
  if [ -n "$script" ]; then sed "$script" "$f"; else cat "$f"; fi
}

# ---- issue dedupe + creation --------------------------------------------
# Every API error here (label create other than "already exists", issue
# listing, issue creation) is a hard failure: returns 1, and callers must
# propagate that as a non-zero exit — never silently continue, and never
# create an issue after a failed dedupe lookup (that lookup is the only
# thing standing between this and spamming a duplicate).
ensure_label() {  # returns 0 if the label exists (created now or already), 1 on any other API error
  local bodyfile
  bodyfile="$(mktemp)"
  json_label_payload "$LABEL" "5319e7" "Opened/updated by bin/check-upstream.sh" > "$bodyfile"
  gh_api POST "/repos/$ISSUE_REPO/labels" "$bodyfile"
  rm -f "$bodyfile"
  case "$GH_API_STATUS" in
    201 | 422) return 0 ;; # 422 = label already exists
    *) echo "ERROR: could not ensure label '$LABEL' exists (HTTP $GH_API_STATUS): $GH_API_BODY" >&2; return 1 ;;
  esac
}

# find_issue_by_title <title> -> echoes the issue number if a match is
# found (any state — open OR closed, so a previously-closed notification
# is never recreated either), prints nothing if genuinely not found,
# returns 1 only on an actual API error. Paginates (per_page=100) until a
# page comes back with 0 items.
find_issue_by_title() {
  local title="$1" page=1 len num
  while :; do
    gh_api GET "/repos/$ISSUE_REPO/issues?state=all&labels=$LABEL&per_page=100&page=$page"
    if [ "$GH_API_STATUS" != 200 ]; then
      echo "ERROR: listing '$LABEL' issues (page $page) failed (HTTP $GH_API_STATUS): $GH_API_BODY" >&2
      return 1
    fi
    len="$(printf '%s' "$GH_API_BODY" | json_array_len)"
    [ "$len" -gt 0 ] || break
    num="$(printf '%s' "$GH_API_BODY" | json_array_find_number title "$title")"
    if [ -n "$num" ]; then
      printf '%s\n' "$num"
      return 0
    fi
    [ "$len" -eq 100 ] || break
    page=$((page + 1))
  done
}

open_or_dedupe_issue() {  # open_or_dedupe_issue <title> <body> -- 0 if ensured (existing or created), 1 on any API error
  local title="$1" body="$2" existing bodyfile
  if [ -z "$TOKEN" ]; then
    echo "NOTE: GITHUB_ISSUE_TOKEN not set — would open/ensure issue titled: $title" >&2
    printf '%s\n' "$body" >&2
    return 0
  fi
  ensure_label || return 1
  existing="$(find_issue_by_title "$title")" || return 1
  if [ -n "$existing" ]; then
    echo "issue #$existing already exists (any state) with this exact title — not creating a duplicate: $title"
    return 0
  fi
  bodyfile="$(mktemp)"
  json_issue_payload "$title" "$body" "$LABEL" > "$bodyfile"
  gh_api POST "/repos/$ISSUE_REPO/issues" "$bodyfile"
  rm -f "$bodyfile"
  if [ "$GH_API_STATUS" = 201 ]; then
    echo "opened issue: $title"
    return 0
  fi
  echo "ERROR: creating issue failed (HTTP $GH_API_STATUS): $title" >&2
  echo "$GH_API_BODY" >&2
  return 1
}

# ============================================================================
# main
# ============================================================================

CUR="$(env_get "$CONFIG_DIR/version.env" HINDSIGHT_VERSION)"
[ -n "$CUR" ] || { echo "ERROR: missing HINDSIGHT_VERSION in $CONFIG_DIR/version.env" >&2; exit 1; }

say "Fetching latest stable release: $UPSTREAM_REPO"
gh_api GET "/repos/$UPSTREAM_REPO/releases/latest"
case "$GH_API_STATUS" in
  200) ;;
  403) echo "ERROR: GitHub API rate-limited (403) fetching $UPSTREAM_REPO release info." >&2; exit 1 ;;
  5*) echo "ERROR: GitHub API returned $GH_API_STATUS fetching $UPSTREAM_REPO release info." >&2; exit 1 ;;
  *)
    echo "ERROR: GitHub API returned unexpected HTTP $GH_API_STATUS fetching $UPSTREAM_REPO release info:" >&2
    echo "$GH_API_BODY" >&2
    exit 1
    ;;
esac
REL_JSON="$GH_API_BODY"

tag="$(printf '%s' "$REL_JSON" | json_str tag_name)"
[ -n "$tag" ] || { echo "ERROR: release response had no tag_name:" >&2; echo "$REL_JSON" >&2; exit 1; }

# /releases/latest already excludes draft/prerelease releases server-side —
# this is a defensive re-check, not the primary filter.
draft="$(printf '%s' "$REL_JSON" | json_bool draft)"
prerelease="$(printf '%s' "$REL_JSON" | json_bool prerelease)"
if [ "$draft" = true ] || [ "$prerelease" = true ]; then
  echo "latest release $tag is marked draft/prerelease — ignoring."
  exit 0
fi

ver="${tag#v}"
if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "latest release tag '$tag' is not a plain vX.Y.Z (prerelease suffix or non-standard tag) — ignoring."
  exit 0
fi

cmp="$(semver_compare "$CUR" "$ver")"
case "$cmp" in
  equal | older)
    echo "up to date (current $CUR, latest stable release $tag)."
    exit 0
    ;;
esac

say "Confirming GHCR image tag exists: ghcr.io/vectorize-io/hindsight:$ver"
if ! ghcr_tag_exists "$ver"; then
  echo "ERROR: ghcr.io/vectorize-io/hindsight:$ver not found via the anonymous pull token — not upgrading or reporting yet (image probably still publishing after the GitHub release)." >&2
  exit 1
fi
echo "    ok"

html_url="$(printf '%s' "$REL_JSON" | json_str html_url)"
notes="$(printf '%s' "$REL_JSON" | json_str body)"
notes_excerpt="$(printf '%s' "$notes" | head -c 1500)"
[ "${#notes}" -gt 1500 ] && notes_excerpt="$notes_excerpt...(truncated, see $html_url)"

if [ "$cmp" = patch ]; then
  say "Patch available: $CUR -> $ver"

  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] would run: bin/upgrade.sh --yes --auto-rollback --smoke $ver"
    echo "[dry-run] on success: commit+push server-setup/version.env, open issue 'Hindsight auto-upgraded to $ver'"
    echo "[dry-run] on failure: open issue 'Hindsight auto-upgrade to $ver failed (rolled back)'"
    exit 0
  fi

  if ! git_ready_for_autoupgrade; then
    body="Patch release $ver is available (current: $CUR), but auto-upgrade was skipped because the repo at $REPO_ROOT is not in a state it is safe to auto-commit/push to (dirty working tree, not on main, or main is not fast-forwardable onto origin/main — see journalctl --user -u hindsight-upgrade-check for the exact reason).

Release: $html_url

Manual upgrade (after fixing the repo state above), run on the server from server-setup/:
  bin/upgrade.sh $ver"
    open_or_dedupe_issue "Hindsight $ver available but auto-upgrade blocked (repo not clean)" "$body" || true
    exit 1
  fi

  LOG="$(mktemp)"
  set +e
  "$CONFIG_DIR/bin/upgrade.sh" --yes --auto-rollback --smoke "$ver" >"$LOG" 2>&1
  upgrade_rc=$?
  set -e

  case "$upgrade_rc" in
    0)
      cat "$LOG"
      say "Committing + pushing version.env"
      push_ok=1
      git -C "$REPO_ROOT" add server-setup/version.env || push_ok=0
      if [ "$push_ok" = 1 ]; then
        git -C "$REPO_ROOT" commit -m "chore: bump Hindsight to $ver" || push_ok=0
      fi
      if [ "$push_ok" = 1 ]; then
        git -C "$REPO_ROOT" push origin main || push_ok=0
      fi

      if [ "$push_ok" = 1 ]; then
        body="Hindsight was automatically upgraded from $CUR to $ver (patch release) and the smoke test passed.

Release: $html_url

$notes_excerpt"
        rm -f "$LOG"
        if open_or_dedupe_issue "Hindsight auto-upgraded to $ver" "$body"; then exit 0; else exit 1; fi
      else
        # Upgrade itself is healthy and running $ver — only the repo update
        # failed. Nothing to roll back; this is a git problem, not a
        # hindsight problem, so bin/upgrade.sh's own rollback is never
        # involved here.
        echo "ERROR: commit/push of version.env failed after a successful upgrade to $ver — hindsight is healthy on $ver, but the repo on the server was not updated." >&2
        body="Hindsight was upgraded to $ver and passed its smoke test — it is healthy and running $ver right now. Committing/pushing version.env on the server afterward FAILED, so the repo still shows $CUR. Nothing needs to be rolled back.

Fix manually on the server:
  cd $REPO_ROOT
  git status
  git add server-setup/version.env
  git commit -m \"chore: bump Hindsight to $ver\"
  git push origin main

Release: $html_url"
        rm -f "$LOG"
        open_or_dedupe_issue "Hindsight auto-upgraded to $ver but version.env push failed" "$body" || true
        exit 1
      fi
      ;;
    2)
      # upgrade.sh --auto-rollback: upgrade failed, but the rollback itself
      # succeeded — hindsight is back on $CUR and healthy.
      echo "upgrade.sh failed but auto-rollback succeeded (back on $CUR) — see the log tail in the issue being opened now." >&2
      body="Automatic upgrade of Hindsight $CUR -> $ver FAILED and was automatically rolled back to $CUR by bin/upgrade.sh --auto-rollback — hindsight is back on $CUR and healthy. version.env was NOT changed; nothing was committed or pushed.

Release: $html_url

--- log tail (secrets redacted) ---
$(redact_log "$LOG" | tail -n 100)"
      rm -f "$LOG"
      open_or_dedupe_issue "Hindsight auto-upgrade to $ver failed (rolled back)" "$body" || true
      exit 1
      ;;
    *)
      # Anything else (3 = the rollback ITSELF failed, or any unexpected
      # code) is treated as the worst case on purpose: hindsight's actual
      # state is unknown/bad and needs a human NOW.
      pre_dump="$(grep -o 'pre-upgrade dump.*: .*' "$LOG" | tail -1 | sed 's/.*: //')"
      echo "upgrade.sh failed AND auto-rollback failed (exit $upgrade_rc) — manual action needed now." >&2
      body="Automatic upgrade of Hindsight $CUR -> $ver FAILED, and the automatic rollback ALSO failed (bin/upgrade.sh exit $upgrade_rc). Hindsight's state on the server is UNKNOWN/BAD — this needs manual action now.

Pre-upgrade dump: ${pre_dump:-see the log tail below}

Manual restore (docs/PLAYBOOK.md §6/§8), run on the server from server-setup/:
  bin/hs stop hindsight
  sed -i 's|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=$CUR|' version.env
  bin/restore-db.sh --yes --no-start ${pre_dump:-<pre-upgrade dump>}
  bin/hs up -d
  bin/hs ready

Release: $html_url

--- log tail (secrets redacted) ---
$(redact_log "$LOG" | tail -n 100)"
      rm -f "$LOG"
      open_or_dedupe_issue "Hindsight auto-upgrade to $ver failed AND rollback failed — manual action needed" "$body" || true
      exit 1
      ;;
  esac
fi

# ---- minor/major: report only, never applied automatically --------------
say "$cmp release available: $CUR -> $ver (manual upgrade only)"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would open issue 'Hindsight $ver available (manual upgrade)' — no upgrade run, no git changes."
  exit 0
fi
body="A new $cmp release of Hindsight is available: $CUR -> $ver. This is NOT applied automatically — only PATCH bumps (same MAJOR.MINOR) are.

Release: $html_url

$notes_excerpt

Manual upgrade, run on the server from server-setup/:
  bin/upgrade.sh $ver"
if open_or_dedupe_issue "Hindsight $ver available (manual upgrade)" "$body"; then exit 0; else exit 1; fi
