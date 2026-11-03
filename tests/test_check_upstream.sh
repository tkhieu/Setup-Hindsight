#!/bin/sh
# bin/check-upstream.sh outcomes:
#   - up to date                        -> nothing, exit 0
#   - prerelease/older tag               -> ignored, exit 0
#   - GitHub API error (403/5xx)         -> no issue, exit non-zero
#   - minor/major available              -> issue only, bin/upgrade.sh NOT called
#   - a matching open issue already exists -> no duplicate created
#   - --dry-run                          -> no upgrade/issue/git, exit 0
#   - patch available, upgrade succeeds  -> upgrade.sh called with exactly
#     "--yes --auto-rollback --smoke <ver>", version.env committed+pushed,
#     a "Hindsight auto-upgraded..." issue opened
#   - patch available, upgrade fails     -> no commit/push, a "...failed
#     (rolled back)" issue opened, exit non-zero
#   - GITHUB_ISSUE_TOKEN is never put in any curl argv (always via -K - on
#     stdin)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"

# ---- shared fake curl, parameterized at call time via env vars -----------
# (every scenario below exports the subset of *_BODY/*_STATUS it needs
# before invoking check-upstream.sh; unset ones fall back to a harmless
# default via the ${VAR:-default} forms inside the script itself).
write_fake_curl() {  # write_fake_curl <fakebin-dir>
  cat > "$1/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_ARGV_LOG"

has_K=0
prev=""
bodyfile=""
for a in "$@"; do
  if [ "$prev" = "-K" ] && [ "$a" = "-" ]; then has_K=1; fi
  if [ "$prev" = "--data-binary" ]; then bodyfile="${a#@}"; fi
  prev="$a"
done
# Drain+discard stdin (the -K config, which may carry the token) — never
# logged, so a token leaking there would never show up as a false pass.
[ "$has_K" = 1 ] && cat >/dev/null

url=""
for a in "$@"; do url="$a"; done

case "$url" in
  *"ghcr.io/token"*)
    printf '{"token":"fake-ghcr-token"}' ;;
  *"ghcr.io/v2/"*"/manifests/"*)
    printf '%s' "${GHCR_STATUS:-200}" ;;
  *"api.github.com/repos/vectorize-io/hindsight/releases/latest")
    printf '%s\n%s' "${RELEASE_BODY:-}" "${RELEASE_STATUS:-200}" ;;
  *"api.github.com/repos/tkhieu/Setup-Hindsight/labels")
    printf '%s\n%s' "" "${LABEL_STATUS:-201}" ;;
  *"api.github.com/repos/tkhieu/Setup-Hindsight/issues?"*)
    printf '%s\n%s' "${ISSUES_LIST_BODY:-[]}" "${ISSUES_LIST_STATUS:-200}" ;;
  *"api.github.com/repos/tkhieu/Setup-Hindsight/issues")
    [ -n "$bodyfile" ] && [ -n "${CREATED_ISSUE_LOG:-}" ] && cat "$bodyfile" >> "$CREATED_ISSUE_LOG"
    printf '%s\n%s' "" "${CREATE_ISSUE_STATUS:-201}" ;;
  *)
    printf '{}\n200' ;;
esac
EOF
  chmod +x "$1/curl"
}

# ---- minimal (non-git) fixture: covers every outcome that never touches
# the repo or runs bin/upgrade.sh ------------------------------------------
setup_minimal() {  # setup_minimal <dir> <cur-version>
  dir="$1" cur="$2"
  mkdir -p "$dir/bin/lib" "$dir/fakebin"
  cp "$SS/bin/check-upstream.sh" "$dir/bin/check-upstream.sh"
  cp "$SS/bin/lib/env.sh" "$dir/bin/lib/env.sh"
  cp "$SS/bin/lib/json.sh" "$dir/bin/lib/json.sh"
  chmod +x "$dir/bin/check-upstream.sh"
  write_fake_curl "$dir/fakebin"

  printf 'HINDSIGHT_VERSION=%s\n' "$cur" > "$dir/version.env"
  : > "$dir/base.env"
  : > "$dir/secrets.env"
  : > "$dir/CURL_ARGV_LOG"
}

run_minimal() {  # run_minimal <dir> [extra args...]
  dir="$1"; shift
  ( cd "$dir" \
    && CURL_ARGV_LOG="$dir/CURL_ARGV_LOG" \
       PATH="$dir/fakebin:$PATH" \
       ./bin/check-upstream.sh "$@" </dev/null )
}

rel_json() {  # rel_json <tag>
  printf '{"tag_name":"%s","draft":false,"prerelease":false,"html_url":"https://github.com/vectorize-io/hindsight/releases/tag/%s","body":"notes"}' "$1" "$1"
}

# ============================================================================
# Scenario: up to date
# ============================================================================
T1="$(mktemp -d)"
setup_minimal "$T1" 1.1.0
RELEASE_BODY="$(rel_json v1.1.0)"
export RELEASE_BODY
out1="$(run_minimal "$T1")"
unset RELEASE_BODY
printf '%s\n' "$out1" | grep -q "up to date" || { echo "$out1"; echo "FAIL: expected 'up to date'"; exit 1; }
rm -rf "$T1"
echo "ok - up to date -> nothing"

# ============================================================================
# Scenario: prerelease tag and an older release are both ignored
# ============================================================================
T2="$(mktemp -d)"
setup_minimal "$T2" 1.2.0
RELEASE_BODY="$(rel_json v1.2.0-rc1)"
export RELEASE_BODY
out2a="$(run_minimal "$T2")"
printf '%s\n' "$out2a" | grep -qi "ignoring" || { echo "$out2a"; echo "FAIL: expected a prerelease tag to be ignored"; exit 1; }
RELEASE_BODY="$(rel_json v1.1.0)"
export RELEASE_BODY
out2b="$(run_minimal "$T2")"
unset RELEASE_BODY
printf '%s\n' "$out2b" | grep -q "up to date" || { echo "$out2b"; echo "FAIL: expected an older release to be reported as up to date"; exit 1; }
rm -rf "$T2"
echo "ok - prerelease tag / older release ignored"

# ============================================================================
# Scenario: GitHub API error -> no issue, exit non-zero
# ============================================================================
T3="$(mktemp -d)"
setup_minimal "$T3" 1.1.0
export RELEASE_STATUS=403
set +e
out3="$(run_minimal "$T3" 2>&1)"
rc3=$?
set -e
unset RELEASE_STATUS
[ "$rc3" -ne 0 ] || { echo "$out3"; echo "FAIL: expected a non-zero exit on a 403 from the releases API"; exit 1; }
grep -q "api.github.com/repos/tkhieu/Setup-Hindsight/issues " "$T3/CURL_ARGV_LOG" 2>/dev/null \
  && { echo "FAIL: an issue-creation call was made despite the releases API erroring"; exit 1; }
rm -rf "$T3"
echo "ok - GitHub API error -> no issue, non-zero exit"

# ============================================================================
# Scenario: minor available -> issue only, bin/upgrade.sh is NEVER called
# (there is no bin/upgrade.sh in this fixture at all, so if check-upstream.sh
# ever tried to run it, the whole scenario would fail with "command not
# found" instead of the assertions below)
# ============================================================================
T4="$(mktemp -d)"
setup_minimal "$T4" 1.1.0
printf 'GITHUB_ISSUE_TOKEN=test-token\n' > "$T4/secrets.env"
CREATED_ISSUE_LOG_4="$T4/created_issue.json"
: > "$CREATED_ISSUE_LOG_4"
RELEASE_BODY="$(rel_json v1.2.0)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_4"
out4="$(run_minimal "$T4")"
unset RELEASE_BODY CREATED_ISSUE_LOG
printf '%s\n' "$out4" | grep -q "opened issue: Hindsight 1.2.0 available (manual upgrade)" \
  || { echo "$out4"; echo "FAIL: expected the manual-upgrade issue to be opened"; exit 1; }
grep -q '"title":"Hindsight 1.2.0 available (manual upgrade)"' "$CREATED_ISSUE_LOG_4" \
  || { echo "FAIL: created-issue payload missing the expected title:"; cat "$CREATED_ISSUE_LOG_4"; exit 1; }
rm -rf "$T4"
echo "ok - minor release -> issue only, upgrade.sh never invoked"

# ============================================================================
# Scenario: a matching open issue already exists -> no duplicate created
# ============================================================================
T5="$(mktemp -d)"
setup_minimal "$T5" 1.1.0
printf 'GITHUB_ISSUE_TOKEN=test-token\n' > "$T5/secrets.env"
CREATED_ISSUE_LOG_5="$T5/created_issue.json"
: > "$CREATED_ISSUE_LOG_5"
RELEASE_BODY="$(rel_json v1.2.0)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_5" \
  ISSUES_LIST_BODY='[{"number":42,"title":"Hindsight 1.2.0 available (manual upgrade)"}]'
out5="$(run_minimal "$T5")"
unset RELEASE_BODY CREATED_ISSUE_LOG ISSUES_LIST_BODY
printf '%s\n' "$out5" | grep -q "already open" || { echo "$out5"; echo "FAIL: expected a 'already open' dedupe message"; exit 1; }
[ -s "$CREATED_ISSUE_LOG_5" ] && { echo "FAIL: a duplicate issue was created despite one already being open:"; cat "$CREATED_ISSUE_LOG_5"; exit 1; }
rm -rf "$T5"
echo "ok - duplicate issue is deduped, not recreated"

# ============================================================================
# Scenario: --dry-run does network reads but no upgrade/issue/git
# ============================================================================
T6="$(mktemp -d)"
setup_minimal "$T6" 1.1.0
CREATED_ISSUE_LOG_6="$T6/created_issue.json"
: > "$CREATED_ISSUE_LOG_6"
RELEASE_BODY="$(rel_json v1.1.1)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_6"
out6="$(run_minimal "$T6" --dry-run)"
unset RELEASE_BODY CREATED_ISSUE_LOG
printf '%s\n' "$out6" | grep -q '\[dry-run\]' || { echo "$out6"; echo "FAIL: expected '[dry-run]' output"; exit 1; }
[ -s "$CREATED_ISSUE_LOG_6" ] && { echo "FAIL: --dry-run created an issue:"; cat "$CREATED_ISSUE_LOG_6"; exit 1; }
grep -q "/issues " "$T6/CURL_ARGV_LOG" && { echo "FAIL: --dry-run made an issues API call:"; cat "$T6/CURL_ARGV_LOG"; exit 1; }
rm -rf "$T6"
echo "ok - --dry-run makes no upgrade/issue/git calls"

# ============================================================================
# Scenario: GITHUB_ISSUE_TOKEN is never put in curl's argv.
# Reuses the minor-release path (token set, issue creation exercised).
# ============================================================================
T7="$(mktemp -d)"
setup_minimal "$T7" 1.1.0
printf 'GITHUB_ISSUE_TOKEN=CANARY-GH-TOKEN-f00dbeef\n' > "$T7/secrets.env"
RELEASE_BODY="$(rel_json v1.2.0)"
export RELEASE_BODY
run_minimal "$T7" >/dev/null
unset RELEASE_BODY
grep -qF "CANARY-GH-TOKEN-f00dbeef" "$T7/CURL_ARGV_LOG" \
  && { echo "FAIL: the GitHub token leaked into curl argv:"; cat "$T7/CURL_ARGV_LOG"; exit 1; }
# Sanity: prove curl was actually called with -K - (so the token really did
# flow through stdin, not that nothing ran at all).
grep -q -- '-K -' "$T7/CURL_ARGV_LOG" || { echo "FAIL: expected at least one '-K -' curl call"; exit 1; }
rm -rf "$T7"
echo "ok - GITHUB_ISSUE_TOKEN never appears in curl argv"

# ============================================================================
# git-backed fixture for the two patch scenarios: a real git repo laid out
# like the real one (server-setup/ under the repo root), with a real local
# bare "origin" so the commit+push path is exercised for real, and a fake
# bin/upgrade.sh whose exit code drives success vs. failure.
# ============================================================================
setup_git() {  # setup_git <dir> <cur-version>
  dir="$1" cur="$2"
  repo="$dir/repo"
  origin="$dir/origin.git"
  mkdir -p "$repo/server-setup/bin/lib" "$dir/fakebin"
  git init -q -b main "$origin" --bare
  git init -q -b main "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" remote add origin "$origin"

  cp "$SS/bin/check-upstream.sh" "$repo/server-setup/bin/check-upstream.sh"
  cp "$SS/bin/lib/env.sh" "$repo/server-setup/bin/lib/env.sh"
  cp "$SS/bin/lib/json.sh" "$repo/server-setup/bin/lib/json.sh"
  chmod +x "$repo/server-setup/bin/check-upstream.sh"
  write_fake_curl "$dir/fakebin"

  printf 'HINDSIGHT_VERSION=%s\n' "$cur" > "$repo/server-setup/version.env"
  : > "$repo/server-setup/base.env"
  printf 'GITHUB_ISSUE_TOKEN=test-token\n' > "$repo/server-setup/secrets.env"
  # Mirrors the real repo's top-level .gitignore: the lock file
  # check-upstream.sh creates must never make git_ready_for_autoupgrade see
  # a dirty working tree on every single run.
  printf 'server-setup/.check-upstream.lock\n' > "$repo/.gitignore"
  : > "$dir/CURL_ARGV_LOG"

  git -C "$repo" add -A
  git -C "$repo" commit -q -m init
  git -C "$repo" push -q -u origin main
}

run_git() {  # run_git <dir> [extra args...]
  dir="$1"; shift
  ( cd "$dir/repo/server-setup" \
    && CURL_ARGV_LOG="$dir/CURL_ARGV_LOG" \
       PATH="$dir/fakebin:$PATH" \
       ./bin/check-upstream.sh "$@" </dev/null )
}

# ============================================================================
# Scenario: patch available, upgrade succeeds -> upgrade.sh called with
# exactly "--yes --auto-rollback --smoke <ver>", version.env committed +
# pushed to origin/main, success issue opened.
# ============================================================================
T8="$(mktemp -d)"
setup_git "$T8" 1.1.0
UPGRADE_LOG_8="$T8/upgrade.log"
CREATED_ISSUE_LOG_8="$T8/created_issue.json"
: > "$UPGRADE_LOG_8"
: > "$CREATED_ISSUE_LOG_8"
cat > "$T8/repo/server-setup/bin/upgrade.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$UPGRADE_LOG_8"
# A real upgrade.sh bumps version.env itself — simulate that so the
# commit+push step right after has something real to commit.
sed -i 's|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=1.1.1|' "$T8/repo/server-setup/version.env"
echo "fake upgrade.sh: ok"
exit 0
EOF
chmod +x "$T8/repo/server-setup/bin/upgrade.sh"
# Commit it: the fake upgrade.sh must be a tracked, clean file just like
# the real one is in the real repo — otherwise git_ready_for_autoupgrade's
# dirty-tree check would always see it as a stray untracked file.
git -C "$T8/repo" add -A
git -C "$T8/repo" commit -q -m "add fake upgrade.sh"
git -C "$T8/repo" push -q origin main

RELEASE_BODY="$(rel_json v1.1.1)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_8"
out8="$(run_git "$T8")"
unset RELEASE_BODY CREATED_ISSUE_LOG

grep -qF -- '--yes --auto-rollback --smoke 1.1.1' "$UPGRADE_LOG_8" \
  || { echo "FAIL: expected upgrade.sh called with '--yes --auto-rollback --smoke 1.1.1', got:"; cat "$UPGRADE_LOG_8"; exit 1; }

printf '%s\n' "$out8" | grep -q "Committing + pushing version.env" \
  || { echo "$out8"; echo "FAIL: expected the commit+push step to run"; exit 1; }
git -C "$T8/repo" log -1 --format=%s | grep -qF "chore: bump Hindsight to 1.1.1" \
  || { echo "FAIL: missing expected commit message"; git -C "$T8/repo" log --oneline; exit 1; }
# Pushed for real: a fresh clone of the local bare origin must see the bump.
CHECKOUT_8="$T8/checkout"
git clone -q "$T8/origin.git" "$CHECKOUT_8"
grep -q '^HINDSIGHT_VERSION=1.1.1$' "$CHECKOUT_8/server-setup/version.env" \
  || { echo "FAIL: origin/main was not actually updated with the version bump"; exit 1; }

grep -q '"title":"Hindsight auto-upgraded to 1.1.1"' "$CREATED_ISSUE_LOG_8" \
  || { echo "FAIL: missing the success issue:"; cat "$CREATED_ISSUE_LOG_8"; exit 1; }

rm -rf "$T8"
echo "ok - patch upgrade succeeds: upgrade.sh flags, commit+push, success issue"

# ============================================================================
# Scenario: patch available, upgrade FAILS -> no commit/push, a "...failed
# (rolled back)" issue opened, exit non-zero.
# ============================================================================
T9="$(mktemp -d)"
setup_git "$T9" 1.1.0
UPGRADE_LOG_9="$T9/upgrade.log"
CREATED_ISSUE_LOG_9="$T9/created_issue.json"
: > "$UPGRADE_LOG_9"
: > "$CREATED_ISSUE_LOG_9"
cat > "$T9/repo/server-setup/bin/upgrade.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$UPGRADE_LOG_9"
echo "fake upgrade.sh: NOT ready after 5 minutes" >&2
exit 1
EOF
chmod +x "$T9/repo/server-setup/bin/upgrade.sh"
git -C "$T9/repo" add -A
git -C "$T9/repo" commit -q -m "add fake upgrade.sh"
git -C "$T9/repo" push -q origin main

BEFORE_SHA_9="$(git -C "$T9/repo" rev-parse main)"
RELEASE_BODY="$(rel_json v1.1.1)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_9"
set +e
out9="$(run_git "$T9" 2>&1)"
rc9=$?
set -e
unset RELEASE_BODY CREATED_ISSUE_LOG

[ "$rc9" -ne 0 ] || { echo "$out9"; echo "FAIL: expected a non-zero exit when upgrade.sh fails"; exit 1; }
[ "$(git -C "$T9/repo" rev-parse main)" = "$BEFORE_SHA_9" ] \
  || { echo "FAIL: a commit was made on main despite upgrade.sh failing"; exit 1; }
grep -q '"title":"Hindsight auto-upgrade to 1.1.1 failed (rolled back)"' "$CREATED_ISSUE_LOG_9" \
  || { echo "FAIL: missing the failure issue:"; cat "$CREATED_ISSUE_LOG_9"; exit 1; }
grep -q "NOT ready after 5 minutes" "$CREATED_ISSUE_LOG_9" \
  || { echo "FAIL: expected the upgrade.sh log tail inside the failure issue body"; exit 1; }

rm -rf "$T9"
echo "ok - patch upgrade fails: no commit/push, failure issue with log tail, non-zero exit"
