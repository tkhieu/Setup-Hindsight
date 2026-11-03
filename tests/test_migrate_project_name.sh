#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/server-setup/bin" "$TMP/fake"
cp "$SS/bin/migrate-project-name.sh" "$TMP/server-setup/bin/"
cat > "$TMP/server-setup/bin/hs" <<'EOF'
#!/bin/sh
printf 'hs %s\n' "$*" >> "$FAKE_LOG"
EOF
cat > "$TMP/server-setup/bin/backup.sh" <<'EOF'
#!/bin/sh
printf 'backup %s\n' "$*" >> "$FAKE_LOG"
EOF
cat > "$TMP/fake/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$FAKE_LOG"
case "$1 $2" in
  'info '*|'compose version') exit 0 ;;
  'volume inspect')
    case "$*" in
      *hindsight_pgdata*|*hindsight_hf_cache*|*hindsight_chatgpt_credentials*) exit 1 ;;
    esac
    case "$*" in
      *com.docker.compose.project*) echo server-setup ;;
      *com.docker.compose.volume*)
        case "$*" in
          *chatgpt_credentials*) echo chatgpt_credentials ;;
          *hf_cache*) echo hf_cache ;;
          *pgdata*) echo pgdata ;;
        esac ;;
    esac
    exit 0 ;;
  'inspect --format')
    case "$*" in
      *com.docker.compose.project.working_dir*)
        if [ "${FAKE_MISMATCH:-0}" = 1 ]; then echo /other/server-setup; else echo "$FAKE_CONFIG_DIR"; fi ;;
      *com.docker.compose.project*) echo server-setup ;;
      *com.docker.compose.service*)
        case "$*" in *-db-1*) echo db ;; *) echo hindsight ;; esac ;;
      *State.Running*) echo true ;;
      *Mounts*)
        case "$*" in
          *-db-1*) echo server-setup_pgdata ;;
          *) printf '%s\n' server-setup_hf_cache server-setup_chatgpt_credentials ;;
        esac ;;
    esac
    exit 0 ;;
  'volume create'|'stop '*|'rm '*|'run '*) exit 0 ;;
esac
echo "unexpected docker call: $*" >&2
exit 1
EOF
chmod +x "$TMP/fake/docker" "$TMP/server-setup/bin/"*
export PATH="$TMP/fake:$PATH" FAKE_LOG="$TMP/log" FAKE_CONFIG_DIR="$TMP/server-setup"
SCRIPT="$TMP/server-setup/bin/migrate-project-name.sh"

FAKE_MISMATCH=1; export FAKE_MISMATCH
if "$SCRIPT" --yes >"$TMP/out" 2>&1; then echo 'accepted foreign container'; exit 1; fi
grep -q 'belongs to another directory' "$TMP/out"
if grep -Eq '^(backup|docker (stop|rm|run|volume create)) ' "$TMP/log"; then exit 1; fi

: > "$TMP/log"
FAKE_MISMATCH=0; export FAKE_MISMATCH
"$SCRIPT" --dry-run >"$TMP/out"
grep -q 'Dry run' "$TMP/out"
if grep -Eq '^(backup|hs|docker (stop|rm|run|volume create)) ' "$TMP/log"; then exit 1; fi

: > "$TMP/log"
"$SCRIPT" --yes >"$TMP/out"
grep -q 'Migration complete' "$TMP/out"
awk '/^backup / { b=NR } /^docker stop / { if (!b || NR <= b) exit 1; found=1 } END { if (!found) exit 1 }' "$TMP/log"
[ "$(grep -c '^docker run ' "$TMP/log")" -eq 3 ]
[ "$(grep -c '^docker volume create ' "$TMP/log")" -eq 3 ]
for key in pgdata hf_cache chatgpt_credentials; do
  grep -q "server-setup_$key:/from:ro" "$TMP/log"
  grep -q "hindsight_$key:/to" "$TMP/log"
done
if grep -E 'hub|agentgateway|cloudflared|server-setup_default|volume rm|compose down|remove-orphans' "$TMP/log"; then exit 1; fi
[ "$(grep -c '^docker rm ' "$TMP/log")" -eq 2 ]
grep -q '^docker rm server-setup-db-1$' "$TMP/log"
grep -q '^docker rm server-setup-hindsight-1$' "$TMP/log"
echo ok
