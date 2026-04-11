#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <username> [path/to/.env]" >&2
  exit 1
fi

USERNAME="$1"
ENV_FILE="${2:-.env}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
else
  echo "Warning: ENV file '${ENV_FILE}' not found. Using default domain settings." >&2
fi

SINGBOX_CONFIG="/etc/sing-box/config.json"
if [[ ! -f "$SINGBOX_CONFIG" ]]; then
  echo "Error: $SINGBOX_CONFIG not found. Is sing-box installed via setup_new.sh?" >&2
  exit 1
fi

# Generate new secrets
NEW_VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
NEW_TROJAN_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/\n' | head -c 16)"
NEW_HYSTERIA2_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/\n' | head -c 16)"
NEW_TT_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/\n' | head -c 16)"

echo "Adding user '${USERNAME}' to sing-box (VLESS, Trojan, Hysteria2)..."

# Safely update sing-box config
jq --arg uuid "$NEW_VLESS_UUID" \
   --arg trojan_pass "$NEW_TROJAN_PASSWORD" \
   --arg h2_name "$USERNAME" \
   --arg h2_pass "$NEW_HYSTERIA2_PASSWORD" \
   '( .inbounds[] | select(.tag == "vless-reality") | .users ) += [{"uuid": $uuid, "flow": "xtls-rprx-vision"}] |
    ( .inbounds[] | select(.tag == "trojan-tls") | .users ) += [{"password": $trojan_pass}] |
    ( .inbounds[] | select(.tag == "hysteria2") | .users ) += [{"name": $h2_name, "password": $h2_pass}]' \
   "$SINGBOX_CONFIG" > /tmp/config.json.tmp && mv /tmp/config.json.tmp "$SINGBOX_CONFIG"

systemctl restart sing-box

echo "Adding user '${USERNAME}' to TrustTunnel..."
TT_CRED_FILE="/opt/trusttunnel/credentials.toml"
if [[ -f "$TT_CRED_FILE" ]]; then
  cat >> "$TT_CRED_FILE" <<INNER_EOF

[[client]]
username = "${USERNAME}"
password = "${NEW_TT_PASSWORD}"
INNER_EOF
  systemctl restart trusttunnel
else
  echo "Warning: TrustTunnel credentials file not found at $TT_CRED_FILE. Skipping TrustTunnel user addition."
fi

# Load settings from setup_new.sh
SETTINGS_FILE="/etc/vpn_settings.env"
if [[ -f "$SETTINGS_FILE" ]]; then
  source "$SETTINGS_FILE"
else
  echo "Warning: $SETTINGS_FILE not found. Client files generation might be incomplete."
  SERVER_IP=$(curl -s4 ifconfig.me || echo "YOUR_SERVER_IP")
  PORT_VLESS_REALITY_TCP=8443
  PORT_TROJAN_TLS_TCP=2053
  PORT_HYSTERIA2_QUIC_UDP=8443
  PORT_TRUSTTUNNEL=9443
  REALITY_PUBLIC_KEY="UNKNOWN_PUBKEY"
  REALITY_SHORT_ID="UNKNOWN_SID"
  REALITY_SERVER_NAME="www.cloudflare.com"
  DOMAIN="example.com"
fi

CLIENT_DIR="/root/vpn_clients/${USERNAME}"
mkdir -p "${CLIENT_DIR}"

TT_DEEPLINK=""
if [[ -d "/opt/trusttunnel" ]]; then
  cd /opt/trusttunnel
  TT_DEEPLINK=$(./trusttunnel_endpoint vpn.toml hosts.toml -c "${USERNAME}" -a "${SERVER_IP}:${PORT_TRUSTTUNNEL}" --format deeplink || echo "Failed to generate deeplink")
  ./trusttunnel_endpoint vpn.toml hosts.toml -c "${USERNAME}" -a "${SERVER_IP}:${PORT_TRUSTTUNNEL}" --format toml > "${CLIENT_DIR}/trusttunnel_client.toml" || echo "Failed to generate toml"
fi

VLESS_LINK="vless://${NEW_VLESS_UUID}@${SERVER_IP}:${PORT_VLESS_REALITY_TCP}?security=reality&encryption=none&pbk=${REALITY_PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SERVER_NAME}&sid=${REALITY_SHORT_ID}#${USERNAME}-VLESS"
TROJAN_LINK="trojan://${NEW_TROJAN_PASSWORD}@${SERVER_IP}:${PORT_TROJAN_TLS_TCP}?security=tls&sni=${DOMAIN}&type=tcp&headerType=none#${USERNAME}-Trojan"
HY2_LINK="hy2://${NEW_HYSTERIA2_PASSWORD}@${SERVER_IP}:${PORT_HYSTERIA2_QUIC_UDP}?sni=${DOMAIN}#${USERNAME}-Hysteria2"

cat > "${CLIENT_DIR}/links.txt" <<LINKS_EOF
VLESS+Reality:
${VLESS_LINK}

Trojan:
${TROJAN_LINK}

Hysteria2:
${HY2_LINK}

TrustTunnel Deeplink:
${TT_DEEPLINK}
LINKS_EOF

cat > "${CLIENT_DIR}/singbox_vless.json" <<VLESS_EOF
{
  "log": {"level": "info"},
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "server": "${SERVER_IP}",
      "server_port": ${PORT_VLESS_REALITY_TCP},
      "uuid": "${NEW_VLESS_UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER_NAME}",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${REALITY_SHORT_ID}"
        }
      }
    }
  ]
}
VLESS_EOF

cat > "${CLIENT_DIR}/singbox_trojan.json" <<TROJAN_EOF
{
  "log": {"level": "info"},
  "outbounds": [
    {
      "type": "trojan",
      "tag": "trojan-tls",
      "server": "${SERVER_IP}",
      "server_port": ${PORT_TROJAN_TLS_TCP},
      "password": "${NEW_TROJAN_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "utls": {"enabled": true, "fingerprint": "chrome"}
      }
    }
  ]
}
TROJAN_EOF

cat > "${CLIENT_DIR}/singbox_hysteria2.json" <<HY2_EOF
{
  "log": {"level": "info"},
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "server": "${SERVER_IP}",
      "server_port": ${PORT_HYSTERIA2_QUIC_UDP},
      "password": "${NEW_HYSTERIA2_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"]
      }
    }
  ]
}
HY2_EOF

echo "========================================================="
echo "✅ User '${USERNAME}' has been added successfully."
echo "Client configurations have been saved to: ${CLIENT_DIR}/"
echo "  1. trusttunnel_client.toml    (For TrustTunnel CLI / App)"
echo "  2. singbox_vless.json         (sing-box VLESS config)"
echo "  3. singbox_trojan.json        (sing-box Trojan config)"
echo "  4. singbox_hysteria2.json     (sing-box Hysteria2 config)"
echo "  5. links.txt                  (vless://, trojan:// URIs & TT link)"
echo "========================================================="
