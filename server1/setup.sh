#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
ENV_FILE="${2:-server1/.env}"

usage() {
  cat <<'EOF'
Usage:
  bash ./server1/setup.sh full [server1/.env]
  bash ./server1/setup.sh split [server1/.env]
EOF
}

case "$MODE" in
  full|split) ;;
  *)
    usage
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure env exists
if [[ ! -f "$ENV_FILE" ]]; then
  EXAMPLE_1="$SCRIPT_DIR/.env.example"
  if [[ -f "$EXAMPLE_1" ]]; then
    echo "[setup] $ENV_FILE not found, creating from $EXAMPLE_1..."
    cp -n "$EXAMPLE_1" "$ENV_FILE"
  fi
fi

# Load env
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# 1. Install Sing-box
bash "$SCRIPT_DIR/install_singbox.sh"

# 2. Render sing-box CLIENT config for server1 -> server2 (egress) and create systemd unit
TUN_MODE="$MODE" bash "$SCRIPT_DIR/render_singbox_client_config.sh" "$ENV_FILE"

cat <<'EOF' > /etc/systemd/system/sing-box-server2.service
[Unit]
Description=sing-box Client Tunnel (server1 -> server2)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
Environment="ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true"
ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/client-server2.json
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/client-server2.json
# sing-box TUN auto_route may register DNS on tun0; keep system DNS on uplink
ExecStartPost=/usr/bin/resolvectl default-route tun0 no
ExecStartPost=/usr/bin/resolvectl dns tun0 8.8.8.8 8.8.4.4
ExecStartPost=/usr/bin/resolvectl domain tun0 ""
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box-server2.service

# 3. Cleanup legacy services (tun2socks / sslocal)
systemctl stop tun2socks-server2.service sslocal-server2.service tun2socks-full-routing.service 2>/dev/null || true
systemctl disable tun2socks-server2.service sslocal-server2.service tun2socks-full-routing.service 2>/dev/null || true

# 4. Optional: Public VPN bundle + WireGuard server
# VPN must be installed BEFORE WireGuard as it performs 'ufw reset'
if [[ "${ENABLE_SERVER1_PUBLIC_VPN:-0}" == "1" ]]; then
  echo "[setup] Installing Public VPN bundle (server1/vpn_install)..."
  bash "$SCRIPT_DIR/vpn_install/setup.sh" "$ENV_FILE"
fi

if [[ "${ENABLE_SERVER1_WIREGUARD:-0}" == "1" ]]; then
  echo "[setup] Installing WireGuard Server..."
  bash "$SCRIPT_DIR/wireguard/setup.sh" "$ENV_FILE"
fi

echo "[setup] Done: mode=$MODE env=$ENV_FILE. sing-box-server2.service is running."
