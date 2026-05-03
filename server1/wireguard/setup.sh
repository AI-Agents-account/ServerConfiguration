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

INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-7666}"
WG_NET="${WG_NET:-10.66.66.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.66.66.1/24}"
WG_DNS1="${WG_DNS1:-1.1.1.1}"
WG_DNS2="${WG_DNS2:-8.8.8.8}"
CLIENT_NAME="${WG_CLIENT_NAME:-mobile-client}"
TUN_DEV="${WG_EGRESS_DEV:-tun0}"

log "Installing wireguard tools (non-interactive)..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard qrencode

log "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null

mkdir -p /etc/wireguard /root/wireguard-clients
chmod 700 /etc/wireguard /root/wireguard-clients

# Keys
if [[ ! -f /etc/wireguard/server.key ]]; then
  umask 077
  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
fi
SERVER_PRIV=$(cat /etc/wireguard/server.key)
SERVER_PUB=$(cat /etc/wireguard/server.pub)

# Server public IP for endpoint
if [[ -n "${SERVER1_PUBLIC_IP:-}" ]]; then
  SERVER_PUBLIC_IP="${SERVER1_PUBLIC_IP}"
else
  # Try to detect public IP bypassing potential tunnels
  SERVER_PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)
  if [[ -z "$SERVER_PUBLIC_IP" || "$SERVER_PUBLIC_IP" =~ ^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.168\.|^198\.(1[8-9])\. ]]; then
     SERVER_PUBLIC_IP=$(curl -4 -s --interface "$(ip route get 1.1.1.1 | awk '/dev/ {print $5}')" https://api.ipify.org || curl -4 -s https://api.ipify.org)
  fi
fi
log "Using Server Public IP: ${SERVER_PUBLIC_IP}"

# Detect WAN interface (outbound)
WAN_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || echo "eth0")
log "Detected WAN interface: ${WAN_IFACE}"

# Client keys (idempotent)
CLIENT_DIR="/root/wireguard-clients/${CLIENT_NAME}"
mkdir -p "$CLIENT_DIR"
chmod 700 "$CLIENT_DIR"
if [[ ! -f "$CLIENT_DIR/client.key" ]]; then
  umask 077
  wg genkey | tee "$CLIENT_DIR/client.key" | wg pubkey > "$CLIENT_DIR/client.pub"
fi
CLIENT_PRIV=$(cat "$CLIENT_DIR/client.key")
CLIENT_PUB=$(cat "$CLIENT_DIR/client.pub")

# Assign deterministic client IP (first usable)
CLIENT_IP="${WG_CLIENT_IP:-10.66.66.2/32}"

# Write server config
cat > /etc/wireguard/${INTERFACE}.conf <<EOF
[Interface]
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
MTU = 1280

# Forwarding and MSS Clamping (Full Tunnel via ${TUN_DEV})
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_IP}
EOF
chmod 600 /etc/wireguard/${INTERFACE}.conf

# Client config
cat > "$CLIENT_DIR/${CLIENT_NAME}.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}
DNS = ${WG_DNS1}, ${WG_DNS2}
MTU = 1280

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_DIR/${CLIENT_NAME}.conf"

log "Starting wg-quick@${INTERFACE}..."
systemctl enable --now wg-quick@${INTERFACE}

# Ensure UFW allows routing if active
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  log "Configuring UFW route rules for WireGuard..."
  ufw route allow in on "${INTERFACE}" out on "${WAN_IFACE}" 2>/dev/null || true
  ufw route allow in on "${WAN_IFACE}" out on "${INTERFACE}" 2>/dev/null || true
fi

# Policy routing: traffic arriving from wg0 goes to table 2022 default via tun0
log "Applying full-tunnel policy for WireGuard: iif ${INTERFACE} -> ${TUN_DEV}"
WG_IF="${INTERFACE}" TUN_DEV="${TUN_DEV}" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/apply_split_routing.sh"

# QR
qrencode -o "$CLIENT_DIR/${CLIENT_NAME}.png" -t png < "$CLIENT_DIR/${CLIENT_NAME}.conf"

log "WireGuard setup completed. Client files: $CLIENT_DIR/${CLIENT_NAME}.conf and .png"
