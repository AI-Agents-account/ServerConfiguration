#!/usr/bin/env bash
set -euo pipefail

# Apply split-routing policy rules for WireGuard clients.
# Goal: route ONLY forwarded traffic from wg0 into sing-box tun0 (table 2022),
# while keeping host-originated traffic (incl. sing-box direct outbound) on main routing table.

WG_IF="${WG_IF:-wg0}"
TUN_DEV="${TUN_DEV:-tun0}"
TABLE_ID="${TABLE_ID:-2022}"

# Shadowsocks server2 IP must stay reachable via WAN even when table 2022 is used.
SS_SERVER_IP="${TUN_SSIP:-${SS_SERVER:-}}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need ip

# Ensure tun exists
ip link show "$TUN_DEV" >/dev/null 2>&1 || {
  echo "ERROR: $TUN_DEV not found (sing-box tun inbound not up?)" >&2
  exit 3
}

# Ensure table has default via tun
ip route replace default dev "$TUN_DEV" table "$TABLE_ID"

# Exception: server2 IP via WAN
if [[ -n "$SS_SERVER_IP" ]]; then
  gw="$(ip route show default | awk '/default/ {print $3; exit}')"
  iface="$(ip route show default | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  if [[ -n "$gw" && -n "$iface" ]]; then
    ip route replace "${SS_SERVER_IP}/32" via "$gw" dev "$iface" table "$TABLE_ID" || true
  fi
fi

# Route ONLY traffic entering from wg0 into table 2022
# Idempotent add:
if ! ip rule show | grep -q "iif ${WG_IF}.*lookup ${TABLE_ID}"; then
  ip rule add pref 10000 iif "$WG_IF" lookup "$TABLE_ID"
fi

# Also route packets to the tun subnet (local) via table 2022 (safe)
if ! ip rule show | grep -q "to 172\.19\.0\.0/30.*lookup ${TABLE_ID}"; then
  ip rule add pref 9000 to 172.19.0.0/30 lookup "$TABLE_ID"
fi

echo "[apply_split_routing] OK: iif ${WG_IF} -> table ${TABLE_ID} default via ${TUN_DEV} (SS exception applied if set)"
