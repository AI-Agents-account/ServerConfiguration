#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"

log() { echo "[install_full_tunnel_mode] $*"; }

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
  : "${FULL_TUNNEL_BYPASS_IPS:=}"
}

main() {
  require_root
  load_env

  command -v tun2socks >/dev/null 2>&1 || { echo "ERROR: tun2socks is not installed. Run server1/install_tun2socks_binary.sh first." >&2; exit 1; }
  command -v ss-local >/dev/null 2>&1 || { echo "ERROR: shadowsocks-libev is not installed. Run server1/install_sslocal.sh first." >&2; exit 1; }

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y nftables

  local gw server_ip dns_bypass
  gw="$(ip route show default | awk '/default/ {print $3; exit}')"
  server_ip="$(ip -4 addr show dev "${TUN2SOCKS_IFACE}" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  dns_bypass="$(
    {
      resolvectl dns "${TUN2SOCKS_IFACE}" 2>/dev/null || true
      awk '/^nameserver / {print $2}' /etc/resolv.conf 2>/dev/null || true
    } | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | paste -sd, -
  )"

  [[ -n "$gw" ]] || { echo "ERROR: failed to detect default gateway" >&2; exit 1; }
  [[ -n "$server_ip" ]] || { echo "ERROR: failed to detect server1 IPv4 on ${TUN2SOCKS_IFACE}" >&2; exit 1; }

  cat >/usr/local/sbin/tun2socks-post-up-full.sh <<EOF
#!/usr/bin/env bash
set -e
ip link set ${TUN2SOCKS_TUN_DEV} up mtu ${TUN2SOCKS_MTU}
ip addr replace ${TUN2SOCKS_TUN_ADDR} dev ${TUN2SOCKS_TUN_DEV}
EOF
  chmod 0755 /usr/local/sbin/tun2socks-post-up-full.sh

  cat >/usr/local/sbin/tun2socks-apply-full-routing.sh <<EOF
#!/usr/bin/env bash
set -e
ip route replace default dev ${TUN2SOCKS_TUN_DEV} table 100
ip rule del priority 1000 2>/dev/null || true
ip rule add priority 1000 fwmark 0x1 lookup 100

systemctl enable --now nftables >/dev/null 2>&1 || true
nft list table inet tun2socks >/dev/null 2>&1 || nft add table inet tun2socks
nft flush table inet tun2socks
nft add set inet tun2socks bypass4 '{ type ipv4_addr; flags interval; }'
nft add element inet tun2socks bypass4 '{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.169.0/24, ${TUN_SSIP}/32, ${gw}/32, ${server_ip}/32 }'
EOF

  if [[ -n "$dns_bypass" ]]; then
    cat >>/usr/local/sbin/tun2socks-apply-full-routing.sh <<EOF
nft add element inet tun2socks bypass4 '{ ${dns_bypass} }' || true
EOF
  fi

  if [[ -n "$FULL_TUNNEL_BYPASS_IPS" ]]; then
    cat >>/usr/local/sbin/tun2socks-apply-full-routing.sh <<EOF
nft add element inet tun2socks bypass4 '{ ${FULL_TUNNEL_BYPASS_IPS} }' || true
EOF
  fi

  cat >>/usr/local/sbin/tun2socks-apply-full-routing.sh <<'EOF'
nft 'add chain inet tun2socks output { type route hook output priority mangle; policy accept; }'
nft add rule inet tun2socks output meta mark 0x1 return
nft add rule inet tun2socks output ip daddr @bypass4 return
nft add rule inet tun2socks output tcp sport 22 return
nft add rule inet tun2socks output oifname "lo" return
nft add rule inet tun2socks output meta mark set 0x1
EOF
  chmod 0755 /usr/local/sbin/tun2socks-apply-full-routing.sh

  cat >/etc/systemd/system/tun2socks-server2.service <<EOF
[Unit]
Description=tun2socks client via Shadowsocks server2
After=network-online.target shadowsocks-libev-local@server2-client.service
Wants=network-online.target
Requires=shadowsocks-libev-local@server2-client.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tun2socks -device tun://${TUN2SOCKS_TUN_DEV} -proxy socks5://${LOCAL_SOCKS_ADDR}:${LOCAL_SOCKS_PORT} -interface ${TUN2SOCKS_IFACE} -loglevel info -tun-post-up /usr/local/sbin/tun2socks-post-up-full.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/tun2socks-full-routing.service <<'EOF'
[Unit]
Description=Policy routing for tun2socks full-tunnel mode
After=tun2socks-server2.service
Requires=tun2socks-server2.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tun2socks-apply-full-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now tun2socks-server2.service
  systemctl enable --now tun2socks-full-routing.service

  systemctl --no-pager --full status tun2socks-server2.service || true
  systemctl --no-pager --full status tun2socks-full-routing.service || true

  log "Full-tunnel mode installed. Verify from console first: curl -4 https://ifconfig.me"
}

main "$@"
