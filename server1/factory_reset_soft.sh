#!/usr/bin/env bash
set -euo pipefail

# factory_reset_soft.sh
#
# WARNING: DESTRUCTIVE.
# Removes software and configuration installed by this repository on server1.
# Intended to return VPS to a clean state while keeping OS + SSH access.
#
# Usage:
#   sudo bash ./server1/factory_reset_soft.sh

log() { echo "[factory_reset_soft] $*"; }

log "Stopping services (if present)..."
systemctl stop \
  sing-box-server2.service sing-box-vpn.service sing-box.service \
  wg-quick@wg0.service trusttunnel.service hysteria.service \
  nginx.service fail2ban.service docker.service containerd.service \
  2>/dev/null || true

log "Disabling services (if present)..."
systemctl disable \
  sing-box-server2.service sing-box-vpn.service sing-box.service \
  wg-quick@wg0.service trusttunnel.service hysteria.service \
  nginx.service fail2ban.service docker.service containerd.service \
  2>/dev/null || true

log "Removing custom systemd units (if present)..."
rm -f /etc/systemd/system/sing-box-server2.service \
      /etc/systemd/system/sing-box-vpn.service \
      /etc/systemd/system/sing-box.service \
      /etc/systemd/system/hysteria.service \
      /etc/systemd/system/trusttunnel.service \
      2>/dev/null || true
systemctl daemon-reload || true

log "Removing networking artifacts (rules/routes/interfaces)..."
# Policy rules used by our scripts
ip rule del pref 8000 2>/dev/null || true
ip rule del pref 9000 2>/dev/null || true
ip rule del pref 9001 2>/dev/null || true
ip rule del pref 9002 2>/dev/null || true
ip rule del pref 9003 2>/dev/null || true
ip rule del pref 10000 2>/dev/null || true

# Flush our routing table id (2022) if present
ip route flush table 2022 2>/dev/null || true

# Remove TUN interface if it exists
ip link del tun0 2>/dev/null || true
ip link del sbox-tun 2>/dev/null || true

log "Resetting firewall (UFW) to defaults..."
# If ufw exists, wipe its config
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable || true
  ufw --force reset || true
  ufw default allow outgoing || true
  ufw default deny incoming || true
  ufw allow 22/tcp || true
  ufw --force enable || true
fi

log "Purging packages installed/used by this repo..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# VPN / network
apt-get purge -y wireguard wireguard-tools openvpn strongswan qrencode || true

# Web / hardening bundle from vpn_install
apt-get purge -y nginx nginx-common ufw fail2ban certbot python3-certbot python3-acme || true

# Docker (installed by start.sh)
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true

apt-get autoremove -y || true
apt-get autoclean -y || true

log "Removing files and directories created by scripts..."
# sing-box
rm -rf /etc/sing-box /var/lib/sing-box 2>/dev/null || true
rm -f /usr/local/bin/sing-box 2>/dev/null || true

# TrustTunnel
rm -rf /opt/trusttunnel 2>/dev/null || true

# Hysteria / Xray binaries (if present)
rm -f /usr/local/bin/hysteria /usr/local/bin/xray 2>/dev/null || true
rm -rf /etc/hysteria /etc/xray 2>/dev/null || true

# WireGuard
rm -rf /etc/wireguard /root/wireguard-clients 2>/dev/null || true

# Client artifacts
rm -rf /root/vpn_clients 2>/dev/null || true

# Let's Encrypt (created by certbot)
rm -rf /etc/letsencrypt 2>/dev/null || true

# Docker data
rm -rf /var/lib/docker /var/lib/containerd 2>/dev/null || true

# Project downloads
rm -rf /usr/local/projects/wireguard 2>/dev/null || true

log "Done. Reboot is recommended."
log "You can run: sudo reboot"
