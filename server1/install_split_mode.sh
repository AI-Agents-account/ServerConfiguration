#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"

log() { echo "[install_split_mode] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "ERROR: env file not found: $ENV_FILE" >&2; exit 1; }
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a

  : "${TUN_SSIP:?TUN_SSIP is required}"
  : "${LOCAL_SOCKS_ADDR:=127.0.0.1}"
  : "${LOCAL_SOCKS_PORT:=1080}"
  : "${TUN2SOCKS_IFACE:=$(ip route show default | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')}"
  : "${TUN2SOCKS_TUN_DEV:=tun0}"
  : "${TUN2SOCKS_TUN_ADDR:=198.18.0.1/15}"
  : "${TUN2SOCKS_MTU:=1500}"
  
  : "${SPLIT_FWMARK:=0x65}"
  : "${SPLIT_RU_NETS_FILE:=/etc/server1-split/ru_nets.txt}"
  : "${SPLIT_DIRECT_NETS_FILE:=/etc/server1-split/direct_nets.txt}"
}

main() {
  require_root
  load_env

  command -v tun2socks >/dev/null 2>&1 || { echo "ERROR: tun2socks is not installed. Run server1/install_tun2socks_binary.sh first." >&2; exit 1; }
  command -v ss-local >/dev/null 2>&1 || { echo "ERROR: shadowsocks-libev is not installed. Run server1/install_sslocal.sh first." >&2; exit 1; }

  log "Installing dependencies (nftables, ipset)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y nftables ipset

  local gw server_ip
  gw="$(ip route show default | awk '/default/ {print $3; exit}')"
  server_ip="$(ip -4 addr show dev "${TUN2SOCKS_IFACE}" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"

  [[ -n "$gw" ]] || { echo "ERROR: failed to detect default gateway" >&2; exit 1; }
  [[ -n "$server_ip" ]] || { echo "ERROR: failed to detect server1 IPv4 on ${TUN2SOCKS_IFACE}" >&2; exit 1; }

  log "Creating tun2socks-post-up script..."
  cat >/usr/local/sbin/tun2socks-post-up-split.sh <<EOF
#!/usr/bin/env bash
set -e
ip link set ${TUN2SOCKS_TUN_DEV} up mtu ${TUN2SOCKS_MTU}
ip addr replace ${TUN2SOCKS_TUN_ADDR} dev ${TUN2SOCKS_TUN_DEV}
EOF
  chmod 0755 /usr/local/sbin/tun2socks-post-up-split.sh

  log "Configuring policy routing tables..."
  install -d -m 0755 /etc/iproute2/rt_tables.d
  echo '201 tun' >/etc/iproute2/rt_tables.d/91-tun-split.conf

  log "Creating split-routing application script..."
  cat >/usr/local/sbin/tun2socks-apply-split-routing.sh <<EOF
#!/usr/bin/env bash
set -e

log() { echo "[apply_split] \$*"; }

# 1. Clean up old routing rules/routes (idempotency)
ip rule del priority 1100 fwmark ${SPLIT_FWMARK} lookup tun 2>/dev/null || true
ip route flush table tun 2>/dev/null || true

# Clean up possible full-tunnel remnants that would interfere
ip route del default dev ${TUN2SOCKS_TUN_DEV} metric 50 2>/dev/null || true

# 2. Setup table 'tun'
ip route replace default dev ${TUN2SOCKS_TUN_DEV} table tun

# 3. Add policy rule
ip rule add priority 1100 fwmark ${SPLIT_FWMARK} lookup tun

# 4. IPSET management
ipset create SC_RU_NETS hash:net -exist
ipset create SC_DIRECT_NETS hash:net -exist

ipset flush SC_RU_NETS
ipset flush SC_DIRECT_NETS

# Load RU_NETS
if [[ -f "${SPLIT_RU_NETS_FILE}" ]]; then
  log "Loading RU nets from ${SPLIT_RU_NETS_FILE}"
  while read -r net; do
    net="\${net%%#*}"
    net="\${net// /}"
    [[ -n "\$net" ]] || continue
    ipset add SC_RU_NETS "\$net" -exist
  done <"${SPLIT_RU_NETS_FILE}"
fi

# Load DIRECT_NETS
if [[ -f "${SPLIT_DIRECT_NETS_FILE}" ]]; then
  log "Loading DIRECT nets from ${SPLIT_DIRECT_NETS_FILE}"
  while read -r net; do
    net="\${net%%#*}"
    net="\${net// /}"
    [[ -n "\$net" ]] || continue
    ipset add SC_DIRECT_NETS "\$net" -exist
  done <"${SPLIT_DIRECT_NETS_FILE}"
fi

# Add default direct bypasses (gateway, SS server)
ipset add SC_DIRECT_NETS "${gw}/32" -exist
ipset add SC_DIRECT_NETS "${TUN_SSIP}/32" -exist
ipset add SC_DIRECT_NETS "169.254.169.0/24" -exist

# 5. NFTABLES configuration
# We use a dedicated table to avoid mess with existing rules
nft list table inet sc_split >/dev/null 2>&1 || nft add table inet sc_split

# Mark chain
nft "add chain inet sc_split mark_for_tun { type route hook output priority mangle; policy accept; }"
nft flush chain inet sc_split mark_for_tun

# Rules:
# Skip SSH ingress/egress to self
nft add rule inet sc_split mark_for_tun ip daddr ${server_ip} tcp dport 22 return
# Skip Direct nets (via WAN)
nft add rule inet sc_split mark_for_tun ip daddr @SC_DIRECT_NETS return
# Skip RU nets (via WAN)
nft add rule inet sc_split mark_for_tun ip daddr @SC_RU_NETS return
# Mark everything else for tun
nft add rule inet sc_split mark_for_tun meta mark set ${SPLIT_FWMARK}

# Also handle forwarded traffic (e.g. from WireGuard wg0)
nft "add chain inet sc_split mark_for_tun_fwd { type filter hook prerouting priority mangle; policy accept; }" 2>/dev/null || true
nft flush chain inet sc_split mark_for_tun_fwd
nft add rule inet sc_split mark_for_tun_fwd ip daddr ${server_ip} return
nft add rule inet sc_split mark_for_tun_fwd ip daddr @SC_DIRECT_NETS return
nft add rule inet sc_split mark_for_tun_fwd ip daddr @SC_RU_NETS return
nft add rule inet sc_split mark_for_tun_fwd iifname "wg0" meta mark set ${SPLIT_FWMARK}
nft add rule inet sc_split mark_for_tun_fwd iifname "tun0" return

# Block IPv6 egress to prevent leaks and timeouts since tun0 is IPv4 only
nft "add chain inet sc_split block_ipv6_out { type filter hook output priority filter; policy accept; }" 2>/dev/null || true
nft flush chain inet sc_split block_ipv6_out
nft add rule inet sc_split block_ipv6_out meta nfproto ipv6 fib daddr type != { local, multicast } reject
nft "add chain inet sc_split block_ipv6_fwd { type filter hook forward priority filter; policy accept; }" 2>/dev/null || true
nft flush chain inet sc_split block_ipv6_fwd
nft add rule inet sc_split block_ipv6_fwd meta nfproto ipv6 reject

log "Split-routing rules applied."
EOF
  chmod 0755 /usr/local/sbin/tun2socks-apply-split-routing.sh

  log "Creating systemd services..."
  cat >/etc/systemd/system/tun2socks-server2.service <<EOF
[Unit]
Description=tun2socks client via Shadowsocks server2
After=network-online.target shadowsocks-libev-local@server2-client.service
Wants=network-online.target
Requires=shadowsocks-libev-local@server2-client.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tun2socks -device tun://${TUN2SOCKS_TUN_DEV} -proxy socks5://${LOCAL_SOCKS_ADDR}:${LOCAL_SOCKS_PORT} -interface ${TUN2SOCKS_IFACE} -loglevel info -tun-post-up /usr/local/sbin/tun2socks-post-up-split.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/tun2socks-split-routing.service <<'EOF'
[Unit]
Description=Policy routing for tun2socks split-routing mode
After=tun2socks-server2.service
Requires=tun2socks-server2.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tun2socks-apply-split-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  log "Ensuring config directory exists..."
  mkdir -p "$(dirname "$SPLIT_RU_NETS_FILE")"
  touch "$SPLIT_RU_NETS_FILE" "$SPLIT_DIRECT_NETS_FILE"

  log "Enabling and starting services..."
  systemctl daemon-reload
  systemctl enable --now tun2socks-server2.service
  systemctl enable --now tun2socks-split-routing.service

  log "Split-routing mode installed. Verify with: curl -4 https://ifconfig.me"
}

main "$@"
