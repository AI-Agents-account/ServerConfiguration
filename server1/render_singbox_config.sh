#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"
TUN_MODE="${TUN_MODE:-split}" # Requirements imply split routing

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Required variables (defaults or from .env)
SS_SERVER="${TUN_SSIP:-${SS_SERVER:-}}"
SS_PORT="${TUN_SSPORT:-${SS_SERVER_PORT:-}}"
SS_METHOD="${TUN_SSMETHOD:-${SS_METHOD:-aes-256-gcm}}"
SS_PASSWORD="${TUN_SSPASSWORD:-${SS_PASSWORD:-}}"
SERVER1_PUBLIC_IP="${SERVER1_PUBLIC_IP:-}"

# Inbound ports for bypass (to avoid loops and broken replies)
PORT_PUBLIC="${PORT_PUBLIC:-443}"
PORT_VLESS_REALITY_TCP="${PORT_VLESS_REALITY_TCP:-8443}"
PORT_TROJAN_TLS_TCP="${PORT_TROJAN_TLS_TCP:-2053}"
PORT_HYSTERIA2_QUIC_UDP="${PORT_HYSTERIA2_QUIC_UDP:-8443}"
PORT_TRUSTTUNNEL="${PORT_TRUSTTUNNEL:-9443}"
WG_PORT="${WG_PORT:-7666}"

if [[ -z "$SS_SERVER" || -z "$SS_PORT" || -z "$SS_PASSWORD" ]]; then
  echo "ERROR: Missing Shadowsocks variables (TUN_SSIP/SS_SERVER, TUN_SSPORT/SS_SERVER_PORT, TUN_SSPASSWORD/SS_PASSWORD)" >&2
  exit 1
fi

# Rule sets URLs
GEOIP_RU_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"
GEOSITE_RU_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-ru.srs"

# Rules logic
if [[ "$TUN_MODE" == "split" ]]; then
  ROUTE_RULE_RU='{ "rule_set": ["geoip-ru", "geosite-ru"], "outbound": "direct" },'
  DNS_RULE_RU='{ "rule_set": "geosite-ru", "server": "local" },'
else
  ROUTE_RULE_RU=""
  DNS_RULE_RU=""
fi

# Optional bypass for local public IP
EXTRA_DIRECT_IP=""
if [[ -n "$SERVER1_PUBLIC_IP" ]]; then
  EXTRA_DIRECT_IP="\"$SERVER1_PUBLIC_IP/32\","
fi

cat <<EOF > /etc/sing-box/client-server2.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/var/lib/sing-box/cache.db"
    }
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": "172.19.0.1/30",
      "mtu": 9000,
      "auto_route": true,
      "strict_route": true,
      "stack": "system"
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
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rule_set": [
      {
        "tag": "geoip-ru",
        "type": "remote",
        "format": "binary",
        "url": "$GEOIP_RU_URL",
        "download_detour": "direct"
      },
      {
        "tag": "geosite-ru",
        "type": "remote",
        "format": "binary",
        "url": "$GEOSITE_RU_URL",
        "download_detour": "direct"
      }
    ],
    "rules": [
      {
        "ip_cidr": [
          "10.0.0.0/8",
          "192.168.0.0/16",
          "172.16.0.0/12",
          "127.0.0.0/8",
          "$SS_SERVER/32",
          ${EXTRA_DIRECT_IP}
          "169.254.169.0/24"
        ],
        "outbound": "direct"
      },
      {
        "source_port": [
          $PORT_PUBLIC,
          $PORT_VLESS_REALITY_TCP,
          $PORT_TROJAN_TLS_TCP,
          $PORT_HYSTERIA2_QUIC_UDP,
          $PORT_TRUSTTUNNEL,
          $WG_PORT
        ],
        "outbound": "direct"
      },
      $ROUTE_RULE_RU
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
      $DNS_RULE_RU
      {
        "server": "google"
      }
    ],
    "final": "local"
  }
}
EOF

echo "[render_singbox_config] Generated /etc/sing-box/client-server2.json (mode=$TUN_MODE, compatible with 1.12+ rule_set)"
