#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"
TUN_MODE="${TUN_MODE:-full}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Required variables (defaults or from .env)
# Backward/forward compatibility note:
# - Historically, server1/.env.example uses TUN_* variables.
# - Some docs/scripts referenced SS_* variables.
# We accept both, preferring TUN_*.
SS_SERVER="${TUN_SSIP:-${SS_SERVER:-}}"
SS_PORT="${TUN_SSPORT:-${SS_SERVER_PORT:-}}"
SS_METHOD="${TUN_SSMETHOD:-${SS_METHOD:-aes-256-gcm}}"
SS_PASSWORD="${TUN_SSPASSWORD:-${SS_PASSWORD:-}}"
SERVER1_PUBLIC_IP="${SERVER1_PUBLIC_IP:-}"

if [[ -z "$SS_SERVER" || -z "$SS_PORT" || -z "$SS_PASSWORD" ]]; then
  echo "ERROR: Missing required Shadowsocks variables (TUN_SSIP/SS_SERVER, TUN_SSPORT/SS_SERVER_PORT, TUN_SSPASSWORD/SS_PASSWORD)" >&2
  exit 1
fi

cat <<EOF > /etc/sing-box/client-server2.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": "172.19.0.1/30",
      "mtu": 9000,
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "platform": {
        "http_proxy": {
          "enabled": false
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "$SS_SERVER",
      "server_port": $SS_PORT,
      "method": "$SS_METHOD",
      "password": "$SS_PASSWORD"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "ip_cidr": ["10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"],
        "outbound": "direct"
      },
EOF

if [[ -n "$SERVER1_PUBLIC_IP" ]]; then
cat <<EOF >> /etc/sing-box/client-server2.json
      {
        "ip_cidr": ["$SERVER1_PUBLIC_IP/32"],
        "outbound": "direct"
      },
EOF
fi

if [[ "$TUN_MODE" == "split" ]]; then
cat <<EOF >> /etc/sing-box/client-server2.json
      {
        "geoip": ["ru"],
        "geosite": ["category-gov-ru", "cn"],
        "outbound": "direct"
      },
EOF
fi

cat <<EOF >> /etc/sing-box/client-server2.json
      {
        "outbound": "proxy"
      }
    ]
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "address": "8.8.8.8",
        "detour": "proxy"
      },
      {
        "tag": "local",
        "address": "1.1.1.1",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "local"
      }
    ]
  }
}
EOF

echo "[render_singbox_config] Generated /etc/sing-box/client-server2.json (mode=$TUN_MODE)"
