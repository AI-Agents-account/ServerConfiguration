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

echo ""
echo "========================================="
echo "✅ User '${USERNAME}' has been added successfully."
echo "========================================="
echo "--- sing-box / Xray credentials ---"
echo "VLESS UUID         : $NEW_VLESS_UUID"
echo "Trojan Password    : $NEW_TROJAN_PASSWORD"
echo "Hysteria2 User     : $USERNAME"
echo "Hysteria2 Password : $NEW_HYSTERIA2_PASSWORD"
echo ""
echo "--- TrustTunnel credentials ---"
echo "Username : $USERNAME"
echo "Password : $NEW_TT_PASSWORD"
echo ""

if [[ -d "/opt/trusttunnel" ]]; then
  echo "--- TrustTunnel Client Config (Deeplink) ---"
  # Fetch server IP if not passed via env
  SERVER_IP=$(curl -s4 ifconfig.me || echo "<your-server-ip>")
  cd /opt/trusttunnel && ./trusttunnel_endpoint vpn.toml hosts.toml -c "${USERNAME}" -a "${SERVER_IP}" || echo "Failed to generate deeplink."
fi
echo "========================================="
