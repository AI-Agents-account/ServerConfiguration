#!/usr/bin/env bash
set -euo pipefail

log() { echo "[restart_tun2socks_route] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

main() {
  require_root

  log "Reloading systemd units..."
  systemctl daemon-reload

  log "Starting Shadowsocks local client..."
  systemctl enable --now shadowsocks-libev-local@server2-client.service

  log "Starting tun2socks..."
  systemctl enable --now tun2socks-server2.service

  log "Re-applying full-tunnel policy routing..."
  systemctl enable --now tun2socks-full-routing.service

  log "Service states:"
  systemctl --no-pager --full status shadowsocks-libev-local@server2-client.service || true
  systemctl --no-pager --full status tun2socks-server2.service || true
  systemctl --no-pager --full status tun2socks-full-routing.service || true

  log "Done. Current public IPv4 should now be server2 egress."
  curl -4 -s --max-time 20 https://ifconfig.me || true
  echo
}

main "$@"
