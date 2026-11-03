#!/usr/bin/env bash
# One-time migration from the shared server-setup Compose project.
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HS="$CONFIG_DIR/bin/hs"
OLD=server-setup
NEW=hindsight
VOLUMES=(pgdata hf_cache chatgpt_credentials)
YES=0

die() { echo "migrate-project-name: $*" >&2; exit 1; }
label() { docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null; }
volume_label() { docker volume inspect --format "{{index .Labels \"$2\"}}" "$1" 2>/dev/null; }
volume_exists() { docker volume inspect "$1" >/dev/null 2>&1; }

case "${1:---dry-run}" in
  --yes) YES=1 ;;
  --dry-run) ;;
  *) die "usage: bin/migrate-project-name.sh [--dry-run|--yes]" ;;
esac
[ "$#" -le 1 ] || die "usage: bin/migrate-project-name.sh [--dry-run|--yes]"
command -v docker >/dev/null || die "docker is missing"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
docker compose version >/dev/null 2>&1 || die "Docker Compose is unavailable"

# A successful rerun is a read-only check. Any partial target set is refused:
# the operator can inspect it before deciding whether to resume or roll back.
target_count=0
for key in "${VOLUMES[@]}"; do
  target="${NEW}_${key}"
  if volume_exists "$target"; then
    [ "$(volume_label "$target" com.docker.compose.project)" = "$NEW" ] || die "$target has unexpected project label"
    [ "$(volume_label "$target" com.docker.compose.volume)" = "$key" ] || die "$target has unexpected volume label"
    target_count=$((target_count + 1))
  fi
done
if [ "$target_count" -gt 0 ]; then
  [ "$target_count" -eq 3 ] || die "partial target volumes exist; inspect before retrying"
  for service in db hindsight; do
    cid="${NEW}-${service}-1"
    [ "$(label "$cid" com.docker.compose.project)" = "$NEW" ] || die "$cid is not a completed migration"
    [ "$(label "$cid" com.docker.compose.project.working_dir)" = "$CONFIG_DIR" ] || die "$cid belongs to another directory"
    [ "$(label "$cid" com.docker.compose.service)" = "$service" ] || die "$cid has unexpected service label"
    [ "$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null)" = true ] || die "$cid is not running"
  done
  COMPOSE_PROJECT_NAME="$NEW" "$HS" ready >/dev/null || die "new stack is not healthy"
  echo "Migration already complete; old volumes remain untouched."
  exit 0
fi

for service in db hindsight; do
  cid="${OLD}-${service}-1"
  [ "$(label "$cid" com.docker.compose.project)" = "$OLD" ] || die "$cid has unexpected project label"
  [ "$(label "$cid" com.docker.compose.project.working_dir)" = "$CONFIG_DIR" ] || die "$cid belongs to another directory"
  [ "$(label "$cid" com.docker.compose.service)" = "$service" ] || die "$cid has unexpected service label"
  [ "$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null)" = true ] || die "$cid must be running for the backup"
done
for key in "${VOLUMES[@]}"; do
  source="${OLD}_${key}"
  volume_exists "$source" || die "$source is missing"
  [ "$(volume_label "$source" com.docker.compose.project)" = "$OLD" ] || die "$source has unexpected project label"
  [ "$(volume_label "$source" com.docker.compose.volume)" = "$key" ] || die "$source has unexpected volume label"
done

# Docker Compose puts working_dir on containers, not on named volumes. Confirm
# each source volume is mounted by the already-verified Hindsight container.
for key in "${VOLUMES[@]}"; do
  service=hindsight
  [ "$key" = pgdata ] && service=db
  mounts="$(docker inspect --format '{{range .Mounts}}{{println .Name}}{{end}}' "${OLD}-${service}-1")"
  grep -Fxq "${OLD}_${key}" <<< "$mounts" || die "${OLD}_${key} is not mounted by our $service container"
done

echo "Preflight OK: source containers and three volumes belong to $CONFIG_DIR."
if [ "$YES" -eq 0 ]; then
  echo "Dry run: would back up, stop/remove only ${OLD}-db-1 and ${OLD}-hindsight-1, copy three volumes, start $NEW, then check /health."
  exit 0
fi

# The old project is selected only for the database dump; no project-wide
# stop/down/removal command is ever issued against the shared project.
COMPOSE_PROJECT_NAME="$OLD" "$CONFIG_DIR/bin/backup.sh" project-name-migration
for service in hindsight db; do
  cid="${OLD}-${service}-1"
  docker stop "$cid"
  docker rm "$cid"
done
for key in "${VOLUMES[@]}"; do
  source="${OLD}_${key}"
  target="${NEW}_${key}"
  docker volume create --label "com.docker.compose.project=$NEW" --label "com.docker.compose.volume=$key" "$target" >/dev/null
  docker run --rm -v "$source:/from:ro" -v "$target:/to" alpine:3.20 sh -c 'cp -a /from/. /to/'
done
COMPOSE_PROJECT_NAME="$NEW" "$HS" up -d
COMPOSE_PROJECT_NAME="$NEW" "$HS" ready

cat <<'EOF'
Migration complete. Verify: bin/hs ps; bin/hs ready; bin/smoke.sh;
bin/restore-db.sh --drill r2:latest; docker ps (hindsight-* names).
Check OneAIHub containers are still running. Old volumes and the shared
server-setup_default network are retained. For rollback: stop/remove only
hindsight-db-1 and hindsight-hindsight-1 after checking their working_dir
labels, then run COMPOSE_PROJECT_NAME=server-setup bin/hs up -d and bin/hs ready.
After independent verification and a backup, old-volume cleanup is exactly:
docker volume rm server-setup_pgdata server-setup_hf_cache server-setup_chatgpt_credentials
EOF
