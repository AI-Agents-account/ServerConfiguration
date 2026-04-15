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

# Remove NAT rule (best-effort)
iptables -t nat -D POSTROUTING -s "${WG_NET}" -o "${WAN_IF}" -j MASQUERADE 2>/dev/null || true

# Remove policy rule/route (best-effort)
# Note: route table may contain other routes; we only delete the default we added.
ip rule del from "${WG_NET}" table "${TABLE}" priority "${PRIO}" 2>/dev/null || true
ip route del default via "${WAN_GW}" dev "${WAN_IF}" table "${TABLE}" 2>/dev/null || true

echo "[OK] Removed direct egress workaround (best-effort)"
