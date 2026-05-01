#!/usr/bin/env bash
set -euo pipefail

# wireguard/setup.sh
# Opinionated WireGuard setup for ServerConfiguration environments where the VPS egress may be full-tunneled
# through a separate interface (e.g. tun0 from tun2socks).
#
# Goals:
# - WireGuard server on UDP :7666 (configurable)
# - IPv4-only client routing by default (recommended)
# - Client traffic can egress via a chosen interface (default: tun0)
# - Provide a stable DNS for clients via dnsmasq on 10.66.66.1 and allow it in UFW on wg0
#
# Usage:
#   sudo bash wireguard/setup.sh [client_name]
#

CLIENT_NAME="${1:-greenapple}"
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-7666}"
WG_NET="${WG_NET:-10.66.66.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.66.66.1/24}"
# NOTE: do not hardcode WG_CLIENT_IP for every client. Default is computed dynamically per-client.
WG_CLIENT_IP_DEFAULT="10.66.66.2/32"
EGRESS_IF="${EGRESS_IF:-tun0}"  # set to enp3s0 if you want direct egress
DNS_LISTEN_IP="${DNS_LISTEN_IP:-10.66.66.1}"
DNS_UPSTREAM1="${DNS_UPSTREAM1:-8.8.8.8}"
# Use existing port if wg0.conf already exists, otherwise use environment or default
if [[ -f "/etc/wireguard/${WG_IF}.conf" ]]; then
  EXISTING_PORT=$(grep -i "^ListenPort" "/etc/wireguard/${WG_IF}.conf" | awk '{print $3}')
  if [[ -n "$EXISTING_PORT" ]]; then
    echo "[wireguard] Using existing ListenPort: $EXISTING_PORT"
    WG_PORT="$EXISTING_PORT"
  fi
fi

main() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)." >&2
    exit 1
  fi
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 2
  }
}

main() {
  require_root

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y wireguard iptables dnsmasq ca-certificates curl

  need wg
  need wg-quick
  need ip
  need iptables

  # Enable IPv4 forwarding
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # Detect public IP for client endpoint (best-effort)
  SERVER_PUBLIC_IP="$(ip -4 addr show | awk '/inet / && $2 !~ /^127\./ {print $2}' | cut -d/ -f1 | head -n1)"

  # Keys
  umask 077
  SERVER_PRIV="$(wg genkey)"
  SERVER_PUB="$(printf "%s" "$SERVER_PRIV" | wg pubkey)"
  CLIENT_PRIV="$(wg genkey)"
  CLIENT_PUB="$(printf "%s" "$CLIENT_PRIV" | wg pubkey)"
  PSK="$(wg genpsk)"

  install -d -m 0700 /etc/wireguard

  # If interface config already exists, we MUST NOT regenerate server keys.
  if [[ -f "/etc/wireguard/${WG_IF}.conf" ]]; then
    echo "[wireguard] ${WG_IF}.conf exists; adding a new peer (idempotent)" >&2
    SERVER_PRIV="$(sudo awk -F' = ' '/^PrivateKey =/ {print $2; exit}' "/etc/wireguard/${WG_IF}.conf")"
    SERVER_PUB="$(printf "%s" "$SERVER_PRIV" | wg pubkey)"
    # Pick next free client IP in 10.66.66.0/24 starting from .2
    USED="$(sudo awk -F' = ' '/^AllowedIPs = 10\.66\.66\./ {print $2}' "/etc/wireguard/${WG_IF}.conf" | cut -d/ -f1 | tr '\n' ' ')"
    ip=2
    while echo "$USED" | tr ' ' '\n' | grep -qx "10.66.66.${ip}"; do ip=$((ip+1)); done
    WG_CLIENT_IP="10.66.66.${ip}/32"
    # Append new peer
    cat >>"/etc/wireguard/${WG_IF}.conf" <<EOF

[Peer]
# Client: ${CLIENT_NAME}
PublicKey = ${CLIENT_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${WG_CLIENT_IP}
EOF
  else
    WG_CLIENT_IP="${WG_CLIENT_IP:-${WG_CLIENT_IP_DEFAULT}}"
    # wg0.conf (first-time setup)
    cat >"/etc/wireguard/${WG_IF}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
# Bypass sing-box auto_route for WireGuard's own UDP packets
FwMark = 0x1

# Allow WireGuard handshake
PostUp = iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT

# Forwarding rules
PostUp = iptables -I FORWARD -i ${WG_IF} -j ACCEPT
PostUp = iptables -I FORWARD -i ${EGRESS_IF} -o ${WG_IF} -j ACCEPT

# NAT client subnet out via EGRESS_IF (tun0 for "through tunnel" mode)
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${EGRESS_IF} -j MASQUERADE

# MTU/fragmentation helper for TCP
PostUp = iptables -t mangle -A FORWARD -i ${WG_IF} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

PostDown = iptables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${WG_IF} -j ACCEPT
PostDown = iptables -D FORWARD -i ${EGRESS_IF} -o ${WG_IF} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${EGRESS_IF} -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -i ${WG_IF} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

[Peer]
# Client: ${CLIENT_NAME}
PublicKey = ${CLIENT_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${WG_CLIENT_IP}
EOF
  fi

  chmod 600 "/etc/wireguard/${WG_IF}.conf"

  # dnsmasq: stable DNS for WG clients (avoid UDP DNS reliability issues through full-tunnel)
  cat >/etc/dnsmasq.d/${WG_IF}.conf <<EOF
# WireGuard DNS for clients
interface=${WG_IF}
listen-address=${DNS_LISTEN_IP}
bind-interfaces
port=53

no-resolv
server=${DNS_UPSTREAM1}
server=${DNS_UPSTREAM2}

domain-needed
bogus-priv
EOF


  # UFW rules (best-effort; if ufw is not installed, skip)
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${WG_PORT}/udp" || true
    # Allow DNS to server over wg interface
    ufw allow in on ${WG_IF} to any port 53 proto udp || true
    ufw allow in on ${WG_IF} to any port 53 proto tcp || true
    ufw --force enable || true
  fi

  systemctl enable --now "wg-quick@${WG_IF}"
  systemctl restart "wg-quick@${WG_IF}"
  systemctl enable --now dnsmasq
  systemctl restart dnsmasq || true

  # Client config
  install -d -m 0700 /root/wireguard-clients
  CLIENT_PATH="/root/wireguard-clients/${WG_IF}-client-${CLIENT_NAME}.conf"
  cat >"${CLIENT_PATH}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_CLIENT_IP}
DNS = ${DNS_LISTEN_IP}

# Recommended on mobile networks:
# PersistentKeepalive = 25
# MTU = 1280

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  chmod 600 "${CLIENT_PATH}"

  echo "========================================================="
  echo "✅ WireGuard configured."
  echo "Interface: ${WG_IF} (UDP:${WG_PORT})"
  echo "Egress interface for clients: ${EGRESS_IF}"
  echo "Client config: ${CLIENT_PATH}"
  echo "========================================================="
}

main "$@"
