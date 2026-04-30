#!/usr/bin/env bash
set -euo pipefail
echo "[install_vpn_clients] Installing VPN clients: wireguard-tools, openvpn, strongswan..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools openvpn strongswan
echo "[install_vpn_clients] VPN clients installed."
