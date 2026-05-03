#!/usr/bin/env bash
# server1/wireguard/setup_split_routing.sh
# Implements RU direct split routing for WireGuard clients.

set -euo pipefail

log() { echo "[wg-split-setup] $*"; }

IPSET_NAME="ru_cidrs"
MARK=0x1
PRIO_MARK=9999
PRIO_WG=10000
WG_IFACE="wg0"
WAN_IFACE="enp3s0"
TUN_IFACE="tun0"
WG_NET="10.66.66.0/24"
TABLE_VPN="vpn-split"

# 1) Ensure ipset is populated
log "Ensuring ipset $IPSET_NAME is populated..."
bash "$(dirname "$0")/update-ru-ipset.sh"

# 2) Configure iptables mangle
log "Applying iptables mangle rules..."
iptables -t mangle -D PREROUTING -i "$WG_IFACE" -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK" 2>/dev/null || true
iptables -t mangle -A PREROUTING -i "$WG_IFACE" -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK"

# 3) Configure ip rules
log "Applying ip rules..."
# Remove problematic global rule if it exists (captured in dump)
ip rule del pref 9001 2>/dev/null || true

# Add RU bypass rule
ip rule del pref "$PRIO_MARK" 2>/dev/null || true
ip rule add pref "$PRIO_MARK" fwmark "$MARK" lookup main

# Ensure WG tunnel rule
ip rule del iif "$WG_IFACE" pref "$PRIO_WG" 2>/dev/null || true
ip rule add iif "$WG_IFACE" pref "$PRIO_WG" lookup "$TABLE_VPN"

# 4) Configure NAT
log "Applying NAT rules..."
# Clean up old MASQUERADE
iptables -t nat -D POSTROUTING -s "$WG_NET" -o "$TUN_IFACE" -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -s "$WG_NET" -o "$WAN_IFACE" -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null || true

# Add new MASQUERADE rules
# RU traffic (marked) -> WAN
iptables -t nat -A POSTROUTING -s "$WG_NET" -o "$WAN_IFACE" -m mark --mark "$MARK" -j MASQUERADE
# Non-RU traffic (unmarked) -> Tunnel
iptables -t nat -A POSTROUTING -s "$WG_NET" -o "$TUN_IFACE" ! --mark "$MARK" -j MASQUERADE

# 5) Create persistence service
log "Creating persistence service /etc/systemd/system/wg-split-routing.service..."
cat > /etc/systemd/system/wg-split-routing.service <<EOF
[Unit]
Description=WireGuard RU Split Routing Persistence
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash -c '\
  ipset create $IPSET_NAME hash:net -! ; \
  iptables -t mangle -C PREROUTING -i $WG_IFACE -m set --match-set $IPSET_NAME dst -j MARK --set-mark $MARK 2>/dev/null || \
  iptables -t mangle -A PREROUTING -i $WG_IFACE -m set --match-set $IPSET_NAME dst -j MARK --set-mark $MARK; \
  ip rule add pref $PRIO_MARK fwmark $MARK lookup main 2>/dev/null || true; \
  ip rule add iif $WG_IFACE pref $PRIO_WG lookup $TABLE_VPN 2>/dev/null || true; \
  iptables -t nat -C POSTROUTING -s $WG_NET -o $WAN_IFACE -m mark --mark $MARK -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s $WG_NET -o $WAN_IFACE -m mark --mark $MARK -j MASQUERADE; \
  iptables -t nat -C POSTROUTING -s $WG_NET -o $TUN_IFACE ! --mark $MARK -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s $WG_NET -o $TUN_IFACE ! --mark $MARK -j MASQUERADE; \
  ip rule del pref 9001 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

# 6) Create update timer
log "Setting up update timer..."
cat > /etc/systemd/system/wg-split-routing-update.service <<EOF
[Unit]
Description=Update RU ipset for WireGuard Split Routing
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash /usr/local/projects/wireguard/update-ru-ipset.sh
EOF

cat > /etc/systemd/system/wg-split-routing-update.timer <<EOF
[Unit]
Description=Daily update of RU ipset

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Ensure script is in the expected location for the service
mkdir -p /usr/local/projects/wireguard/
cp "$(dirname "$0")/update-ru-ipset.sh" /usr/local/projects/wireguard/update-ru-ipset.sh
chmod +x /usr/local/projects/wireguard/update-ru-ipset.sh

systemctl daemon-reload
systemctl enable --now wg-split-routing.service
systemctl enable --now wg-split-routing-update.timer

log "Split routing setup completed."
