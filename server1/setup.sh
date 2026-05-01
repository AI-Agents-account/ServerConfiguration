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

# Ensure env exists (user requirement): create server1/.env from an example on first run.
# Never overwrite an existing env file.
if [[ ! -f "$ENV_FILE" ]]; then
  EXAMPLE_1="$SCRIPT_DIR/.env.example"
  EXAMPLE_2="$SCRIPT_DIR/../.env.example"
  if [[ -f "$EXAMPLE_1" ]]; then
    echo "[setup] $ENV_FILE not found, creating from $EXAMPLE_1..."
    cp -n "$EXAMPLE_1" "$ENV_FILE"
  elif [[ -f "$EXAMPLE_2" ]]; then
    echo "[setup] $ENV_FILE not found, creating from $EXAMPLE_2..."
    cp -n "$EXAMPLE_2" "$ENV_FILE"
  else
    echo "ERROR: env file not found ($ENV_FILE) and no .env.example available to bootstrap." >&2
    exit 2
  fi
fi

# Load env so ENABLE_SERVER1_PUBLIC_VPN / ENABLE_SERVER1_WIREGUARD (and other vars)
# affect control flow below.
# shellcheck disable=SC1090
source "$ENV_FILE"

# 0. Install VPN Clients
bash "$SCRIPT_DIR/install_vpn_clients.sh"

# 1. Install Sing-box
bash "$SCRIPT_DIR/install_singbox.sh"

# 2. Render configuration
TUN_MODE="$MODE" bash "$SCRIPT_DIR/render_singbox_config.sh" "$ENV_FILE"

# 3. Create/Update Systemd Service
# sing-box service expects its working directory to exist.
install -d -m 0755 /var/lib/sing-box
cat <<EOF > /etc/systemd/system/sing-box-server2.service
[Unit]
Description=sing-box Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/sing-box
Environment="ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true"
Environment="ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true"
ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/client-server2.json
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/client-server2.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

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

# 5.1 Apply routing policy for WireGuard clients (wg0 -> table 2022 -> tun0).
# This avoids routing the whole host through the tunnel and prevents direct-outbound loops.
if [[ -f "$SCRIPT_DIR/apply_split_routing.sh" ]]; then
  bash "$SCRIPT_DIR/apply_split_routing.sh" || true
fi

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
