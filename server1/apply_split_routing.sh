#!/usr/bin/env bash
set -euo pipefail

# Apply split-routing policy rules for WireGuard clients.
# Goal: route traffic from wg0 into sing-box sbox-tun (table 2022).

WG_IF="${WG_IF:-wg0}"
TUN_DEV="${TUN_DEV:-sbox-tun}"
TABLE_ID="${TABLE_ID:-2022}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need ip

# Ensure table exists in /etc/iproute2/rt_tables
if ! grep -q "^$TABLE_ID " /etc/iproute2/rt_tables 2>/dev/null; then
    echo "$TABLE_ID vpn-split" >> /etc/iproute2/rt_tables || true
fi

# Ensure table has default via tun
if ip link show "$TUN_DEV" >/dev/null 2>&1; then
  ip route replace default dev "$TUN_DEV" table "$TABLE_ID"
  echo "[apply_split_routing] Added default route to table $TABLE_ID via $TUN_DEV"
else
  echo "[apply_split_routing] WARNING: $TUN_DEV not found. Table $TABLE_ID route not applied."
fi

# Route ONLY traffic entering from wg0 into table 2022
if ! ip rule show | grep -q "iif ${WG_IF}.*lookup ${TABLE_ID}"; then
  ip rule add pref 10000 iif "$WG_IF" lookup "$TABLE_ID"
fi

# Ensure IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "[apply_split_routing] OK: iif ${WG_IF} -> table ${TABLE_ID} default via ${TUN_DEV}"
