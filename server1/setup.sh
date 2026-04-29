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
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
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

echo "[setup] Done: mode=$MODE env=$ENV_FILE. Sing-box is running."
