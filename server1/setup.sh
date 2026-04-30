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

# Load env so ENABLE_SERVER1_PUBLIC_VPN / ENABLE_SERVER1_WIREGUARD (and other vars)
# affect control flow below.
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# 0. Install VPN Clients
bash "$SCRIPT_DIR/install_vpn_clients.sh"

# 1. Install Sing-box
bash "$SCRIPT_DIR/install_singbox.sh"

# 2. Render configuration
TUN_MODE="$MODE" bash "$SCRIPT_DIR/render_singbox_config.sh" "$ENV_FILE"

# 3. Create/Update Systemd Service
cat <<EOF > /etc/systemd/system/sing-box-server2.service
[Unit]
Description=sing-box Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/sing-box
Environment="ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true"
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/client-server2.json
Restart=on-failure
RestartSec=10
LimitNOFILE= infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box-server2.service

# 4. Stop old services if they exist
systemctl stop tun2socks-server2.service sslocal-server2.service 2>/dev/null || true
systemctl disable tun2socks-server2.service sslocal-server2.service 2>/dev/null || true

# 5. Restart sing-box
systemctl restart sing-box-server2.service

# 6. Optional: VPN & WireGuard Server setup
# VPN must be installed BEFORE WireGuard as it performs 'ufw reset'
if [[ "${ENABLE_SERVER1_PUBLIC_VPN:-0}" == "1" ]]; then
  echo "[setup] Installing Public VPN Server..."
  bash "$SCRIPT_DIR/vpn_install/setup.sh" "$ENV_FILE"
fi

if [[ "${ENABLE_SERVER1_WIREGUARD:-0}" == "1" ]]; then
  echo "[setup] Installing WireGuard Server..."
  bash "$SCRIPT_DIR/wireguard/setup.sh" "mobile-client"
fi

echo "[setup] Done: mode=$MODE env=$ENV_FILE. Sing-box is running."
