#!/usr/bin/env bash
# One-time (idempotent) setup on the server: installs a static rclone
# binary (no sudo), installs the systemd --user units (backup timers,
# restore drill timer, cloudflared tunnel service), checks linger, and
# enables the backup/drill timers.
#
# cloudflared-hindsight.service is installed and enabled but NOT started —
# it needs a tunnel UUID + credentials file that only exists after you've
# created the tunnel by hand (docs/PLAYBOOK.md §4). Start it yourself once
# that's in place: systemctl --user start cloudflared-hindsight
#
# Usage: bin/install-systemd.sh [--dry-run]
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

say() { printf '\n==> %s\n' "$*"; }

run() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

install_rclone() {
  local rclone_bin="${RCLONE_BIN:-$HOME/.local/bin/rclone}"
  say "rclone"
  if [ -x "$rclone_bin" ]; then
    echo "already installed at $rclone_bin: $("$rclone_bin" version | head -1)"
    return
  fi

  local arch rclone_arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) rclone_arch=amd64 ;;
    aarch64 | arm64) rclone_arch=arm64 ;;
    *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
  esac
  local url="https://downloads.rclone.org/rclone-current-linux-${rclone_arch}.zip"

  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] would download $url and install to $rclone_bin"
    return
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL "$url" -o "$tmp/rclone.zip"
  unzip -q "$tmp/rclone.zip" -d "$tmp"
  mkdir -p "$(dirname "$rclone_bin")"
  install -m 755 "$tmp"/rclone-*-linux-"${rclone_arch}"/rclone "$rclone_bin"
  echo "installed: $("$rclone_bin" version | head -1)"
}

install_units() {
  local unit_dir="$HOME/.config/systemd/user"
  say "systemd --user units -> $unit_dir"

  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] would mkdir -p $unit_dir"
  else
    mkdir -p "$unit_dir"
  fi

  local src name
  for src in "$CONFIG_DIR"/systemd/hindsight-backup@.service \
             "$CONFIG_DIR"/systemd/hindsight-backup@6h.timer \
             "$CONFIG_DIR"/systemd/hindsight-backup@daily.timer \
             "$CONFIG_DIR"/systemd/hindsight-backup@weekly.timer \
             "$CONFIG_DIR"/systemd/hindsight-backup@monthly.timer \
             "$CONFIG_DIR"/systemd/hindsight-restore-drill.service \
             "$CONFIG_DIR"/systemd/hindsight-restore-drill.timer \
             "$CONFIG_DIR"/cloudflared/cloudflared-hindsight.service; do
    name="$(basename "$src")"
    if [ "$DRY_RUN" = 1 ]; then
      echo "[dry-run] would install $name -> $unit_dir/$name"
    else
      sed "s|@CONFIG_DIR@|$CONFIG_DIR|g" "$src" > "$unit_dir/$name"
      echo "  $name"
    fi
  done
}

install_cloudflared_config() {
  local dst="$HOME/.cloudflared/hindsight-config.yml"
  say "cloudflared config -> $dst"
  if [ -f "$dst" ]; then
    echo "already exists — leaving it as-is (edit it directly, not the repo template)."
    return
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] would copy cloudflared/config.yml -> $dst"
    return
  fi
  mkdir -p "$HOME/.cloudflared"
  cp "$CONFIG_DIR/cloudflared/config.yml" "$dst"
  echo "copied. Fill in the tunnel UUID + credentials-file path: docs/PLAYBOOK.md §4."
}

check_linger() {
  say "systemd --user linger"
  local user; user="$(whoami)"
  if [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" = "yes" ]; then
    echo "already enabled for $user"
    return
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] would run: loginctl enable-linger $user"
    return
  fi
  if ! loginctl enable-linger "$user" 2>/dev/null; then
    echo "could not enable linger — timers won't survive logout until you run:" >&2
    echo "  sudo loginctl enable-linger $user" >&2
    return 1
  fi
}

enable_timers() {
  say "daemon-reload + enable timers"
  run systemctl --user daemon-reload
  local mode
  for mode in 6h daily weekly monthly; do
    run systemctl --user enable --now "hindsight-backup@${mode}.timer"
  done
  run systemctl --user enable --now hindsight-restore-drill.timer
  # Enabled but not started: needs a tunnel UUID + credentials file created
  # by hand first — see docs/PLAYBOOK.md §4.
  run systemctl --user enable cloudflared-hindsight.service
}

for c in curl unzip docker python3; do
  command -v "$c" >/dev/null || { echo "missing dependency: $c" >&2; exit 1; }
done

LINGER_OK=1
install_rclone
install_units
install_cloudflared_config
check_linger || LINGER_OK=0
enable_timers

if [ "$LINGER_OK" = 0 ]; then
  say "FAILED"
  echo "timers are installed but won't survive logout/reboot — see the linger error above." >&2
  exit 1
fi

say "done"
if [ "$DRY_RUN" = 1 ]; then
  echo "dry run only — nothing was installed or enabled."
else
  echo "check with: systemctl --user list-timers 'hindsight-backup@*' hindsight-restore-drill.timer"
  echo "cloudflared: create the tunnel + credentials file (docs/PLAYBOOK.md §4), then:"
  echo "  systemctl --user start cloudflared-hindsight"
fi
