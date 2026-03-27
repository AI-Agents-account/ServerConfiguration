#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"

log() { echo "[install_safe_mode] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "ERROR: env file not found: $ENV_FILE" >&2; exit 1; }
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$ENV_FILE" | xargs -d '\n' || true)

  : "${LOCAL_SOCKS_ADDR:=127.0.0.1}"
  : "${LOCAL_SOCKS_PORT:=1080}"
  : "${TUN2SOCKS_IFACE:=$(ip route show default | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')}"
  : "${TUN2SOCKS_TUN_DEV:=tun0}"
  : "${TUN2SOCKS_TUN_ADDR:=198.18.0.1/15}"
  : "${TUN2SOCKS_MTU:=1500}"
}

main() {
  require_root
  load_env

  command -v tun2socks >/dev/null 2>&1 || { echo "ERROR: tun2socks is not installed. Run server1/install_tun2socks_binary.sh first." >&2; exit 1; }
  command -v ss-local >/dev/null 2>&1 || { echo "ERROR: shadowsocks-libev is not installed. Run server1/install_sslocal.sh first." >&2; exit 1; }

  id -u tunroute >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin tunroute

  cat >/usr/local/sbin/tun2socks-post-up-safe.sh <<EOF
#!/usr/bin/env bash
set -e
ip link set ${TUN2SOCKS_TUN_DEV} up mtu ${TUN2SOCKS_MTU}
ip addr replace ${TUN2SOCKS_TUN_ADDR} dev ${TUN2SOCKS_TUN_DEV}
EOF
  chmod 0755 /usr/local/sbin/tun2socks-post-up-safe.sh

  cat >/usr/local/sbin/tun2socks-apply-safe-routing.sh <<EOF
#!/usr/bin/env bash
set -e
UID_TUN=\$(id -u tunroute)
ip route replace default dev ${TUN2SOCKS_TUN_DEV} table 100
ip rule del priority 1000 2>/dev/null || true
ip rule add priority 1000 uidrange \${UID_TUN}-\${UID_TUN} lookup 100
EOF
  chmod 0755 /usr/local/sbin/tun2socks-apply-safe-routing.sh

  cat >/usr/local/bin/via-server2 <<'EOF'
#!/usr/bin/env bash
set -e
exec runuser -u tunroute -- "$@"
EOF
  chmod 0755 /usr/local/bin/via-server2

  cat >/etc/systemd/system/tun2socks-server2.service <<EOF
[Unit]
Description=tun2socks client via Shadowsocks server2
After=network-online.target shadowsocks-libev-local@server2-client.service
Wants=network-online.target
Requires=shadowsocks-libev-local@server2-client.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tun2socks -device tun://${TUN2SOCKS_TUN_DEV} -proxy socks5://${LOCAL_SOCKS_ADDR}:${LOCAL_SOCKS_PORT} -interface ${TUN2SOCKS_IFACE} -loglevel info -tun-post-up /usr/local/sbin/tun2socks-post-up-safe.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/tun2socks-routing.service <<'EOF'
[Unit]
Description=Policy routing for tun2socks safe mode
After=tun2socks-server2.service
Requires=tun2socks-server2.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tun2socks-apply-safe-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now tun2socks-server2.service
  systemctl enable --now tun2socks-routing.service

  systemctl --no-pager --full status tun2socks-server2.service || true
  systemctl --no-pager --full status tun2socks-routing.service || true

  log "Safe mode installed. Use: via-server2 curl -4 https://ifconfig.me"
}

main "$@"
