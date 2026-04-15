#!/usr/bin/env bash
set -euo pipefail

WG_NET="${WG_NET:-10.66.66.0/24}"
WAN_IF="${WAN_IF:-}"
WAN_GW="${WAN_GW:-}"
TABLE="${TABLE:-100}"
PRIO="${PRIO:-1000}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }
need ip
need iptables
need awk

# Auto-detect WAN interface / gateway if not provided
if [[ -z "$WAN_IF" ]]; then
  WAN_IF="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
fi
if [[ -z "$WAN_GW" ]]; then
  WAN_GW="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {print $3; exit}')"
fi

# Remove NAT rule (best-effort)
if [[ -n "$WAN_IF" ]]; then
  iptables -t nat -D POSTROUTING -s "${WG_NET}" -o "${WAN_IF}" -j MASQUERADE 2>/dev/null || true
fi

# Remove policy rule/route (best-effort)
ip rule del from "${WG_NET}" table "${TABLE}" priority "${PRIO}" 2>/dev/null || true
if [[ -n "$WAN_GW" && -n "$WAN_IF" ]]; then
  ip route del default via "${WAN_GW}" dev "${WAN_IF}" table "${TABLE}" 2>/dev/null || true
fi

echo "[OK] Removed direct egress workaround (best-effort)"
