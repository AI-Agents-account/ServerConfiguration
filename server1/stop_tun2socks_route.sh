#!/usr/bin/env bash
set -euo pipefail

log() { echo "[stop_tun2socks_route] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

main() {
  require_root

  local iface gw
  iface="$(ip route show default | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  gw="$(ip route show default | awk '/default/ {print $3; exit}')"

  log "Stopping full-tunnel routing and related services..."
  systemctl stop tun2socks-full-routing.service 2>/dev/null || true
  systemctl stop tun2socks-server2.service 2>/dev/null || true
  systemctl stop shadowsocks-libev-local@server2-client.service 2>/dev/null || true

  log "Removing legacy policy-routing remnants if present..."
  ip rule del priority 1000 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true
  nft delete table inet tun2socks 2>/dev/null || true

  log "Restoring direct default route via uplink..."
  ip route del default dev tun0 2>/dev/null || true
  if [[ -n "${gw:-}" && -n "${iface:-}" ]]; then
    ip route replace default via "$gw" dev "$iface" metric 100
  fi

  log "Done. Current public IPv4 should now be server1 direct egress."
  curl -4 -s --max-time 20 https://ifconfig.me || true
  echo
}

main "$@"
