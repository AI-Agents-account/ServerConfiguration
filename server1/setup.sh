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

# Determine tun interface name (must match render_singbox_client_config.sh)
TUN_DEV="${SINGBOX_TUN_IFACE:-tun0}"

cat <<EOF > /etc/systemd/system/sing-box-server2.service
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
# Prevent systemd-resolved from using the tunnel for global DNS resolution to avoid loops.
ExecStartPost=-/usr/bin/resolvectl dns $TUN_DEV ""
ExecStartPost=-/usr/bin/resolvectl domain $TUN_DEV ""
ExecStartPost=-/usr/bin/resolvectl default-route $TUN_DEV false
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

# Add OS route for server2 explicitly to bypass loop
if [[ -n "$TUN_SSIP" ]]; then
  # Resolve hostname to IP if needed
  SS_IP="$TUN_SSIP"
  if [[ ! "$SS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SS_IP=$(getent hosts "$TUN_SSIP" | awk '{print $1}' | head -n1 || echo "")
  fi

  if [[ -n "$SS_IP" ]]; then
    DEFAULT_GW=$(ip route show default | awk '/default/ {print $3}' | head -n1)
    if [[ -n "$DEFAULT_GW" ]]; then
      ip route replace "$SS_IP/32" via "$DEFAULT_GW" 2>/dev/null || true
    fi
  fi
fi

systemctl daemon-reload
systemctl enable --now sing-box-server2.service

# 3. Apply routing for local processes (manual bypass of auto_route issues)
# Traffic from localhost to NON-RU -> table 2022
TABLE_ID=2022
if ! grep -q "^$TABLE_ID " /etc/iproute2/rt_tables 2>/dev/null; then
    echo "$TABLE_ID vpn-split" >> /etc/iproute2/rt_tables || true
fi
ip route replace default dev tun0 table $TABLE_ID 2>/dev/null || true

# Policy Rules (ordered by priority/pref)
# 1. SSH Protection: Always allow SSH in/out via main table
ip rule del pref 10 2>/dev/null || true
ip rule add pref 10 dport 22 lookup main 2>/dev/null || true
ip rule del pref 11 2>/dev/null || true
ip rule add pref 11 sport 22 lookup main 2>/dev/null || true

# 2. Local DNS bypass (avoid loops with systemd-resolved)
ip rule del pref 8000 2>/dev/null || true
ip rule add pref 8000 dport 53 lookup main 2>/dev/null || true
ip rule del pref 8001 2>/dev/null || true
ip rule add pref 8001 sport 53 lookup main 2>/dev/null || true

# 3. Mark 0xff (255) bypass: sing-box direct outbound/proxy traffic
ip rule del pref 8002 2>/dev/null || true
ip rule add pref 8002 fwmark 255 lookup main 2>/dev/null || true

# 4. Main table suppression: ignore default route in 'main', fall through to 2022
ip rule del pref 9000 2>/dev/null || true
ip rule add pref 9000 lookup main suppress_prefixlength 0 2>/dev/null || true

# 5. Catch-all for suppressed/remaining: route to tun0
ip rule del pref 9001 2>/dev/null || true
ip rule add pref 9001 lookup $TABLE_ID 2>/dev/null || true

# 4. Cleanup legacy services (tun2socks / sslocal)
systemctl stop tun2socks-server2.service sslocal-server2.service tun2socks-full-routing.service 2>/dev/null || true
systemctl disable tun2socks-server2.service sslocal-server2.service tun2socks-full-routing.service 2>/dev/null || true

# 5. Optional: Public VPN bundle + WireGuard server
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
