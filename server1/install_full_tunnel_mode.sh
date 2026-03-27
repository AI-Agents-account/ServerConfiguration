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

  local gw server_ip dns_bypass ssh_bypass
  gw="$(ip route show default | awk '/default/ {print $3; exit}')"
  server_ip="$(ip -4 addr show dev "${TUN2SOCKS_IFACE}" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  dns_bypass="$(
    {
      resolvectl dns "${TUN2SOCKS_IFACE}" 2>/dev/null || true
      awk '/^nameserver / {print $2}' /etc/resolv.conf 2>/dev/null || true
    } | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | sort -u | paste -sd, -
  )"
  ssh_bypass="$(
    (
      ss -tn state established '( sport = :22 )' 2>/dev/null \
        | awk 'NR>1 {print $5}' \
        | sed 's/\[//; s/\]//; s/:[0-9][0-9]*$//' \
        | grep -E '^[0-9]+(\.[0-9]+){3}$' \
        | sort -u | paste -sd, -
    ) || true
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

# Clean up remnants from the old policy-routing mode if they exist.
ip rule del priority 1000 2>/dev/null || true
ip route flush table 100 2>/dev/null || true
nft delete table inet tun2socks 2>/dev/null || true

# Keep direct reachability to the uplink, Shadowsocks server, active SSH peers,
# and selected bypass destinations via the real gateway on ${TUN2SOCKS_IFACE}.
ip route replace ${gw}/32 dev ${TUN2SOCKS_IFACE}
ip route replace ${TUN_SSIP}/32 via ${gw} dev ${TUN2SOCKS_IFACE}
ip route replace 169.254.169.0/24 dev ${TUN2SOCKS_IFACE} || true
EOF

  if [[ -n "$dns_bypass" ]]; then
    IFS=',' read -r -a DNS_BYPASS_ARR <<< "$dns_bypass"
    for dns_ip in "${DNS_BYPASS_ARR[@]}"; do
      [[ -n "$dns_ip" ]] || continue
      cat >>/usr/local/sbin/tun2socks-apply-full-routing.sh <<EOF
ip route replace ${dns_ip}/32 via ${gw} dev ${TUN2SOCKS_IFACE} || true
EOF
    done
  fi

  if [[ -n "$ssh_bypass" ]]; then
    IFS=',' read -r -a SSH_BYPASS_ARR <<< "$ssh_bypass"
    for ssh_ip in "${SSH_BYPASS_ARR[@]}"; do
      [[ -n "$ssh_ip" ]] || continue
      cat >>/usr/local/sbin/tun2socks-apply-full-routing.sh <<EOF
ip route replace ${ssh_ip}/32 via ${gw} dev ${TUN2SOCKS_IFACE} || true
EOF
    done
  fi

  if [[ -n "$FULL_TUNNEL_BYPASS_IPS" ]]; then
    IFS=',' read -r -a FULL_BYPASS_ARR <<< "$FULL_TUNNEL_BYPASS_IPS"
    for bypass_ip in "${FULL_BYPASS_ARR[@]}"; do
      bypass_ip="${bypass_ip// /}"
      [[ -n "$bypass_ip" ]] || continue
      cat >>/usr/local/sbin/tun2socks-apply-full-routing.sh <<EOF
ip route replace ${bypass_ip} via ${gw} dev ${TUN2SOCKS_IFACE} || true
EOF
    done
  fi

  cat >>/usr/local/sbin/tun2socks-apply-full-routing.sh <<EOF
# Main routing model for universal ingress use-cases:
# prefer tun0 for all traffic, keep eth0 as lower-priority fallback.
ip route replace default dev ${TUN2SOCKS_TUN_DEV} metric 50
ip route replace default via ${gw} dev ${TUN2SOCKS_IFACE} metric 200
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
