#!/usr/bin/env bash
set -euo pipefail

WG_NET="${WG_NET:-10.66.66.0/24}"
WAN_IF="${WAN_IF:-enp3s0}"
WAN_GW="${WAN_GW:-176.109.104.1}"
TABLE="${TABLE:-100}"
PRIO="${PRIO:-1000}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need ip
need iptables

# 1) policy routing for WG subnet
if ! ip rule show | grep -q "from ${WG_NET} lookup ${TABLE}"; then
  ip rule add from "${WG_NET}" table "${TABLE}" priority "${PRIO}"
fi

if ! ip route show table "${TABLE}" | grep -q "^default"; then
  ip route add default via "${WAN_GW}" dev "${WAN_IF}" table "${TABLE}"
fi

# 2) NAT WG subnet out via WAN
if ! iptables -t nat -C POSTROUTING -s "${WG_NET}" -o "${WAN_IF}" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "${WG_NET}" -o "${WAN_IF}" -j MASQUERADE
fi

echo "[OK] Applied direct egress workaround for WireGuard clients"
echo "  WG_NET=${WG_NET}"
echo "  WAN_IF=${WAN_IF}"
echo "  WAN_GW=${WAN_GW}"
echo "  TABLE=${TABLE} PRIO=${PRIO}"

echo "--- ip rule (filtered) ---"
ip rule show | grep -E "lookup (${TABLE}|main|default|local)" || true

echo "--- table ${TABLE} routes ---"
ip route show table "${TABLE}" || true

echo "--- nat POSTROUTING ---"
iptables -t nat -L POSTROUTING -n -v --line-numbers | sed -n '1,120p'
