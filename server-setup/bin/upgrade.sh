#!/usr/bin/env bash
# Safe upgrade. Usage: bin/upgrade.sh 1.2.0
# (no leading "v" — matches version.env; see its comment on why the
# published image tag drops the "v" that the upstream git tag has)
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC1091
. "$CONFIG_DIR/bin/lib/env.sh"
HS="$CONFIG_DIR/bin/hs"
NEW="${1:?usage: upgrade.sh <target-version>, e.g. 1.2.0}"

# Guards against a typo/garbage argument being embedded verbatim into sed
# below (this doubles as the rollback text).
[[ "$NEW" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "invalid version: $NEW" >&2; exit 1; }

CUR="$(env_get "$CONFIG_DIR/version.env" HINDSIGHT_VERSION)"
[ -n "$CUR" ] || { echo "missing HINDSIGHT_VERSION in $CONFIG_DIR/version.env" >&2; exit 1; }

set -a
# shellcheck disable=SC1091
. "$CONFIG_DIR/base.env"
set +a

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ask() { read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }

[ "$CUR" != "$NEW" ] || { echo "already at $NEW."; exit 0; }

say "1/6 Local backup (the only rollback path — migrations are forward-only)"
backup_out="$("$CONFIG_DIR/bin/backup.sh" "pre-$NEW")"
echo "$backup_out"
PRE_DUMP="$(env_get <(printf '%s\n' "$backup_out") BACKUP_PREFIX)-db.sql.gz"
[ -f "$PRE_DUMP" ] || { echo "couldn't determine the pre-upgrade dump path — aborting before touching anything." >&2; exit 1; }
echo "pre-upgrade dump: $PRE_DUMP"

if [ -f "$CONFIG_DIR/secrets.env" ]; then
  say "1b/6 R2 6h snapshot (best-effort — upgrade continues even if this fails)"
  "$CONFIG_DIR/bin/backup-r2.sh" 6h || echo "R2 backup failed/skipped — the local backup above still covers rollback." >&2
else
  echo
  echo "no secrets.env — skipping R2 snapshot (local backup above still covers rollback)."
fi

say "2/6 Changes $CUR -> $NEW"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh api "repos/vectorize-io/hindsight/compare/v$CUR...v$NEW" \
    --jq '.commits[] | .sha[0:7] + "  " + (.commit.message | split("\n")[0])' 2>/dev/null \
    || echo "(couldn't fetch the commit diff via gh — check https://github.com/vectorize-io/hindsight/releases manually)"
else
  echo "(gh not available/authenticated — check https://github.com/vectorize-io/hindsight/releases manually)"
fi

echo
ask "Diff above OK — continue upgrading $CUR -> $NEW?" || { echo "aborted (nothing changed yet)."; exit 1; }

say "3/6 Pull target image ($NEW) before changing anything"
# Via shell env override (Compose gives shell env precedence over
# --env-file for interpolation), NOT version.env yet: a bad version or
# network failure here leaves the running stack and version.env untouched,
# so there is nothing to roll back and no trap is needed above this line.
HINDSIGHT_VERSION="$NEW" "$HS" pull hindsight

# From here on, state changes on disk/in the stack — arm the rollback
# printer so ANY failure (this script exiting for any reason before the
# final "success" line) prints exact recovery commands.
FAILED=1
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

Step 3 fetches nothing (it's already a local path), verifies the dump,
takes its own extra pre-restore backup, recreates the database, and leaves
hindsight stopped either way — it will say clearly if the restore itself
failed, in which case do not proceed to step 4.
TXT
}
trap '[ "$FAILED" = 1 ] && print_rollback' EXIT

say "4/6 Bump version.env"
sed -i "s|^HINDSIGHT_VERSION=.*|HINDSIGHT_VERSION=$NEW|" "$CONFIG_DIR/version.env"
grep -E '^HINDSIGHT_VERSION=' "$CONFIG_DIR/version.env"

say "5/6 Up"
"$HS" up -d

say "6/6 Waiting for ready (up to 5 min)"
if ! HINDSIGHT_READY_TIMEOUT=300 "$HS" ready; then
  echo "NOT ready after 5 minutes. Check: hs logs hindsight" >&2
  exit 1
fi

FAILED=0
cat <<TXT

Upgraded $CUR -> $NEW.

Two things left:
  1. Commit + push version.env:
       git add server-setup/version.env && git commit -m "chore: bump hindsight to $NEW" && git push
  2. Smoke test: bin/smoke.sh

Pre-upgrade dump kept at: $PRE_DUMP
TXT
