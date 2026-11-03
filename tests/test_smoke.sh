#!/bin/sh
# bin/smoke.sh must: retain a durable fact and confirm (via
# GET memories/list) that extraction actually kept >=1 memory unit before
# trusting recall; fail with a clear message (not a generic HTTP error) when
# extraction kept 0; fail when recall doesn't surface the fact; and in every
# case — success or failure — always delete the bank it created.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"

setup_fixture() {  # setup_fixture <dir> <list_total_json> <recall_results_json>
  dir="$1"
  mkdir -p "$dir/bin" "$dir/fakebin"
  cp "$SS/bin/smoke.sh" "$dir/bin/smoke.sh"
  chmod +x "$dir/bin/smoke.sh"

  cat > "$dir/bin/hs" <<'EOF'
#!/bin/sh
case "$1" in
  url) echo "http://127.0.0.1:8888" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$dir/bin/hs"

  cat > "$dir/base.env" <<'EOF'
HINDSIGHT_DB_USER=hindsight_user
HINDSIGHT_DB_NAME=hindsight_db
EOF
  cat > "$dir/secrets.env" <<'EOF'
HINDSIGHT_API_TENANT_API_KEY=test-key-not-a-real-secret
EOF
}

# ======================================================================
# Scenario 1: success path — list reports 1 memory unit, recall finds it.
# ======================================================================
T1="$(mktemp -d)"
setup_fixture "$T1" "" ""

DELETE_LOG_1="$T1/delete.log"
: > "$DELETE_LOG_1"
cat > "$T1/fakebin/curl" <<EOF
#!/bin/sh
cat >/dev/null
url=""
method=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-X" ]; then method="\$a"; fi
  url="\$a"
  prev="\$a"
done
if [ "\$method" = "DELETE" ]; then echo "DELETE \$url" >> "$DELETE_LOG_1"; fi
case "\$url" in
  *memories/recall)
    token=\$(printf '%s' "\$*" | grep -o 'Smoketest[0-9x]*' | head -1)
    printf '{"results":[{"text":"Smoke-test user %s prefers green tea and lives in Hanoi."}]}\n200\n' "\$token" ;;
  *memories/list*) printf '{"items":[{"id":"x"}],"total":1,"limit":1,"offset":0}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T1/fakebin/curl"

if ! out1="$(cd "$T1" && PATH="$T1/fakebin:$PATH" ./bin/smoke.sh </dev/null 2>&1)"; then
  echo "$out1"
  echo "FAIL: success scenario expected smoke.sh to exit 0"
  exit 1
fi
printf '%s\n' "$out1" | grep -q "Smoke test OK" || { echo "$out1"; echo "FAIL: missing 'Smoke test OK'"; exit 1; }
[ "$(wc -l < "$DELETE_LOG_1")" -eq 1 ] || { echo "FAIL: expected exactly one DELETE call on success, got:"; cat "$DELETE_LOG_1"; exit 1; }
rm -rf "$T1"
echo "ok - success path"

# ======================================================================
# Scenario 2: retain extracts 0 memory units -> clear failure, bank deleted.
# ======================================================================
T2="$(mktemp -d)"
setup_fixture "$T2" "" ""

DELETE_LOG_2="$T2/delete.log"
: > "$DELETE_LOG_2"
cat > "$T2/fakebin/curl" <<EOF
#!/bin/sh
cat >/dev/null
url=""
method=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-X" ]; then method="\$a"; fi
  url="\$a"
  prev="\$a"
done
if [ "\$method" = "DELETE" ]; then echo "DELETE \$url" >> "$DELETE_LOG_2"; fi
case "\$url" in
  *memories/list*) printf '{"items":[],"total":0,"limit":1,"offset":0}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T2/fakebin/curl"

set +e
out2="$(cd "$T2" && PATH="$T2/fakebin:$PATH" ./bin/smoke.sh </dev/null 2>&1)"
rc2=$?
set -e

[ "$rc2" -ne 0 ] || { echo "$out2"; echo "FAIL: expected smoke.sh to fail when retain extracted 0 units"; exit 1; }
printf '%s\n' "$out2" | grep -q "retain extracted 0 facts" || { echo "$out2"; echo "FAIL: missing the 'retain extracted 0 facts' message"; exit 1; }
[ "$(wc -l < "$DELETE_LOG_2")" -eq 1 ] || { echo "FAIL: expected exactly one DELETE call after a 0-units failure, got:"; cat "$DELETE_LOG_2"; exit 1; }
rm -rf "$T2"
echo "ok - retain 0 units fails clearly and still deletes the bank"

# ======================================================================
# Scenario 3: recall misses the fact -> failure, bank still deleted.
# ======================================================================
T3="$(mktemp -d)"
setup_fixture "$T3" "" ""

DELETE_LOG_3="$T3/delete.log"
: > "$DELETE_LOG_3"
cat > "$T3/fakebin/curl" <<EOF
#!/bin/sh
cat >/dev/null
url=""
method=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-X" ]; then method="\$a"; fi
  url="\$a"
  prev="\$a"
done
if [ "\$method" = "DELETE" ]; then echo "DELETE \$url" >> "$DELETE_LOG_3"; fi
case "\$url" in
  *memories/recall) printf '{"results":[{"text":"something unrelated"}]}\n200\n' ;;
  *memories/list*) printf '{"items":[{"id":"x"}],"total":1,"limit":1,"offset":0}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T3/fakebin/curl"

set +e
out3="$(cd "$T3" && PATH="$T3/fakebin:$PATH" ./bin/smoke.sh </dev/null 2>&1)"
rc3=$?
set -e

[ "$rc3" -ne 0 ] || { echo "$out3"; echo "FAIL: expected smoke.sh to fail when recall misses the fact"; exit 1; }
printf '%s\n' "$out3" | grep -q "recall did not surface the fact" || { echo "$out3"; echo "FAIL: missing the recall-miss message"; exit 1; }
[ "$(wc -l < "$DELETE_LOG_3")" -eq 1 ] || { echo "FAIL: expected exactly one DELETE call after a recall-miss failure, got:"; cat "$DELETE_LOG_3"; exit 1; }
rm -rf "$T3"
echo "ok - recall miss fails clearly and still deletes the bank"
