#!/usr/bin/env bash
set -euo pipefail

# Unified sing-box configuration renderer for server1.
# Generates /etc/sing-box/vpn-server.json with split-routing and VPN inbounds.

MODE="${TUN_MODE:-split}" # Default to split-routing for all clients
ENV_FILE="${1:-server1/.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Shadowsocks Egress (to server2)
SS_SERVER="${TUN_SSIP:-${SS_SERVER:-}}"
SS_PORT="${TUN_SSPORT:-${SS_SERVER_PORT:-6666}}"
SS_METHOD="${TUN_SSMETHOD:-${SS_METHOD:-aes-256-gcm}}"
SS_PASSWORD="${TUN_SSPASSWORD:-${SS_PASSWORD:-}}"

# VPN Server Inbounds (Secrets)
VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "de012345-6789-abcd-ef01-23456789abcd")}"
TROJAN_PASSWORD="${TROJAN_PASSWORD:-$(openssl rand -base64 12 2>/dev/null | tr -d '/+' || echo "trojan-pass")}"
HYSTERIA2_PASSWORD="${HYSTERIA2_PASSWORD:-$(openssl rand -base64 12 2>/dev/null | tr -d '/+' || echo "hysteria-pass")}"

DOMAIN="${DOMAIN:-example.com}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.google.com}"
REALITY_HANDSHAKE_SERVER="${REALITY_HANDSHAKE_SERVER:-www.google.com}"
REALITY_HANDSHAKE_PORT="${REALITY_HANDSHAKE_PORT:-443}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 4 2>/dev/null || echo "01234567")}"

PORT_VLESS_REALITY_TCP="${PORT_VLESS_REALITY_TCP:-443}"
PORT_TROJAN_TLS_TCP="${PORT_TROJAN_TLS_TCP:-2053}"
PORT_HYSTERIA2_QUIC_UDP="${PORT_HYSTERIA2_QUIC_UDP:-443}"

FULLCHAIN="${FULLCHAIN:-/etc/sing-box/certs/fullchain.pem}"
PRIVKEY="${PRIVKEY:-/etc/sing-box/certs/privkey.pem}"

SERVER1_PUBLIC_IP="${SERVER1_PUBLIC_IP:-}"
WG_PORT="${WG_PORT:-7666}"

# Detect SSH port to avoid lockout
SSH_PORTS_JSON=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | paste -sd, - || echo 22)
if [[ -z "$SSH_PORTS_JSON" ]]; then SSH_PORTS_JSON="22"; fi

if [[ -z "$SS_SERVER" || -z "$SS_PASSWORD" ]]; then
  echo "ERROR: Missing required Shadowsocks variables (TUN_SSIP/TUN_SSPASSWORD)" >&2
  exit 1
fi

# Rule-set sources (remote .srs):
RU_GEOIP_SRS_URL="${RU_GEOIP_SRS_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru.srs}"
RU_GEOSITE_SRS_URL="${RU_GEOSITE_SRS_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-category-ru.srs}"
RU_GOV_GEOSITE_SRS_URL="${RU_GOV_GEOSITE_SRS_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-category-gov-ru.srs}"
TELEGRAM_GEOSITE_SRS_URL="${TELEGRAM_GEOSITE_SRS_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-telegram.srs}"

EXTRA_DIRECT_IP=""
if [[ -n "$SERVER1_PUBLIC_IP" ]]; then
  EXTRA_DIRECT_IP="\"$SERVER1_PUBLIC_IP/32\","
fi

# Routing Rules Logic
if [[ "$MODE" == "split" ]]; then
  # Split routing: RU direct, Telegram proxy, else proxy
  SPLIT_RULES='{
        "rule_set": ["geosite-telegram"],
        "action": "route",
        "outbound": "proxy"
      },
      {
        "rule_set": ["geoip-ru", "geosite-ru", "geosite-gov-ru"],
        "action": "route",
        "outbound": "direct"
      },'
else
  # Full routing: All via proxy except local/bypass
  SPLIT_RULES=""
fi

# Reality configuration
REALITY_CONFIG=""
if [[ -n "$REALITY_PRIVATE_KEY" ]]; then
  REALITY_CONFIG='{
          "enabled": true,
          "handshake": {"server": "'$REALITY_HANDSHAKE_SERVER'", "server_port": '$REALITY_HANDSHAKE_PORT'},
          "private_key": "'$REALITY_PRIVATE_KEY'",
          "short_id": ["'$REALITY_SHORT_ID'"]
        }'
else
  REALITY_CONFIG='{"enabled": false}'
fi

install -d -m 0755 /etc/sing-box

cat > /etc/sing-box/vpn-server.json <<JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "cache.db",
      "store_fakeip": true
    }
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT_VLESS_REALITY_TCP,
      "users": [{"uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SERVER_NAME",
        "alpn": ["h2", "http/1.1"],
        "reality": $REALITY_CONFIG
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": $PORT_TROJAN_TLS_TCP,
      "users": [{"password": "$TROJAN_PASSWORD"}],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "alpn": ["h2", "http/1.1"],
        "certificate_path": "$FULLCHAIN",
        "key_path": "$PRIVKEY"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": $PORT_HYSTERIA2_QUIC_UDP,
      "users": [{"password": "$HYSTERIA2_PASSWORD"}],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "alpn": ["h3"],
        "certificate_path": "$FULLCHAIN",
        "key_path": "$PRIVKEY"
      }
    },
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sbox-tun",
      "address": [
        "172.19.0.1/30"
      ],
      "mtu": 1500,
      "auto_route": true,
      "strict_route": false,
      "stack": "system",
      "route_table_id": 2022
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
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-local",
        "server": "8.8.8.8",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "action": "route",
        "server": "dns-local"
      }
    ]
  },
  "route": {
    "auto_detect_interface": true,
    "rule_set": [
      {
        "type": "remote",
        "tag": "geoip-ru",
        "format": "binary",
        "url": "$RU_GEOIP_SRS_URL",
        "update_interval": "1d",
        "download_detour": "direct"
      },
      {
        "type": "remote",
        "tag": "geosite-ru",
        "format": "binary",
        "url": "$RU_GEOSITE_SRS_URL",
        "update_interval": "1d",
        "download_detour": "direct"
      },
      {
        "type": "remote",
        "tag": "geosite-gov-ru",
        "format": "binary",
        "url": "$RU_GOV_GEOSITE_SRS_URL",
        "update_interval": "1d",
        "download_detour": "direct"
      },
      {
        "type": "remote",
        "tag": "geosite-telegram",
        "format": "binary",
        "url": "$TELEGRAM_GEOSITE_SRS_URL",
        "update_interval": "1d",
        "download_detour": "direct"
      }
    ],
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "port": 53,
        "action": "route",
        "outbound": "dns-out"
      },
      {
        "port": $WG_PORT,
        "action": "route",
        "outbound": "direct"
      },
      {
        "port": [$SSH_PORTS_JSON],
        "action": "route",
        "outbound": "direct"
      },
      {
        "source_port": [$SSH_PORTS_JSON],
        "action": "route",
        "outbound": "direct"
      },
      {
        "ip_cidr": [
          "10.0.0.0/8",
          "192.168.0.0/16",
          "172.16.0.0/12",
          "127.0.0.0/8",
          "10.66.66.0/24",
          "$SS_SERVER/32",
          ${EXTRA_DIRECT_IP}
          "169.254.169.0/24"
        ],
        "action": "route",
        "outbound": "direct"
      },
      $SPLIT_RULES
      {
        "action": "route",
        "outbound": "proxy"
      }
    ]
  }
}
JSON

echo "[render_singbox_config] Generated /etc/sing-box/vpn-server.json (mode=$MODE)"
