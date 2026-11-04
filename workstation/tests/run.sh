#!/bin/sh
set -eu

root=$(dirname "$(dirname "$(readlink -f "$0")")")
repo_root=$(dirname "$root")
installer=$root/bin/hindsight-client-setup
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/bin"
export PATH="$scratch/bin:$PATH"
export CALLS="$scratch/calls"
: > "$CALLS"
export ARGV_LOG="$scratch/argv"
export CURL_CONFIG_LOG="$scratch/curl-config"
: > "$ARGV_LOG"
: > "$CURL_CONFIG_LOG"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

cat > "$scratch/bin/curl" <<'EOF'
#!/bin/sh
printf 'curl\0' >> "$ARGV_LOG"
printf '%s\0' "$@" >> "$ARGV_LOG"
printf 'curl %s\n' "$*" >> "$CALLS"
case " $* " in
  *' --config - '*) cat >> "$CURL_CONFIG_LOG";;
esac
if [ "${FAKE_CURL_CODE-}" ]; then
    printf '%s' "$FAKE_CURL_CODE"
    exit 0
fi
case " $* " in
  *'/health'*) printf '200';;
  *'/v1/default/banks'*) printf '200';;
  *) exit 1;;
esac
EOF
cat > "$scratch/bin/claude" <<'EOF'
#!/bin/sh
printf 'claude\0' >> "$ARGV_LOG"
printf '%s\0' "$@" >> "$ARGV_LOG"
printf 'claude %s\n' "$*" >> "$CALLS"
EOF
cat > "$scratch/bin/codex" <<'EOF'
#!/bin/sh
printf 'codex\0' >> "$ARGV_LOG"
printf '%s\0' "$@" >> "$ARGV_LOG"
printf 'codex %s\n' "$*" >> "$CALLS"
EOF
cat > "$scratch/bin/npx" <<'EOF'
#!/bin/sh
set -eu
printf 'npx\0' >> "$ARGV_LOG"
printf '%s\0' "$@" >> "$ARGV_LOG"
printf 'npx %s\n' "$*" >> "$CALLS"
if [ "${FAKE_NPX_FAIL-}" ]; then
    printf 'failed with %s\n' "$HINDSIGHT_API_KEY" >&2
    exit 1
fi
case " $* " in
  *' install '*)
    mkdir -p "$HOME/.claude" "$HOME/.codex"
    printf '{"hooks": {"SessionStart": []}}\n' > "$HOME/.claude/settings.json"
    printf '{"hooks": {"SessionStart": []}}\n' > "$HOME/.codex/hooks.json"
    printf '\n[mcp_servers.hindsight]\ncommand = "node"\n' >> "$HOME/.codex/config.toml"
    claude mcp add --scope user hindsight
    codex mcp add hindsight
    ;;
  *' uninstall '*)
    sed '/^\[mcp_servers.hindsight\]/,/^\[/{ /^\[mcp_servers.hindsight\]/d; /^\[/!d; }' "$HOME/.codex/config.toml" > "$HOME/.codex/config.tmp"
    mv "$HOME/.codex/config.tmp" "$HOME/.codex/config.toml"
    rm -f "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"
    ;;
  *) exit 1;;
esac
EOF
chmod +x "$scratch/bin/"*

export HINDSIGHT_API_KEY='secret-test-key-987'
export HINDSIGHT_BANK='hieu-memory'

"$installer" --dry-run > "$scratch/output" 2>&1 || fail 'dry-run exit'
[ ! -e "$HOME/.config/hindsight/client.env" ] || fail 'dry-run wrote config'
! grep -q "$HINDSIGHT_API_KEY" "$scratch/output" || fail 'dry-run leaked key'
pass 'dry-run leaves HOME untouched and hides key'

mkdir -p "$HOME/.codex"
printf 'model = "gpt-test"\n[features]\nfoo = true\n' > "$HOME/.codex/config.toml"
"$installer" install > "$scratch/output" 2>&1 || fail 'install exit'
[ "$(stat -c %a "$HOME/.config/hindsight/client.env")" = 600 ] || fail 'env permissions'
python3 - "$HOME/.hindsight/coding-agent.json" <<'PY' || fail 'official config'
import json, sys
c = json.load(open(sys.argv[1]))
assert c['serverMode'] == 'self-hosted'
assert c['apiUrl'] == 'https://hindsight-api.hieutk.dev'
assert c['apiToken'] == 'secret-test-key-987'
assert c['bankId'] == 'hieu-memory'
assert c['autoUpdate'] is False
PY
[ -L "$HOME/.claude/skills/setup-hindsight-client" ] || fail 'Claude skill'
[ -L "$HOME/.codex/skills/setup-hindsight-client" ] || fail 'Codex skill'
grep -q 'model = "gpt-test"' "$HOME/.codex/config.toml" || fail 'Codex model lost'
grep -q 'foo = true' "$HOME/.codex/config.toml" || fail 'Codex feature lost'
grep -q '^hooks = true # hindsight-client-setup$' "$HOME/.codex/config.toml" || fail 'Codex hooks not enabled'
grep -q '\[mcp_servers.hindsight\]' "$HOME/.codex/config.toml" || fail 'Codex MCP missing'
grep -q '/health' "$CALLS" || fail 'health not checked'
grep -q '/v1/default/banks' "$CALLS" || fail 'auth not checked'
grep -q "Authorization: Bearer $HINDSIGHT_API_KEY" "$CURL_CONFIG_LOG" || fail 'auth header missing from curl stdin config'
! grep -q "$HINDSIGHT_API_KEY" "$scratch/output" || fail 'install leaked key'
pass 'install configures official integration, preserves Codex config, and verifies API'

before=$(grep -c '^npx ' "$CALLS")
chmod 644 "$HOME/.config/hindsight/client.env"
"$installer" install > "$scratch/output" 2>&1 || fail 'reinstall exit'
after=$(grep -c '^npx ' "$CALLS")
[ "$before" = "$after" ] || fail 'reinstall rewired official integration'
[ "$(stat -c %a "$HOME/.config/hindsight/client.env")" = 600 ] || fail 'reinstall did not protect env file'
pass 'unchanged reinstall is idempotent'

"$installer" --status > "$scratch/output" 2>&1 || fail 'status exit'
! grep -q "$HINDSIGHT_API_KEY" "$scratch/output" || fail 'status leaked key'
pass 'status checks connection without printing key'

export FAKE_CURL_CODE=401
if "$installer" --status > "$scratch/output" 2>&1; then fail '401 should fail'; fi
grep -q 'HTTP 401' "$scratch/output" || fail '401 guidance missing'
! grep -q "$HINDSIGHT_API_KEY" "$scratch/output" || fail '401 leaked key'
unset FAKE_CURL_CODE
pass '401 reports an auth failure without printing key'

"$installer" --uninstall > "$scratch/output" 2>&1 || fail 'uninstall exit'
[ ! -e "$HOME/.claude/skills/setup-hindsight-client" ] || fail 'Claude skill remains'
[ ! -e "$HOME/.codex/skills/setup-hindsight-client" ] || fail 'Codex skill remains'
grep -q 'model = "gpt-test"' "$HOME/.codex/config.toml" || fail 'uninstall changed unrelated config'
! grep -q '^hooks = true # hindsight-client-setup$' "$HOME/.codex/config.toml" || fail 'installer-owned hooks flag remains'
! grep -q "$HINDSIGHT_API_KEY" "$scratch/output" || fail 'uninstall leaked key'
pass 'uninstall removes integration and skill, preserving unrelated config'

export FAKE_NPX_FAIL=1
if "$installer" install > "$scratch/output" 2>&1; then fail 'npx failure should fail'; fi
! grep -q "$HINDSIGHT_API_KEY" "$scratch/output" || fail 'upstream error leaked key'
unset FAKE_NPX_FAIL
pass 'upstream failure cannot echo key'

export HOME="$scratch/home-no-features"
mkdir -p "$HOME/.codex"
printf 'model = "keep-me"\n' > "$HOME/.codex/config.toml"
"$installer" install > "$scratch/output" 2>&1 || fail 'install without features table'
grep -q 'Codex hooks chưa bật' "$scratch/output" || fail 'missing Codex hooks warning'
grep -q 'hooks = true' "$scratch/output" || fail 'Codex hooks fix missing'
pass 'missing Codex features table gives actionable warning'

! grep -aFq "$HINDSIGHT_API_KEY" "$ARGV_LOG" || fail 'secret appeared in child process argv'
pass 'curl, npx, claude, and codex argv never contain the key'

claude_marketplace=$repo_root/.claude-plugin/marketplace.json
codex_marketplace=$repo_root/.agents/plugins/marketplace.json
plugin_dir=$repo_root/plugins/hindsight-client
jq -e '.name == "setup-hindsight" and .plugins[0].name == "hindsight-client" and .plugins[0].source == "./plugins/hindsight-client"' "$claude_marketplace" >/dev/null || fail 'Claude marketplace manifest'
jq -e '.name == "setup-hindsight" and .plugins[0].name == "hindsight-client" and .plugins[0].source.path == "./plugins/hindsight-client"' "$codex_marketplace" >/dev/null || fail 'Codex marketplace manifest'
jq -e '.name == "hindsight-client" and .version == "0.1.1"' "$plugin_dir/.claude-plugin/plugin.json" >/dev/null || fail 'Claude plugin version'
jq -e '.name == "hindsight-client" and .version == "0.1.1"' "$plugin_dir/plugin.json" >/dev/null || fail 'Codex plugin version'
jq -e '.extensions["com.openai"].onboardingSkill == "./skills/setup-hindsight-client/SKILL.md"' "$plugin_dir/plugin.json" >/dev/null || fail 'Codex onboarding path'
[ -f "$plugin_dir/skills/setup-hindsight-client/SKILL.md" ] || fail 'packaged skill missing'
[ -x "$plugin_dir/scripts/hindsight-client-setup" ] || fail 'packaged installer missing'
[ ! -e "$plugin_dir/mcp.json" ] && [ ! -e "$plugin_dir/.mcp.json" ] || fail 'plugin unexpectedly bundles MCP'
pass 'both marketplace manifests parse and reference the packaged skill and installer'

export HOME="$scratch/plugin-home"
mkdir -p "$HOME"
HINDSIGHT_CLIENT_PLUGIN_MODE=1 "$plugin_dir/scripts/hindsight-client-setup" install > "$scratch/output" 2>&1 || fail 'plugin installer exit'
[ ! -e "$HOME/.claude/skills/setup-hindsight-client" ] || fail 'plugin mode duplicated Claude skill'
[ ! -e "$HOME/.codex/skills/setup-hindsight-client" ] || fail 'plugin mode duplicated Codex skill'
pass 'marketplace script uses packaged skill without duplicate symlinks'

printf '11 test cases passed\n'
