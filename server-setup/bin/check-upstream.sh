#!/usr/bin/env bash
# Weekly check for a new Hindsight upstream release (vectorize-io/hindsight).
# PATCH bumps (same MAJOR.MINOR, higher PATCH, e.g. 1.1.0 -> 1.1.1) are
# upgraded AUTOMATICALLY via `bin/upgrade.sh --yes --auto-rollback --smoke`;
# MINOR/MAJOR bumps are never applied automatically, only reported. All
# notifications go through ops-notify. Minor/major release notices are
# deduped by kind and version in local state. See docs/PLAYBOOK.md §8b.
#
# Usage: bin/check-upstream.sh [--dry-run]
#   --dry-run   does the network reads (latest-release lookup, GHCR tag
#               check) but performs no upgrade, no git commit/push, and
#               sends no notification — prints what it would have done instead.
set -euo pipefail

# python3 is required for parsing the release and GHCR token JSON.
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
NOTIFIED_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/hindsight/upgrade-notified"
OPS_NOTIFY_BIN="${OPS_NOTIFY_BIN:-$HOME/.local/bin/ops-notify}"
# Generous but FINITE bound on git fetch/push below — every curl call here
# already carries its own --max-time/--connect-timeout. See docs/PLAYBOOK.md
# §8b (same reasoning as bin/upgrade.sh's PULL_TIMEOUT/BACKUP_TIMEOUT/
# RESTORE_TIMEOUT: TimeoutStartSec=infinity trusts these, not systemd).
GIT_TIMEOUT="${HINDSIGHT_GIT_TIMEOUT:-60}"

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

# ---- GitHub release lookup (anonymous, read-only) ------------------------
GH_API_STATUS=""
GH_API_BODY=""
gh_api() {  # gh_api <path>
  local out
  out="$(curl -sS --connect-timeout 10 --max-time 30 -w '\n%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com$1")"
  GH_API_STATUS="${out##*$'\n'}"
  GH_API_BODY="${out%$'\n'*}"
}

# ---- GHCR anonymous tag check ------------------------------------------
# Token endpoint first (anonymous pull-scope token, short-lived, not a
# repo secret — still routed via -K - for consistency), then HEAD-style
# manifest check (-o /dev/null, we only care about the status code).
# Takes the FULL tag compose will actually pull (version + image suffix,
# e.g. 1.2.1-slim — see image_suffix in bin/lib/env.sh), not the bare
# version: upstream publishes the slim and full variants separately, so a
# bare tag existing says nothing about the one this stack runs.
ghcr_tag_exists() {  # ghcr_tag_exists <tag, e.g. 1.2.1-slim>
  local token status
  token="$(curl -fsS --connect-timeout 10 --max-time 15 \
    "https://ghcr.io/token?scope=repository:vectorize-io/hindsight:pull" | json_str token)"
  [ -n "$token" ] || return 1
  status="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json"\n' "$token" \
    | curl -s --connect-timeout 10 --max-time 15 -o /dev/null -w '%{http_code}' -K - \
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
  if ! timeout "$GIT_TIMEOUT" git -C "$REPO_ROOT" fetch --quiet origin main; then
    echo "git fetch origin main failed (or exceeded ${GIT_TIMEOUT}s)" >&2
    return 1
  fi
  local_sha="$(git -C "$REPO_ROOT" rev-parse main)"
  remote_sha="$(git -C "$REPO_ROOT" rev-parse origin/main)"
  if [ "$local_sha" != "$remote_sha" ]; then
    echo "local main ($local_sha) is not fast-forwardable onto origin/main ($remote_sha)" >&2
    return 1
  fi
}

# Send the message via stdin so neither its contents nor any secret can
# appear in argv. Failure is visible in the journal; callers handling an
# upgrade outcome preserve that outcome's exit code and never roll back.
notify() {  # notify <level> <title> <body>
  local level="$1" title="$2" body="$3"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] would notify (%s): %s\n%s\n' "$level" "$title" "$body"
    return 0
  fi
  if [ ! -x "$OPS_NOTIFY_BIN" ] ||
     ! printf '%s\n' "$body" | "$OPS_NOTIFY_BIN" --stdin --level "$level" --stack hindsight --title "$title"; then
    printf 'ERROR: ops-notify failed for: %s\n%s\n' "$title" "$body" >&2
    return 1
  fi
}

notify_release_once() {  # notify_release_once <kind> <version> <title> <body>
  local kind="$1" version="$2" title="$3" body="$4"
  if [ -f "$NOTIFIED_STATE" ] && grep -Fxq "$kind $version" "$NOTIFIED_STATE"; then
    echo "already notified: $kind $version"
    return 0
  fi
  notify info "$title" "$body" || return 1
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  ( umask 077
    mkdir -p "$(dirname "$NOTIFIED_STATE")"
    touch "$NOTIFIED_STATE"
    chmod 600 "$NOTIFIED_STATE"
    printf '%s %s\n' "$kind" "$version" >> "$NOTIFIED_STATE"
  )
}

# ============================================================================
# main
# ============================================================================

CUR="$(env_get "$CONFIG_DIR/version.env" HINDSIGHT_VERSION)"
[ -n "$CUR" ] || { echo "ERROR: missing HINDSIGHT_VERSION in $CONFIG_DIR/version.env" >&2; exit 1; }

say "Fetching latest stable release: $UPSTREAM_REPO"
gh_api "/repos/$UPSTREAM_REPO/releases/latest"
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

image_tag="${ver}$(image_suffix "$CONFIG_DIR/version.env")"
say "Confirming GHCR image tag exists: ghcr.io/vectorize-io/hindsight:$image_tag"
if ! ghcr_tag_exists "$image_tag"; then
  echo "ERROR: ghcr.io/vectorize-io/hindsight:$image_tag not found via the anonymous pull token — not upgrading or reporting yet (image probably still publishing after the GitHub release)." >&2
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
    echo "[dry-run] on success: commit+push server-setup/version.env, send notification 'Hindsight auto-upgraded to $ver'"
    echo "[dry-run] on a VERIFIED failed-and-recovered outcome (exit 2): notify 'Hindsight auto-upgrade to $ver failed (rolled back)' (pre-upgrade dump taken), '...failed before changing anything (restarted OK)' (stopped, no dump), or '...not applied; old version verified running' (image pull failed, stack untouched)"
    echo "[dry-run] on a failed-and-UNVERIFIED outcome (exit 3): send the matching '...manual action needed' error notification instead (rollback failed / restart not verified / untouched old version not verified)"
    echo "[dry-run] after a healthy upgrade: if git commit fails, notify 'Hindsight auto-upgraded to $ver but version.env commit failed'; if only the push fails, notify '...but version.env push failed'"
    exit 0
  fi

  if ! git_ready_for_autoupgrade; then
    body="Patch release $ver is available (current: $CUR), but auto-upgrade was skipped because the repo at $REPO_ROOT is not in a state it is safe to auto-commit/push to (dirty working tree, not on main, or main is not fast-forwardable onto origin/main — see journalctl --user -u hindsight-upgrade-check for the exact reason).

Release: $html_url

Manual upgrade (after fixing the repo state above), run on the server from server-setup/:
  bin/upgrade.sh $ver"
    notify warn "Hindsight $ver available but auto-upgrade blocked (repo not clean)" "$body" || true
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
      # commit_ok covers `add`+`commit` — a failure there means NO commit
      # exists anywhere (local git identity not set, a pre-commit hook
      # rejecting it, a dirty index, ...), so the fix is to actually make
      # one. push_ok (only even attempted if commit_ok) covers the SEPARATE
      # `push` step — a failure there means the commit already exists
      # LOCALLY, so the fix is pull+push, NEVER a second commit. Conflating
      # these two would tell the operator to commit again in the push-ok
      # case, or to "just push" when there is nothing yet to push.
      commit_ok=1
      push_ok=0
      git -C "$REPO_ROOT" add server-setup/version.env || commit_ok=0
      if [ "$commit_ok" = 1 ]; then
        git -C "$REPO_ROOT" commit -m "chore: bump Hindsight to $ver" || commit_ok=0
      fi
      if [ "$commit_ok" = 1 ]; then
        push_ok=1
        timeout "$GIT_TIMEOUT" git -C "$REPO_ROOT" push origin main || push_ok=0
      fi

      if [ "$commit_ok" = 1 ] && [ "$push_ok" = 1 ]; then
        body="Hindsight was automatically upgraded from $CUR to $ver (patch release) and the smoke test passed.

Release: $html_url

$notes_excerpt"
        rm -f "$LOG"
        if notify info "Hindsight auto-upgraded to $ver" "$body"; then exit 0; else exit 1; fi
      elif [ "$commit_ok" = 0 ]; then
        # Upgrade itself is healthy and running $ver — only the repo update
        # failed, and failed before any commit was even made. Nothing to
        # roll back; this is a git problem, not a hindsight problem, so
        # bin/upgrade.sh's own rollback is never involved here.
        echo "ERROR: commit of version.env failed after a successful upgrade to $ver — hindsight is healthy on $ver, but the repo on the server was never updated (no commit exists)." >&2
        body="Hindsight was upgraded to $ver and passed its smoke test — it is healthy and running $ver right now. Committing version.env to $ver on the server afterward FAILED (before any commit was made) — likely a missing git identity (user.name/user.email) or a rejecting pre-commit/commit-msg hook. Nothing needs to be rolled back.

Fix manually on the server:
  git -C $REPO_ROOT status
  git -C $REPO_ROOT config user.name && git -C $REPO_ROOT config user.email   # set these if empty
  git -C $REPO_ROOT add server-setup/version.env
  git -C $REPO_ROOT commit -m \"chore: bump Hindsight to $ver\"
  git -C $REPO_ROOT push origin main

Release: $html_url"
        rm -f "$LOG"
        notify warn "Hindsight auto-upgraded to $ver but version.env commit failed" "$body" || true
        exit 1
      else
        # commit_ok=1, push_ok=0: the LOCAL commit above already landed —
        # only pushing it to origin/main failed. The fix is pull+push,
        # NEVER a second commit (that would duplicate/conflict with the
        # one that's already there).
        echo "ERROR: push of version.env failed after a successful upgrade to $ver — hindsight is healthy on $ver, but the commit on the server has not reached origin/main yet." >&2
        body="Hindsight was upgraded to $ver and passed its smoke test — it is healthy and running $ver right now. The commit bumping version.env to $ver already exists LOCALLY on the server; only pushing it to origin/main afterward FAILED. Nothing needs to be rolled back, and do NOT create a second commit.

Fix manually on the server:
  git -C $REPO_ROOT status
  git -C $REPO_ROOT log origin/main..HEAD
  git -C $REPO_ROOT pull --rebase origin main   # or resolve any conflict by hand
  git -C $REPO_ROOT push origin main

Release: $html_url"
        rm -f "$LOG"
        notify warn "Hindsight auto-upgraded to $ver but version.env push failed" "$body" || true
        exit 1
      fi
      ;;
    2)
      # upgrade.sh exits 2 for THREE distinct, both-VERIFIED-healthy cases,
      # told apart by the pre-upgrade dump line and the RECOVERY_KIND
      # marker bin/upgrade.sh prints on every before-bump recovery (its
      # on_exit: "restarted" when hindsight was actually stopped — or a
      # stop was attempted and may have timed out — vs "untouched" when
      # only the image pull failed and hindsight was never stopped at
      # all, so nothing was ever restarted):
      #   1. a real auto-rollback that succeeded (a pre-upgrade dump
      #      exists — the "pre-upgrade dump: ..." line is only ever
      #      printed after that backup step completes)
      #   2. hindsight was actually stopped (or a stop was attempted) and
      #      then successfully restarted (RECOVERY_KIND: restarted)
      #   3. hindsight was never even stopped — only the image pull
      #      failed — and was just confirmed still healthy, untouched
      #      (RECOVERY_KIND: untouched); calling this "restarted OK" would
      #      be flatly wrong, since nothing was ever restarted.
      # `|| true`: no match is a normal, expected outcome here, not a
      # pipeline error (see bin/upgrade.sh's own `set -euo pipefail` note
      # on this same grep).
      pre_dump="$(grep -o 'pre-upgrade dump.*: .*' "$LOG" | tail -1 | sed 's/.*: //')" || true
      if [ -n "$pre_dump" ]; then
        echo "upgrade.sh failed but auto-rollback succeeded and was VERIFIED (back on $CUR) — see the outcome in the journal." >&2
        title="Hindsight auto-upgrade to $ver failed (rolled back)"
        body="Automatic upgrade of Hindsight $CUR -> $ver FAILED and was automatically rolled back to $CUR by bin/upgrade.sh --auto-rollback — VERIFIED back on $CUR and healthy (version.env pin + the running container's image + /health all checked). version.env was NOT changed; nothing was committed or pushed.

Release: $html_url

See journalctl --user -u hindsight-upgrade-check for this outcome."
      elif grep -q "RECOVERY_KIND: untouched" "$LOG"; then
        echo "upgrade.sh failed before anything was touched (the image pull itself failed) — hindsight was never stopped, just confirmed still healthy on $CUR." >&2
        title="Hindsight auto-upgrade to $ver not applied; old version verified running"
        body="An attempt to automatically upgrade Hindsight $CUR -> $ver FAILED before hindsight was ever stopped (the image pull itself failed) — the upgrade was never applied, nothing was touched or restarted, and bin/upgrade.sh VERIFIED hindsight is still running fine on $CUR (version.env pin + the running container's image + /health all checked).

Release: $html_url

See journalctl --user -u hindsight-upgrade-check for this outcome."
      else
        echo "upgrade.sh failed before changing anything (no pre-upgrade dump was ever taken) — hindsight was stopped (or a stop was attempted) and has been restarted and VERIFIED healthy on $CUR." >&2
        title="Hindsight auto-upgrade to $ver failed before changing anything (restarted OK)"
        body="An attempt to automatically upgrade Hindsight $CUR -> $ver FAILED before any version switch happened (hindsight was stopped, or a stop was attempted, before the pre-upgrade backup itself failed) — nothing in the database was touched, no dump was needed. bin/upgrade.sh restarted hindsight and VERIFIED it is healthy on $CUR afterward (version.env pin + the running container's image + /health all checked).

Release: $html_url

See journalctl --user -u hindsight-upgrade-check for this outcome."
      fi
      rm -f "$LOG"
      notify warn "$title" "$body" || true
      exit 1
      ;;
    *)
      # Anything else (3 = the verified-recovery check ITSELF failed, or
      # any unexpected code) is treated as the worst case on purpose:
      # hindsight's actual state is unknown/bad and needs a human NOW. Same
      # three-way split as exit 2 above (dump present / RECOVERY_KIND
      # untouched / RECOVERY_KIND restarted) decides which manual-recovery
      # text applies.
      pre_dump="$(grep -o 'pre-upgrade dump.*: .*' "$LOG" | tail -1 | sed 's/.*: //')" || true
      echo "upgrade.sh failed and the recovery could not be VERIFIED (exit $upgrade_rc) — manual action needed now." >&2
      if [ -n "$pre_dump" ]; then
        title="Hindsight auto-upgrade to $ver failed AND rollback failed — manual action needed"
        body="Automatic upgrade of Hindsight $CUR -> $ver FAILED, and the automatic rollback could NOT be verified (bin/upgrade.sh exit $upgrade_rc). Hindsight's state on the server is UNKNOWN/BAD — this needs manual action now.

Pre-upgrade dump: $pre_dump

Manual restore (docs/PLAYBOOK.md §6/§8), run on the server from server-setup/:
  bin/hs stop hindsight
  sed -i 's|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=$CUR|' version.env
  bin/restore-db.sh --yes --no-start $pre_dump
  bin/hs up -d
  bin/hs ready

Release: $html_url

See journalctl --user -u hindsight-upgrade-check for this outcome."
      elif grep -q "RECOVERY_KIND: untouched" "$LOG"; then
        title="Hindsight auto-upgrade to $ver not applied; old version could not be verified — manual action needed"
        body="An attempt to automatically upgrade Hindsight $CUR -> $ver FAILED before hindsight was ever stopped (the image pull itself failed) — the upgrade was never applied, but bin/upgrade.sh could NOT verify hindsight is still healthy on $CUR afterward (exit $upgrade_rc). No dump was ever taken — there is nothing to restore, version.env should still read $CUR. Check manually:
  cd $CONFIG_DIR
  bin/hs ps
  bin/hs ready
  bin/hs logs hindsight

Release: $html_url

See journalctl --user -u hindsight-upgrade-check for this outcome."
      else
        title="Hindsight auto-upgrade to $ver failed before changing anything AND the restart could not be verified — manual action needed"
        body="An attempt to automatically upgrade Hindsight $CUR -> $ver FAILED before any version switch happened (hindsight was stopped, or a stop was attempted), and bin/upgrade.sh could NOT verify hindsight is healthy on $CUR afterward (exit $upgrade_rc). No dump was ever taken — there is nothing to restore, version.env should still read $CUR. Check and restart manually:
  cd $CONFIG_DIR
  bin/hs ps
  bin/hs up -d
  bin/hs ready
  bin/hs logs hindsight

Release: $html_url

See journalctl --user -u hindsight-upgrade-check for this outcome."
      fi
      rm -f "$LOG"
      notify error "$title" "$body" || true
      exit 1
      ;;
  esac
fi

# ---- minor/major: report only, never applied automatically --------------
say "$cmp release available: $CUR -> $ver (manual upgrade only)"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would send notification 'Hindsight $ver available (manual upgrade)' — no upgrade run, no git changes."
  exit 0
fi
body="A new $cmp release of Hindsight is available: $CUR -> $ver. This is NOT applied automatically — only PATCH bumps (same MAJOR.MINOR) are.

Release: $html_url

$notes_excerpt

Manual upgrade, run on the server from server-setup/:
  bin/upgrade.sh $ver"
if notify_release_once "$cmp" "$ver" "Hindsight $ver available (manual upgrade)" "$body"; then exit 0; else exit 1; fi
