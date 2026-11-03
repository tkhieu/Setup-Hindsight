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
#   - patch available, upgrade.sh exits 2 (rollback OK) -> no commit/push, a
#     "...failed (rolled back)" issue opened, exit non-zero
#   - patch available, upgrade.sh exits 3 (rollback ALSO failed) -> the
#     louder "...failed AND rollback failed" issue, with the pre-upgrade
#     dump path and the manual restore command, exit non-zero
#   - patch available, upgrade succeeds but git push fails -> a "...but
#     version.env push failed" issue, NOT a rollback, exit non-zero
#   - a GitHub API error while listing issues (dedupe lookup) -> no issue
#     created, exit non-zero
#   - dedupe finds a CLOSED issue on page 2 of the listing -> no duplicate
#   - GITHUB_ISSUE_TOKEN is never put in any curl argv (always via -K - on
#     stdin)
#   - --dry-run creates no file at all, including the shared lock file
#   - missing python3 -> fails loud, immediately
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
    printf '%s\n%s' "${LABEL_BODY:-}" "${LABEL_STATUS:-201}" ;;
  *"api.github.com/repos/tkhieu/Setup-Hindsight/issues?"*"page=2"*)
    printf '%s\n%s' "${ISSUES_LIST_BODY_PAGE2:-[]}" "${ISSUES_LIST_STATUS:-200}" ;;
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
  cp "$SS/bin/lib/lock.sh" "$dir/bin/lib/lock.sh"
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
printf '%s\n' "$out5" | grep -q "already exists" || { echo "$out5"; echo "FAIL: expected an 'already exists' dedupe message"; exit 1; }
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
[ -e "$T6/.ops.lock" ] && { echo "FAIL: --dry-run created the shared lock file (must skip locking entirely)"; exit 1; }
rm -rf "$T6"
echo "ok - --dry-run makes no upgrade/issue/git calls and creates no files at all"

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
  cp "$SS/bin/lib/lock.sh" "$repo/server-setup/bin/lib/lock.sh"
  chmod +x "$repo/server-setup/bin/check-upstream.sh"
  write_fake_curl "$dir/fakebin"

  printf 'HINDSIGHT_VERSION=%s\n' "$cur" > "$repo/server-setup/version.env"
  : > "$repo/server-setup/base.env"
  printf 'GITHUB_ISSUE_TOKEN=test-token\n' > "$repo/server-setup/secrets.env"
  # Mirrors the real repo's top-level .gitignore: the lock file
  # check-upstream.sh creates must never make git_ready_for_autoupgrade see
  # a dirty working tree on every single run.
  printf 'server-setup/.ops.lock\n' > "$repo/.gitignore"
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
# Scenario: patch available, upgrade.sh exits 2 (upgrade failed but its own
# --auto-rollback succeeded) -> no commit/push, a "...failed (rolled back)"
# issue opened, exit non-zero.
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
echo "pre-upgrade dump (hindsight was already stopped when this was taken): $T9/fake-pre-1.1.0.sql.gz"
echo "fake upgrade.sh: NOT ready after 5 minutes" >&2
echo "AUTO-ROLLBACK OK — hindsight is back on 1.1.0 and healthy (verified version.env + image + /health)." >&2
exit 2
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

[ "$rc9" -eq 1 ] || { echo "$out9"; echo "FAIL: expected check-upstream.sh to exit 1, got $rc9"; exit 1; }
[ "$(git -C "$T9/repo" rev-parse main)" = "$BEFORE_SHA_9" ] \
  || { echo "FAIL: a commit was made on main despite upgrade.sh failing"; exit 1; }
grep -q '"title":"Hindsight auto-upgrade to 1.1.1 failed (rolled back)"' "$CREATED_ISSUE_LOG_9" \
  || { echo "FAIL: missing the failure issue:"; cat "$CREATED_ISSUE_LOG_9"; exit 1; }
grep -q "NOT ready after 5 minutes" "$CREATED_ISSUE_LOG_9" \
  || { echo "FAIL: expected the upgrade.sh log tail inside the failure issue body"; exit 1; }

rm -rf "$T9"
echo "ok - upgrade.sh exit 2 (rolled back OK): no commit/push, failure issue with log tail, non-zero exit"

# ============================================================================
# Scenario: patch available, upgrade.sh exits 3 (upgrade failed AND its own
# --auto-rollback ALSO failed) -> the louder issue, with the pre-upgrade
# dump path and the manual restore command extracted from the log, exit
# non-zero.
# ============================================================================
T10="$(mktemp -d)"
setup_git "$T10" 1.1.0
UPGRADE_LOG_10="$T10/upgrade.log"
CREATED_ISSUE_LOG_10="$T10/created_issue.json"
: > "$UPGRADE_LOG_10"
: > "$CREATED_ISSUE_LOG_10"
cat > "$T10/repo/server-setup/bin/upgrade.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$UPGRADE_LOG_10"
echo "pre-upgrade dump (hindsight was already stopped when this was taken): $T10/fake-pre-1.1.0.sql.gz"
echo "NOT ready after 5 minutes. Check: hs logs hindsight" >&2
echo "ERROR: auto-rollback's restore-db.sh failed — hindsight is left STOPPED. Manual intervention required; pre-upgrade dump: $T10/fake-pre-1.1.0.sql.gz" >&2
exit 3
EOF
chmod +x "$T10/repo/server-setup/bin/upgrade.sh"
git -C "$T10/repo" add -A
git -C "$T10/repo" commit -q -m "add fake upgrade.sh"
git -C "$T10/repo" push -q origin main

BEFORE_SHA_10="$(git -C "$T10/repo" rev-parse main)"
RELEASE_BODY="$(rel_json v1.1.1)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_10"
set +e
out10="$(run_git "$T10" 2>&1)"
rc10=$?
set -e
unset RELEASE_BODY CREATED_ISSUE_LOG

[ "$rc10" -eq 1 ] || { echo "$out10"; echo "FAIL: expected check-upstream.sh to exit 1, got $rc10"; exit 1; }
[ "$(git -C "$T10/repo" rev-parse main)" = "$BEFORE_SHA_10" ] \
  || { echo "FAIL: a commit was made on main despite upgrade.sh failing"; exit 1; }
grep -q '"title":"Hindsight auto-upgrade to 1.1.1 failed AND rollback failed — manual action needed"' "$CREATED_ISSUE_LOG_10" \
  || { echo "FAIL: missing the loud failed+rollback-failed issue:"; cat "$CREATED_ISSUE_LOG_10"; exit 1; }
grep -qF "$T10/fake-pre-1.1.0.sql.gz" "$CREATED_ISSUE_LOG_10" \
  || { echo "FAIL: expected the pre-upgrade dump path inside the issue body:"; cat "$CREATED_ISSUE_LOG_10"; exit 1; }
grep -q "bin/restore-db.sh --yes --no-start" "$CREATED_ISSUE_LOG_10" \
  || { echo "FAIL: expected the manual restore command inside the issue body:"; cat "$CREATED_ISSUE_LOG_10"; exit 1; }

rm -rf "$T10"
echo "ok - upgrade.sh exit 3 (rollback ALSO failed): loud issue with dump path + manual command, non-zero exit"

# ============================================================================
# Scenario: a GitHub API error while listing issues (the dedupe lookup) ->
# no issue created, exit non-zero. Reuses the minor-release path.
# ============================================================================
T11="$(mktemp -d)"
setup_minimal "$T11" 1.1.0
printf 'GITHUB_ISSUE_TOKEN=test-token\n' > "$T11/secrets.env"
CREATED_ISSUE_LOG_11="$T11/created_issue.json"
: > "$CREATED_ISSUE_LOG_11"
RELEASE_BODY="$(rel_json v1.2.0)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_11" ISSUES_LIST_STATUS=500
set +e
out11="$(run_minimal "$T11" 2>&1)"
rc11=$?
set -e
unset RELEASE_BODY CREATED_ISSUE_LOG ISSUES_LIST_STATUS

[ "$rc11" -ne 0 ] || { echo "$out11"; echo "FAIL: expected a non-zero exit when the issue-listing API errors"; exit 1; }
[ -s "$CREATED_ISSUE_LOG_11" ] && { echo "FAIL: an issue was created despite the dedupe lookup failing:"; cat "$CREATED_ISSUE_LOG_11"; exit 1; }
printf '%s\n' "$out11" | grep -qi "listing.*issues.*failed" \
  || { echo "$out11"; echo "FAIL: expected a clear 'listing issues failed' error"; exit 1; }
rm -rf "$T11"
echo "ok - API error on issue listing -> no issue created, non-zero exit"

# ============================================================================
# Scenario: dedupe finds a CLOSED issue on page 2 of the listing -> no
# duplicate created. Page 1 is a full 100-item page of non-matching issues
# (forces find_issue_by_title to continue to page 2); page 2 has the one
# matching issue, closed.
# ============================================================================
T12="$(mktemp -d)"
setup_minimal "$T12" 1.1.0
printf 'GITHUB_ISSUE_TOKEN=test-token\n' > "$T12/secrets.env"
CREATED_ISSUE_LOG_12="$T12/created_issue.json"
: > "$CREATED_ISSUE_LOG_12"

page1_items=""
i=1
while [ "$i" -le 100 ]; do
  page1_items="${page1_items}{\"number\":$i,\"title\":\"filler issue $i\",\"state\":\"open\"},"
  i=$((i + 1))
done
ISSUES_LIST_BODY="[${page1_items%,}]"
# shellcheck disable=SC2089  # literal JSON, only ever read quoted ("$VAR") by the fake curl below
ISSUES_LIST_BODY_PAGE2='[{"number":999,"title":"Hindsight 1.2.0 available (manual upgrade)","state":"closed"}]'

RELEASE_BODY="$(rel_json v1.2.0)"
# shellcheck disable=SC2090  # same: ISSUES_LIST_BODY_PAGE2 is always read quoted, never re-parsed
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_12" ISSUES_LIST_BODY ISSUES_LIST_BODY_PAGE2
out12="$(run_minimal "$T12")"
unset RELEASE_BODY CREATED_ISSUE_LOG ISSUES_LIST_BODY ISSUES_LIST_BODY_PAGE2

printf '%s\n' "$out12" | grep -q "issue #999 already exists" \
  || { echo "$out12"; echo "FAIL: expected the page-2 closed issue #999 to be found and deduped"; exit 1; }
[ -s "$CREATED_ISSUE_LOG_12" ] && { echo "FAIL: a duplicate issue was created despite a closed match on page 2:"; cat "$CREATED_ISSUE_LOG_12"; exit 1; }
grep -q "page=2" "$T12/CURL_ARGV_LOG" || { echo "FAIL: expected find_issue_by_title to actually request page 2"; exit 1; }
rm -rf "$T12"
echo "ok - dedupe finds a closed issue on page 2 -> no duplicate, even across pagination"

# ============================================================================
# Scenario: patch available, upgrade succeeds, but the git push afterward
# FAILS -> a "...but version.env push failed" issue, NOT a rollback
# (nothing to roll back — hindsight is healthy), exit non-zero. The local
# commit still lands (git problem only); only the push to origin fails.
# ============================================================================
T13="$(mktemp -d)"
setup_git "$T13" 1.1.0
UPGRADE_LOG_13="$T13/upgrade.log"
CREATED_ISSUE_LOG_13="$T13/created_issue.json"
: > "$UPGRADE_LOG_13"
: > "$CREATED_ISSUE_LOG_13"
cat > "$T13/repo/server-setup/bin/upgrade.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$UPGRADE_LOG_13"
sed -i 's|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=1.1.1|' "$T13/repo/server-setup/version.env"
echo "fake upgrade.sh: ok"
exit 0
EOF
chmod +x "$T13/repo/server-setup/bin/upgrade.sh"
git -C "$T13/repo" add -A
git -C "$T13/repo" commit -q -m "add fake upgrade.sh"
git -C "$T13/repo" push -q origin main
# Break ONLY the push path: a pre-receive hook on the bare origin that
# rejects every push. `git fetch origin main` (the git_ready_for_autoupgrade
# preflight) is a read-only operation and still succeeds against this same
# origin, so the preflight passes and the run reaches the real commit+push
# step below — pointing origin at a nonexistent path instead would also
# break that preflight fetch and never get this far.
cat > "$T13/origin.git/hooks/pre-receive" <<'HOOKEOF'
#!/bin/sh
echo "rejected by pre-receive hook (simulated push failure)" >&2
exit 1
HOOKEOF
chmod +x "$T13/origin.git/hooks/pre-receive"

BEFORE_SHA_13="$(git -C "$T13/repo" rev-parse main)"
RELEASE_BODY="$(rel_json v1.1.1)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_13"
set +e
out13="$(run_git "$T13" 2>&1)"
rc13=$?
set -e
unset RELEASE_BODY CREATED_ISSUE_LOG

[ "$rc13" -ne 0 ] || { echo "$out13"; echo "FAIL: expected a non-zero exit when the push fails"; exit 1; }
[ "$(git -C "$T13/repo" rev-parse main)" != "$BEFORE_SHA_13" ] \
  || { echo "FAIL: expected the local commit to still land even though the push failed"; exit 1; }
grep -q '"title":"Hindsight auto-upgraded to 1.1.1 but version.env push failed"' "$CREATED_ISSUE_LOG_13" \
  || { echo "FAIL: missing the push-failed issue:"; cat "$CREATED_ISSUE_LOG_13"; exit 1; }
printf '%s\n' "$out13" "$(cat "$CREATED_ISSUE_LOG_13")" | grep -qi "AUTO-ROLLBACK" \
  && { echo "FAIL: a push failure after a healthy upgrade must never mention a rollback"; exit 1; }
# The commit already exists locally (only the push failed) — the fix is
# pull+push, never a second commit. The issue body must say exactly that,
# and must NEVER tell the operator to `git commit` again.
grep -q "pull --rebase origin main" "$CREATED_ISSUE_LOG_13" \
  || { echo "FAIL: expected the issue to say 'git pull --rebase origin main':"; cat "$CREATED_ISSUE_LOG_13"; exit 1; }
grep -qi "do NOT create a second commit\|NEVER.*second commit\|already exists LOCALLY" "$CREATED_ISSUE_LOG_13" \
  || { echo "FAIL: expected the issue to say the commit already exists locally / no second commit:"; cat "$CREATED_ISSUE_LOG_13"; exit 1; }
grep -qi "git commit" "$CREATED_ISSUE_LOG_13" \
  && { echo "FAIL: push-failure recovery text must never instruct a second 'git commit':"; cat "$CREATED_ISSUE_LOG_13"; exit 1; }
rm -rf "$T13"
echo "ok - upgrade succeeds but push fails: push-failed issue, no rollback, no second commit, non-zero exit"

# ============================================================================
# Scenario: python3 missing from PATH -> check-upstream.sh fails loud,
# immediately (before touching network, lock, or anything else).
# ============================================================================
T15="$(mktemp -d)"
setup_minimal "$T15" 1.1.0

# Build a PATH containing nothing but a symlink to the real bash (needed for
# the "#!/usr/bin/env bash" shebang to resolve at all) — not a filtered copy
# of the ambient PATH, which on a system where python3 lives in the same
# directory as bash itself (e.g. both under /usr/bin) would also remove bash
# and fail for the wrong reason ("env: 'bash': No such file or directory").
# `command -v python3` is a bash builtin check that happens before anything
# else external is invoked, so bash alone is enough to reach and fail it.
NO_PY3_BASH="$(command -v bash)"
mkdir -p "$T15/no-py3-bin"
ln -s "$NO_PY3_BASH" "$T15/no-py3-bin/bash"

set +e
out15="$(cd "$T15" && PATH="$T15/no-py3-bin" ./bin/check-upstream.sh </dev/null 2>&1)"
rc15=$?
set -e

[ "$rc15" -ne 0 ] || { echo "$out15"; echo "FAIL: expected a non-zero exit with python3 unavailable"; exit 1; }
printf '%s\n' "$out15" | grep -qi "python3 is required" \
  || { echo "$out15"; echo "FAIL: expected a clear 'python3 is required' message"; exit 1; }
[ -e "$T15/.ops.lock" ] && { echo "FAIL: the lock file was created despite failing before lock acquisition"; exit 1; }
rm -rf "$T15"
echo "ok - missing python3 -> fails loud immediately"

# ============================================================================
# Scenario: the issue-listing API returns HTTP 200 but a malformed/non-array
# body (not valid JSON at all) -> treated as an error, NOT as "0 issues
# found" — no issue created, exit non-zero. Reuses the minor-release path.
# ============================================================================
T16="$(mktemp -d)"
setup_minimal "$T16" 1.1.0
printf 'GITHUB_ISSUE_TOKEN=test-token\n' > "$T16/secrets.env"
CREATED_ISSUE_LOG_16="$T16/created_issue.json"
: > "$CREATED_ISSUE_LOG_16"
RELEASE_BODY="$(rel_json v1.2.0)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_16" ISSUES_LIST_BODY='this is not json at all'
set +e
out16="$(run_minimal "$T16" 2>&1)"
rc16=$?
set -e
unset RELEASE_BODY CREATED_ISSUE_LOG ISSUES_LIST_BODY

[ "$rc16" -ne 0 ] || { echo "$out16"; echo "FAIL: expected a non-zero exit on a malformed issue-list body"; exit 1; }
[ -s "$CREATED_ISSUE_LOG_16" ] && { echo "FAIL: an issue was created despite a malformed issue-list body:"; cat "$CREATED_ISSUE_LOG_16"; exit 1; }
printf '%s\n' "$out16" | grep -qi "malformed" \
  || { echo "$out16"; echo "FAIL: expected a clear 'malformed' error"; exit 1; }
rm -rf "$T16"
echo "ok - malformed/non-array issue-list body -> treated as an error, no issue created"

# ============================================================================
# Scenario: label create returns HTTP 422, but for a reason OTHER than
# "already exists" (e.g. an invalid color) -> must fail, not be treated as
# "the label already exists". Reuses the minor-release path.
# ============================================================================
T17="$(mktemp -d)"
setup_minimal "$T17" 1.1.0
printf 'GITHUB_ISSUE_TOKEN=test-token\n' > "$T17/secrets.env"
CREATED_ISSUE_LOG_17="$T17/created_issue.json"
: > "$CREATED_ISSUE_LOG_17"
RELEASE_BODY="$(rel_json v1.2.0)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_17" LABEL_STATUS=422 \
  LABEL_BODY='{"message":"Validation Failed","errors":[{"resource":"Label","code":"invalid","field":"color"}]}'
set +e
out17="$(run_minimal "$T17" 2>&1)"
rc17=$?
set -e
unset RELEASE_BODY CREATED_ISSUE_LOG LABEL_STATUS LABEL_BODY

[ "$rc17" -ne 0 ] || { echo "$out17"; echo "FAIL: expected a non-zero exit on a non-already_exists 422"; exit 1; }
[ -s "$CREATED_ISSUE_LOG_17" ] && { echo "FAIL: an issue was created despite the label create failing:"; cat "$CREATED_ISSUE_LOG_17"; exit 1; }
printf '%s\n' "$out17" | grep -qi "not 'already_exists'" \
  || { echo "$out17"; echo "FAIL: expected a clear '...not already_exists...' error"; exit 1; }
rm -rf "$T17"
echo "ok - 422 label create NOT already_exists -> fails, no issue created"

# ============================================================================
# Scenario: patch available, upgrade.sh exits 2 but WITHOUT ever taking a
# pre-upgrade dump (simulating a pull/stop/backup failure BEFORE the
# version bump — see bin/upgrade.sh's VERSION_BUMPED=0 recovery path) ->
# the distinct "failed before changing anything (restarted OK)" issue, NOT
# the "(rolled back)" one (there was nothing to roll back), exit non-zero.
# ============================================================================
T18="$(mktemp -d)"
setup_git "$T18" 1.1.0
UPGRADE_LOG_18="$T18/upgrade.log"
CREATED_ISSUE_LOG_18="$T18/created_issue.json"
: > "$UPGRADE_LOG_18"
: > "$CREATED_ISSUE_LOG_18"
cat > "$T18/repo/server-setup/bin/upgrade.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$UPGRADE_LOG_18"
echo "fake upgrade.sh: image pull failed" >&2
echo "hindsight restarted on 1.1.0 and VERIFIED healthy (version.env + image + /health)." >&2
exit 2
EOF
chmod +x "$T18/repo/server-setup/bin/upgrade.sh"
git -C "$T18/repo" add -A
git -C "$T18/repo" commit -q -m "add fake upgrade.sh"
git -C "$T18/repo" push -q origin main

BEFORE_SHA_18="$(git -C "$T18/repo" rev-parse main)"
RELEASE_BODY="$(rel_json v1.1.1)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_18"
set +e
out18="$(run_git "$T18" 2>&1)"
rc18=$?
set -e
unset RELEASE_BODY CREATED_ISSUE_LOG

[ "$rc18" -ne 0 ] || { echo "$out18"; echo "FAIL: expected a non-zero exit"; exit 1; }
[ "$(git -C "$T18/repo" rev-parse main)" = "$BEFORE_SHA_18" ] \
  || { echo "FAIL: a commit was made on main despite upgrade.sh failing before any version bump"; exit 1; }
grep -q '"title":"Hindsight auto-upgrade to 1.1.1 failed before changing anything (restarted OK)"' "$CREATED_ISSUE_LOG_18" \
  || { echo "FAIL: missing the before-bump restarted-OK issue:"; cat "$CREATED_ISSUE_LOG_18"; exit 1; }
grep -qi "rolled back" "$CREATED_ISSUE_LOG_18" \
  && { echo "FAIL: nothing was ever bumped, so this issue must never say 'rolled back':"; cat "$CREATED_ISSUE_LOG_18"; exit 1; }
rm -rf "$T18"
echo "ok - upgrade.sh exit 2 with no pre-upgrade dump -> 'failed before changing anything (restarted OK)' issue"

# ============================================================================
# Scenario: patch available, upgrade succeeds, but the git COMMIT itself
# fails (before any commit exists at all — distinct from T13's push
# failure, where the commit already landed) -> a "...but version.env
# commit failed" issue with instructions to fix git identity/hooks and
# then add+commit+push, NOT the push-failed text. No rollback either way.
# ============================================================================
T19="$(mktemp -d)"
setup_git "$T19" 1.1.0
UPGRADE_LOG_19="$T19/upgrade.log"
CREATED_ISSUE_LOG_19="$T19/created_issue.json"
: > "$UPGRADE_LOG_19"
: > "$CREATED_ISSUE_LOG_19"
cat > "$T19/repo/server-setup/bin/upgrade.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$UPGRADE_LOG_19"
sed -i 's|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=1.1.1|' "$T19/repo/server-setup/version.env"
echo "fake upgrade.sh: ok"
exit 0
EOF
chmod +x "$T19/repo/server-setup/bin/upgrade.sh"
git -C "$T19/repo" add -A
git -C "$T19/repo" commit -q -m "add fake upgrade.sh"
git -C "$T19/repo" push -q origin main
# Break ONLY the commit step: a pre-commit hook on the LOCAL repo that
# rejects every commit (simulating a missing git identity or a rejecting
# hook) — added AFTER the scaffolding commit above, so only the real
# auto-upgrade commit inside check-upstream.sh is ever blocked.
cat > "$T19/repo/.git/hooks/pre-commit" <<'HOOKEOF'
#!/bin/sh
echo "rejected by pre-commit hook (simulated commit failure)" >&2
exit 1
HOOKEOF
chmod +x "$T19/repo/.git/hooks/pre-commit"

BEFORE_SHA_19="$(git -C "$T19/repo" rev-parse main)"
RELEASE_BODY="$(rel_json v1.1.1)"
export RELEASE_BODY CREATED_ISSUE_LOG="$CREATED_ISSUE_LOG_19"
set +e
out19="$(run_git "$T19" 2>&1)"
rc19=$?
set -e
unset RELEASE_BODY CREATED_ISSUE_LOG

[ "$rc19" -ne 0 ] || { echo "$out19"; echo "FAIL: expected a non-zero exit when the commit fails"; exit 1; }
[ "$(git -C "$T19/repo" rev-parse main)" = "$BEFORE_SHA_19" ] \
  || { echo "FAIL: expected NO commit to land — the commit step itself failed"; exit 1; }
grep -q '"title":"Hindsight auto-upgraded to 1.1.1 but version.env commit failed"' "$CREATED_ISSUE_LOG_19" \
  || { echo "FAIL: missing the distinct commit-failed issue:"; cat "$CREATED_ISSUE_LOG_19"; exit 1; }
printf '%s\n' "$out19" "$(cat "$CREATED_ISSUE_LOG_19")" | grep -qi "AUTO-ROLLBACK" \
  && { echo "FAIL: a commit failure after a healthy upgrade must never mention a rollback"; exit 1; }
grep -q "commit -m" "$CREATED_ISSUE_LOG_19" \
  || { echo "FAIL: the commit-failed issue must instruct add+commit+push (there is no commit yet):"; cat "$CREATED_ISSUE_LOG_19"; exit 1; }
grep -qi "git identity\|pre-commit" "$CREATED_ISSUE_LOG_19" \
  || { echo "FAIL: expected a hint about git identity/hooks:"; cat "$CREATED_ISSUE_LOG_19"; exit 1; }
rm -rf "$T19"
echo "ok - git commit itself fails -> distinct 'version.env commit failed' issue, add+commit+push instructions, no rollback"
