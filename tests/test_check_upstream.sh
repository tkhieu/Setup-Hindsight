#!/bin/sh
# Outcome contract for check-upstream.sh; all network and Telegram delivery are faked.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/repo/server-setup/bin/lib" "$T/bin" "$T/home"
cp "$SS/bin/check-upstream.sh" "$T/repo/server-setup/bin/check-upstream.sh"
for f in env.sh json.sh lock.sh; do cp "$SS/bin/lib/$f" "$T/repo/server-setup/bin/lib/$f"; done
cp "$SS/version.env" "$T/repo/server-setup/version.env"
printf 'HINDSIGHT_VERSION=1.1.0\n' > "$T/repo/server-setup/version.env"
: > "$T/repo/server-setup/base.env"
printf 'HINDSIGHT_DB_PASSWORD=SECRET-CANARY\n' > "$T/repo/server-setup/secrets.env"
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *ghcr.io/token*) printf '{"token":"fake"}' ;;
  *ghcr.io/v2/*) printf '%s' "${GHCR_STATUS:-200}" ;;
  *releases/latest*) printf '%s\n%s' "$RELEASE_BODY" "${RELEASE_STATUS:-200}" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/bin/ops-notify" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$NOTIFY_ARGS"
cat >> "$NOTIFY_STDIN"
printf '\n---\n' >> "$NOTIFY_STDIN"
[ "${NOTIFY_FAIL:-0}" = 0 ]
SH
cat > "$T/repo/server-setup/bin/upgrade.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$UPGRADE_LOG"
if [ "${UPGRADE_RC:-0}" = 0 ]; then
  sed -i "s/^HINDSIGHT_VERSION=.*/HINDSIGHT_VERSION=$4/" "$CONFIG_VERSION"
  exit 0
fi
printf '%s\n' "${UPGRADE_MARKER:-RECOVERY_KIND: restarted}"
exit "$UPGRADE_RC"
SH
chmod +x "$T/bin/"* "$T/repo/server-setup/bin/"*.sh
export OPS_NOTIFY_BIN="$T/bin/ops-notify" HOME="$T/home" PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" NOTIFY_ARGS="$T/notify.args" NOTIFY_STDIN="$T/notify.stdin" UPGRADE_LOG="$T/upgrade.log" CONFIG_VERSION="$T/repo/server-setup/version.env"
: > "$CURL_LOG"; : > "$NOTIFY_ARGS"; : > "$NOTIFY_STDIN"; : > "$UPGRADE_LOG"
git init -q -b main "$T/repo"
git -C "$T/repo" config user.email test@example.com
git -C "$T/repo" config user.name Test
git init -q -b main --bare "$T/origin.git"
git -C "$T/repo" remote add origin "$T/origin.git"
printf 'server-setup/.ops.lock\n' > "$T/repo/.gitignore"
git -C "$T/repo" add -A
git -C "$T/repo" commit -qm init
git -C "$T/repo" push -q -u origin main
run() { (cd "$T/repo/server-setup" && ./bin/check-upstream.sh "$@" </dev/null); }
release() { RELEASE_BODY="$(printf '{"tag_name":"v%s","draft":false,"prerelease":false,"html_url":"https://example.test/%s","body":"notes"}' "$1" "$1")"; export RELEASE_BODY; }
reset_logs() { : > "$NOTIFY_ARGS"; : > "$NOTIFY_STDIN"; : > "$UPGRADE_LOG"; }
assert_notice() { grep -Fq -- "--stdin --level $1 --stack hindsight --title $2" "$NOTIFY_ARGS" || { echo "missing notice $1 $2"; cat "$NOTIFY_ARGS"; exit 1; }; }
assert_count() { [ "$(wc -l < "$NOTIFY_ARGS")" -eq "$1" ] || { echo "wrong notifier count"; cat "$NOTIFY_ARGS"; exit 1; }; }
assert_no_secret_argv() { ! grep -Fq SECRET-CANARY "$NOTIFY_ARGS" && ! grep -Fq SECRET-CANARY "$CURL_LOG"; }

release 1.2.0
run --dry-run > "$T/first-dry.out"
[ ! -e "$T/repo/server-setup/.ops.lock" ]
[ ! -e "$HOME/.local/state/hindsight/upgrade-notified" ]
assert_count 0
release 1.1.0
run >/dev/null
release 1.2.0
RELEASE_STATUS=403; export RELEASE_STATUS
if run >"$T/api-error.out" 2>&1; then echo 'expected release lookup failure'; exit 1; fi
assert_count 0
unset RELEASE_STATUS
GHCR_STATUS=404; export GHCR_STATUS
if run >"$T/ghcr-error.out" 2>&1; then echo 'expected missing GHCR tag failure'; exit 1; fi
assert_count 0
unset GHCR_STATUS
assert_count 0
release 1.2.0
run >/dev/null
assert_notice info 'Hindsight 1.2.0 available (manual upgrade)'
grep -Fq 'https://example.test/1.2.0' "$NOTIFY_STDIN"
grep -Fq 'bin/upgrade.sh 1.2.0' "$NOTIFY_STDIN"
[ "$(stat -c %a "$HOME/.local/state/hindsight/upgrade-notified")" = 600 ]
grep -Fxq 'minor 1.2.0' "$HOME/.local/state/hindsight/upgrade-notified"
run >/dev/null
assert_count 1
rm "$HOME/.local/state/hindsight/upgrade-notified"
run >/dev/null
assert_count 2
release 2.0.0
run >/dev/null
assert_notice info 'Hindsight 2.0.0 available (manual upgrade)'
grep -Fxq 'major 2.0.0' "$HOME/.local/state/hindsight/upgrade-notified"
reset_logs
rm "$HOME/.local/state/hindsight/upgrade-notified"
run --dry-run > "$T/dry.out"
grep -q 'would send notification' "$T/dry.out"
[ ! -e "$HOME/.local/state/hindsight/upgrade-notified" ]
assert_count 0
NOTIFY_FAIL=1; export NOTIFY_FAIL
if run >"$T/fail.out" 2>&1; then echo 'missing notification failure exit'; exit 1; fi
grep -q 'ops-notify failed' "$T/fail.out"
[ ! -e "$HOME/.local/state/hindsight/upgrade-notified" ]
unset NOTIFY_FAIL
mv "$T/bin/ops-notify" "$T/bin/ops-notify.off"
if run >"$T/missing.out" 2>&1; then echo 'missing notifier failure exit'; exit 1; fi
grep -q 'ops-notify failed' "$T/missing.out"
mv "$T/bin/ops-notify.off" "$T/bin/ops-notify"
reset_logs
release 1.1.1
UPGRADE_RC=2 UPGRADE_MARKER='RECOVERY_KIND: untouched'; export UPGRADE_RC UPGRADE_MARKER
if run >"$T/untouched.out" 2>&1; then echo 'expected upgrade failure'; exit 1; fi
assert_notice warn 'Hindsight auto-upgrade to 1.1.1 not applied; old version verified running'
if grep -q 'restarted OK' "$NOTIFY_ARGS"; then echo 'untouched outcome claimed restart'; exit 1; fi
reset_logs
UPGRADE_MARKER='RECOVERY_KIND: restarted'; export UPGRADE_MARKER
if run >"$T/restarted.out" 2>&1; then echo 'expected upgrade failure'; exit 1; fi
assert_notice warn 'Hindsight auto-upgrade to 1.1.1 failed before changing anything (restarted OK)'
reset_logs
UPGRADE_MARKER='pre-upgrade dump: /tmp/fake.sql.gz'; export UPGRADE_MARKER
if run >"$T/rolled.out" 2>&1; then echo 'expected upgrade failure'; exit 1; fi
assert_notice warn 'Hindsight auto-upgrade to 1.1.1 failed (rolled back)'
reset_logs
UPGRADE_RC=3; export UPGRADE_RC
if run >"$T/rollback-fail.out" 2>&1; then echo 'expected upgrade failure'; exit 1; fi
assert_notice error 'Hindsight auto-upgrade to 1.1.1 failed AND rollback failed — manual action needed'
grep -Fq '/tmp/fake.sql.gz' "$NOTIFY_STDIN"
reset_logs
UPGRADE_MARKER='RECOVERY_KIND: untouched'; export UPGRADE_MARKER
if run >"$T/unverified.out" 2>&1; then echo 'expected upgrade failure'; exit 1; fi
assert_notice error 'Hindsight auto-upgrade to 1.1.1 not applied; old version could not be verified — manual action needed'
reset_logs
UPGRADE_MARKER='RECOVERY_KIND: restarted'; export UPGRADE_MARKER
if run >"$T/restart-fail.out" 2>&1; then echo 'expected upgrade failure'; exit 1; fi
assert_notice error 'Hindsight auto-upgrade to 1.1.1 failed before changing anything AND the restart could not be verified — manual action needed'
reset_logs
NOTIFY_FAIL=1; export NOTIFY_FAIL
if run >"$T/no-rollback.out" 2>&1; then echo 'expected upgrade failure'; exit 1; fi
[ "$(wc -l < "$UPGRADE_LOG")" -eq 1 ]
grep -q 'ops-notify failed' "$T/no-rollback.out"
unset NOTIFY_FAIL UPGRADE_RC UPGRADE_MARKER
reset_logs
# Repo safety gate sends a warning; no upgrade is attempted.
printf x > "$T/repo/dirty"
if run >"$T/dirty.out" 2>&1; then echo 'expected dirty repo failure'; exit 1; fi
assert_notice warn 'Hindsight 1.1.1 available but auto-upgrade blocked (repo not clean)'
[ ! -s "$UPGRADE_LOG" ]
rm "$T/repo/dirty"
reset_logs
# A failing git commit has its own warning and no push/rollback.
cat > "$T/repo/.git/hooks/pre-commit" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$T/repo/.git/hooks/pre-commit"
if run >"$T/commit-fail.out" 2>&1; then echo 'expected commit failure'; exit 1; fi
assert_notice warn 'Hindsight auto-upgraded to 1.1.1 but version.env commit failed'
[ "$(wc -l < "$UPGRADE_LOG")" -eq 1 ]
rm "$T/repo/.git/hooks/pre-commit"
git -C "$T/repo" reset -q --hard origin/main
reset_logs
# A rejected push leaves the local bump commit intact, with a distinct warning.
cat > "$T/origin.git/hooks/pre-receive" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$T/origin.git/hooks/pre-receive"
if run >"$T/push-fail.out" 2>&1; then echo 'expected push failure'; exit 1; fi
assert_notice warn 'Hindsight auto-upgraded to 1.1.1 but version.env push failed'
[ "$(wc -l < "$UPGRADE_LOG")" -eq 1 ]
rm "$T/origin.git/hooks/pre-receive"
git -C "$T/repo" reset -q --hard origin/main
reset_logs
run > "$T/ok.out"
assert_notice info 'Hindsight auto-upgraded to 1.1.1'
grep -Fq -- '--yes --auto-rollback --smoke 1.1.1' "$UPGRADE_LOG"
git --git-dir="$T/origin.git" show main:server-setup/version.env | grep -q '^HINDSIGHT_VERSION=1.1.1$'
assert_no_secret_argv
reset_logs
release 1.1.2
NOTIFY_FAIL=1; export NOTIFY_FAIL
if run >"$T/healthy-notify-fail.out" 2>&1; then echo 'expected notification failure exit'; exit 1; fi
assert_notice info 'Hindsight auto-upgraded to 1.1.2'
[ "$(wc -l < "$UPGRADE_LOG")" -eq 1 ]
git --git-dir="$T/origin.git" show main:server-setup/version.env | grep -q '^HINDSIGHT_VERSION=1.1.2$'
grep -q 'ops-notify failed' "$T/healthy-notify-fail.out"
unset NOTIFY_FAIL
printf 'ok - release dedupe, dry-run, notifier failures, recovery outcomes, repo gate, patch success, and argv safety\n'
