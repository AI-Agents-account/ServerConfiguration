#!/usr/bin/env bash
set -euo pipefail

# Render sing-box client config for server1 -> server2 (egress tunnel) with full/split routing.
# Output: /etc/sing-box/client-server2.json

MODE="${TUN_MODE:-split}"
ENV_FILE="${1:-server1/.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

SS_SERVER="${TUN_SSIP:-${SS_SERVER:-}}"
SS_PORT="${TUN_SSPORT:-${SS_SERVER_PORT:-6666}}"
SS_METHOD="${TUN_SSMETHOD:-${SS_METHOD:-chacha20-ietf-poly1305}}"
SS_PASSWORD="${TUN_SSPASSWORD:-${SS_PASSWORD:-}}"

TUN_IFACE="${SINGBOX_TUN_IFACE:-tun0}"
TUN_ADDR="${SINGBOX_TUN_ADDR:-172.19.0.1/30}"
TUN_MTU="${SINGBOX_TUN_MTU:-1500}"

# Rule-set sources (remote .srs)
RU_GEOIP_SRS_URL="${RU_GEOIP_SRS_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru.srs}"
RU_GEOSITE_SRS_URL="${RU_GEOSITE_SRS_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-category-ru.srs}"
RU_GOV_GEOSITE_SRS_URL="${RU_GOV_GEOSITE_SRS_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-category-gov-ru.srs}"
TELEGRAM_GEOSITE_SRS_URL="${TELEGRAM_GEOSITE_SRS_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-telegram.srs}"

if [[ -z "$SS_SERVER" || -z "$SS_PASSWORD" ]]; then
  echo "ERROR: Missing required Shadowsocks variables (TUN_SSIP/TUN_SSPASSWORD)" >&2
  exit 1
fi

install -d -m 0755 /etc/sing-box

# Routing rules:
# - Always keep local/private ranges direct
# - Keep server2 direct
# - Split: RU+GOV direct, Telegram proxy, rest proxy
# - Full: everything proxy (except the bypass rules above)
SPLIT_RULES=""
if [[ "$MODE" == "split" ]]; then
  SPLIT_RULES='      {"rule_set": ["geosite-telegram"], "action": "route", "outbound": "proxy"},
      {"rule_set": ["geoip-ru", "geosite-ru", "geosite-gov-ru"], "action": "route", "outbound": "direct"},'
fi

cat > /etc/sing-box/client-server2.json <<JSON
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "$TUN_IFACE",
      "address": ["$TUN_ADDR"],
      "mtu": $TUN_MTU,
      "auto_route": true,
      "strict_route": true,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "$SS_SERVER",
      "server_port": $SS_PORT,
      "method": "$SS_METHOD",
      "password": "$SS_PASSWORD"
    }
  ],
  "dns": {
    "servers": [
      {"type": "udp", "tag": "dns-direct", "server": "1.1.1.1", "detour": "direct"},
      {"type": "udp", "tag": "dns-direct-2", "server": "8.8.8.8", "detour": "direct"}
    ],
    "rules": [
      {"action": "route", "server": "dns-direct"}
    ]
  },
  "route": {
    "auto_detect_interface": true,
    "rule_set": [
      {"type": "remote", "tag": "geoip-ru", "format": "binary", "url": "$RU_GEOIP_SRS_URL", "update_interval": "1d", "download_detour": "direct"},
      {"type": "remote", "tag": "geosite-ru", "format": "binary", "url": "$RU_GEOSITE_SRS_URL", "update_interval": "1d", "download_detour": "direct"},
      {"type": "remote", "tag": "geosite-gov-ru", "format": "binary", "url": "$RU_GOV_GEOSITE_SRS_URL", "update_interval": "1d", "download_detour": "direct"},
      {"type": "remote", "tag": "geosite-telegram", "format": "binary", "url": "$TELEGRAM_GEOSITE_SRS_URL", "update_interval": "1d", "download_detour": "direct"}
    ],
    "rules": [
      {"ip_cidr": ["10.0.0.0/8","192.168.0.0/16","172.16.0.0/12","127.0.0.0/8","169.254.0.0/16"], "action": "route", "outbound": "direct"},
      {"ip_cidr": ["$SS_SERVER/32"], "action": "route", "outbound": "direct"},

$SPLIT_RULES
      {"action": "route", "outbound": "proxy"}
    ]
  }
}
JSON

echo "[render_singbox_client_config] Generated /etc/sing-box/client-server2.json (mode=$MODE iface=$TUN_IFACE)"
