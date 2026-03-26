#!/usr/bin/env bash
set -euo pipefail

# Expects EnvironmentFile=/etc/default/tun2socks
: "${SSIP:?}"
: "${IFACE:?}"
: "${TUNDEV:?}"

MIP=$(ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
if [[ -z "${MIP}" ]]; then
  echo "[tun2socks-poststart] ERROR: cannot detect default gateway (MIP)" >&2
  exit 1
fi

LIP=$(ip -4 addr show dev "${IFACE}" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
if [[ -z "${LIP}" ]]; then
  echo "[tun2socks-poststart] ERROR: cannot detect local IPv4 on IFACE=${IFACE}" >&2
  exit 1
fi

# Ensure primary route via IFACE exists as fallback
ip route del default dev "${IFACE}" 2>/dev/null || true
ip route replace default via "${MIP}" dev "${IFACE}" metric 200

# Policy routing table for local IP
ip rule add from "${LIP}" table lip 2>/dev/null || true
ip route replace default via "${MIP}" dev "${IFACE}" table lip

# Route to SS server directly via IFACE (so we don't tunnel the tunnel)
ip route replace "${SSIP}/32" via "${MIP}" dev "${IFACE}"

# Also keep DNS resolvers reachable via IFACE.
# Otherwise DNS may try to go through tun2socks (often UDP) and hang.
while read -r ns; do
  [[ -n "${ns}" ]] || continue
  ip route replace "${ns}/32" via "${MIP}" dev "${IFACE}" || true
done < <(awk '/^nameserver/{print $2}' /etc/resolv.conf | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

# Primary default route via tun
ip route replace default dev "${TUNDEV}" metric 50
