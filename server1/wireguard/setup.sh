#!/usr/bin/env bash
set -euo pipefail

# This script installs WireGuard and configures policy routing to send 
# its traffic through the unified sing-box VPN server for split-routing.

ENV_FILE="${1:-server1/wireguard.env}"

log() { echo "[wg-setup] $*"; }

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# 1) Download/Verify angristan script
INSTALLER="/usr/local/projects/wireguard/wireguard-install.sh"
if [[ ! -x "$INSTALLER" ]]; then
  log "Downloading installer..."
  mkdir -p "$(dirname "$INSTALLER")"
  curl -fsSL "https://raw.githubusercontent.com/Nyr/wireguard-install/master/wireguard-install.sh" -o "$INSTALLER"
  chmod +x "$INSTALLER"
fi

# 2) Pre-seed installer answers
export INTERFACE="${WG_INTERFACE:-wg0}"
# Hard requirement: WireGuard must ALWAYS listen on UDP 7666
export PORT="7666"
export PROTOCOL="1" # UDP (hard-pinned)
export EXTERNAL_IP="${SERVER1_PUBLIC_IP:-$(curl -s https://api.ipify.org)}"
export IP6="${WG_IP6:-n}"
export DNS1="${WG_DNS1:-10.66.66.1}"
export DNS2="${WG_DNS2:-8.8.8.8}"

if ! command -v wg >/dev/null; then
    log "Running WireGuard installer..."
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a; echo -e "\n\n\n\n\n\n\n\n\nmobile-client\n1\n\n\n" | "$INSTALLER"
else
    log "WireGuard is already installed."
fi

# 3) Post-install: Adjust routing to send wg0 traffic through sing-box TUN
log "Configuring policy routing for $INTERFACE -> sbox-tun..."

sysctl -w net.ipv4.ip_forward=1 >/dev/null

TABLE_ID=2022
if ! grep -q "^$TABLE_ID " /etc/iproute2/rt_tables 2>/dev/null; then
    echo "$TABLE_ID vpn-split" >> /etc/iproute2/rt_tables || true
fi

ip rule del iif "$INTERFACE" table $TABLE_ID 2>/dev/null || true
ip rule add iif "$INTERFACE" table $TABLE_ID

if ip link show sbox-tun >/dev/null 2>&1; then
    ip route replace default dev sbox-tun table $TABLE_ID
    log "Route added: default via sbox-tun in table $TABLE_ID"
else
    log "Warning: sbox-tun not found. Route to table $TABLE_ID will be added by sing-box on start."
fi

# Firewall
iptables -C FORWARD -i "$INTERFACE" -o sbox-tun -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$INTERFACE" -o sbox-tun -j ACCEPT
iptables -C FORWARD -i sbox-tun -o "$INTERFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i sbox-tun -o "$INTERFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

log "WireGuard setup completed."
