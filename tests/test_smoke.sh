#!/bin/sh
# bin/smoke.sh must: retain a durable fact and confirm (via
# GET memories/list) that extraction actually kept >=1 memory unit before
# trusting recall; accept any non-empty recall `results` array against this
# freshly-created, isolated bank as proof recall found the fact — never
# requiring a literal substring (an opaque token, or even a specific word
# like "Hanoi") to have survived extraction's paraphrasing; fail with a
# clear message when retain kept 0 units, or when recall's `results` array
# is empty; and in every case — success or failure — always delete the bank
# it created.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"

setup_fixture() {  # setup_fixture <dir>
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
# Scenario 1: success path — list reports 1 memory unit, recall's result
# literally mentions "Hanoi".
# ======================================================================
T1="$(mktemp -d)"
setup_fixture "$T1"

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
  *memories/recall) printf '{"results":[{"text":"The smoke-test user prefers green tea and lives in Hanoi."}]}\n200\n' ;;
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
printf '%s\n' "$out1" | grep -qi "recall result mentions 'Hanoi'" || { echo "$out1"; echo "FAIL: expected the Hanoi-found info line"; exit 1; }
[ "$(wc -l < "$DELETE_LOG_1")" -eq 1 ] || { echo "FAIL: expected exactly one DELETE call on success, got:"; cat "$DELETE_LOG_1"; exit 1; }
rm -rf "$T1"
echo "ok - success path"

# ======================================================================
# Scenario 2: retain extracts 0 memory units -> clear failure, bank deleted.
# ======================================================================
T2="$(mktemp -d)"
setup_fixture "$T2"

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
# Scenario 3: recall paraphrases the fact — no literal token, no literal
# "Hanoi" — but returns a non-empty results array -> smoke still PASSES,
# since this bank is freshly created and isolated, so any result found
# against it must be the fact just retained. This is exactly the case a
# concise extractor can produce on a healthy server.
# ======================================================================
T3="$(mktemp -d)"
setup_fixture "$T3"

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
  *memories/recall) printf '{"results":[{"text":"The user resides in the capital of Vietnam and favors a warm green beverage."}]}\n200\n' ;;
  *memories/list*) printf '{"items":[{"id":"x"}],"total":1,"limit":1,"offset":0}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T3/fakebin/curl"

if ! out3="$(cd "$T3" && PATH="$T3/fakebin:$PATH" ./bin/smoke.sh </dev/null 2>&1)"; then
  echo "$out3"
  echo "FAIL: a paraphrased (but non-empty) recall result must still pass smoke"
  exit 1
fi
printf '%s\n' "$out3" | grep -q "Smoke test OK" || { echo "$out3"; echo "FAIL: missing 'Smoke test OK'"; exit 1; }
printf '%s\n' "$out3" | grep -qi "did not literally contain 'Hanoi'" || { echo "$out3"; echo "FAIL: expected the non-fatal 'Hanoi not found' note"; exit 1; }
[ "$(wc -l < "$DELETE_LOG_3")" -eq 1 ] || { echo "FAIL: expected exactly one DELETE call on success, got:"; cat "$DELETE_LOG_3"; exit 1; }
rm -rf "$T3"
echo "ok - a paraphrased recall result (no literal token/word) still passes"

# ======================================================================
# Scenario 4: recall returns an empty results array -> clear failure, bank
# still deleted.
# ======================================================================
T4="$(mktemp -d)"
setup_fixture "$T4"

DELETE_LOG_4="$T4/delete.log"
: > "$DELETE_LOG_4"
cat > "$T4/fakebin/curl" <<EOF
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
if [ "\$method" = "DELETE" ]; then echo "DELETE \$url" >> "$DELETE_LOG_4"; fi
case "\$url" in
  *memories/recall) printf '{"results": []}\n200\n' ;;
  *memories/list*) printf '{"items":[{"id":"x"}],"total":1,"limit":1,"offset":0}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T4/fakebin/curl"

set +e
out4="$(cd "$T4" && PATH="$T4/fakebin:$PATH" ./bin/smoke.sh </dev/null 2>&1)"
rc4=$?
set -e

[ "$rc4" -ne 0 ] || { echo "$out4"; echo "FAIL: expected smoke.sh to fail when recall returns an empty results array"; exit 1; }
printf '%s\n' "$out4" | grep -q "recall returned 0 results" || { echo "$out4"; echo "FAIL: missing the empty-recall-results message"; exit 1; }
[ "$(wc -l < "$DELETE_LOG_4")" -eq 1 ] || { echo "FAIL: expected exactly one DELETE call after an empty-recall failure, got:"; cat "$DELETE_LOG_4"; exit 1; }
rm -rf "$T4"
echo "ok - empty recall results fails clearly and still deletes the bank"
