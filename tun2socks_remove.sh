#!/usr/bin/env bash
set -euo pipefail

log() { echo "[tun2socks_remove.sh] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

main() {
  require_root

  log "Stopping and disabling tun2socks service (if exists)..."
  systemctl stop tun2socks 2>/dev/null || true
  systemctl disable tun2socks 2>/dev/null || true

  log "Removing systemd unit (if exists)..."
  rm -f /etc/systemd/system/tun2socks.service
  systemctl daemon-reload || true
  systemctl reset-failed || true

  log "Removing binaries (if exist)..."
  rm -f /usr/local/bin/tun2socks
  rm -f /usr/local/bin/tun2socks-poststart.sh

  # Some deployments may have a local copy
  rm -f /usr/local/ServerConfiguration/tun2socks 2>/dev/null || true

  log "Cleaning up network artifacts (best-effort)..."
  ip link delete tun0 2>/dev/null || true
  ip rule del table lip 2>/dev/null || true
  ip route flush table lip 2>/dev/null || true
  ip route del default dev tun0 2>/dev/null || true

  log "Removing /etc/tun2socks (if exists)..."
  rm -rf /etc/tun2socks 2>/dev/null || true

  log "Done."
}

main "$@"
