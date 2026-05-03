#!/usr/bin/env bash
set -euo pipefail

# Parse arguments
USERNAME=""
ENV_FILE_ARG=""
ROTATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate)
      ROTATE=true
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$USERNAME" ]]; then
        USERNAME="$1"
      elif [[ -z "$ENV_FILE_ARG" ]]; then
        ENV_FILE_ARG="$1"
      else
        echo "Too many arguments." >&2
        exit 1
      fi
      shift
      ;;
    esac
done

if [[ -z "$USERNAME" ]]; then
  echo "Usage: $0 <username> [path/to/.env] [--rotate]" >&2
  exit 1
fi

# Env file lookup
# Priority: 1. Argument, 2. server1/.env, 3. ./server1/.env, 4. ./.env
ENV_FILE=""
if [[ -n "$ENV_FILE_ARG" ]]; then
  if [[ -f "$ENV_FILE_ARG" ]]; then
    ENV_FILE="$ENV_FILE_ARG"
  fi
else
  for f in "server1/.env" "./server1/.env" "./.env"; do
    if [[ -f "$f" ]]; then
      ENV_FILE="$f"
      break
    fi
  done
fi

if [[ -n "$ENV_FILE" ]]; then
  echo "Using ENV file: $(realpath "$ENV_FILE")"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "Warning: No ENV file found in default locations. Using default settings." >&2
fi

VPN_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${VPN_INSTALL_DIR}/clients"

SINGBOX_CONFIG="/etc/sing-box/vpn-server.json"
if [[ ! -f "$SINGBOX_CONFIG" ]]; then
  if [[ -f "/etc/sing-box/config.json" ]]; then
    SINGBOX_CONFIG="/etc/sing-box/config.json"
  else
    echo "Error: sing-box config not found in /etc/sing-box/" >&2
    exit 1
  fi
fi

# Function to extract existing secret from sing-box config
extract_secret() {
  local protocol="$1"
  local field="$2"
  # Search for a user with the given name in the specified inbound type
  jq -r --arg name "$USERNAME" '
    .inbounds[] | select(.type == "'"$protocol"'") | .users[]? | select(.name == $name) | .'"$field" \
    "$SINGBOX_CONFIG" 2>/dev/null | grep -v "null" | head -n 1 || echo ""
}

# Load or generate secrets
VLESS_UUID=""
TROJAN_PASSWORD=""
HYSTERIA2_PASSWORD=""

if [[ "$ROTATE" == "false" ]]; then
  VLESS_UUID=$(extract_secret "vless" "uuid")
  TROJAN_PASSWORD=$(extract_secret "trojan" "password")
  HYSTERIA2_PASSWORD=$(extract_secret "hysteria2" "password")
  
  [[ -n "$VLESS_UUID" ]] && echo "Found existing VLESS UUID for ${USERNAME}"
  [[ -n "$TROJAN_PASSWORD" ]] && echo "Found existing Trojan password for ${USERNAME}"
  [[ -n "$HYSTERIA2_PASSWORD" ]] && echo "Found existing Hysteria2 password for ${USERNAME}"
fi

if [[ -z "$VLESS_UUID" ]]; then
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
  echo "Generated new VLESS UUID for ${USERNAME}"
fi
if [[ -z "$TROJAN_PASSWORD" ]]; then
  TROJAN_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/\n' | head -c 16)"
  echo "Generated new Trojan password for ${USERNAME}"
fi
if [[ -z "$HYSTERIA2_PASSWORD" ]]; then
  HYSTERIA2_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/\n' | head -c 16)"
  echo "Generated new Hysteria2 password for ${USERNAME}"
fi

# TrustTunnel secrets
TT_CRED_FILE="/opt/trusttunnel/credentials.toml"
TT_PASSWORD=""
if [[ "$ROTATE" == "false" && -f "$TT_CRED_FILE" ]]; then
  TT_PASSWORD=$(awk -v user="$USERNAME" '
    $0 ~ "username = \""user"\"" {found=1}
    found && $1 == "password" {print $3; exit}
  ' "$TT_CRED_FILE" | tr -d '" ' || echo "")
  [[ -n "$TT_PASSWORD" ]] && echo "Found existing TrustTunnel password for ${USERNAME}"
fi

if [[ -z "$TT_PASSWORD" ]]; then
  TT_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/\n' | head -c 16)"
  echo "Generated new TrustTunnel password for ${USERNAME}"
fi

echo "Updating sing-box config for user '${USERNAME}'..."
# Ensure idempotency by removing old entry if it exists (by name) and adding new one
jq --arg name "$USERNAME" \
   --arg uuid "$VLESS_UUID" \
   --arg trojan_pass "$TROJAN_PASSWORD" \
   --arg h2_pass "$HYSTERIA2_PASSWORD" \
   '
   def update_users(proto; user_obj):
     (.inbounds[]? | select(.type == proto)) |= (
       .users |= (map(select(.name != $name)) + [user_obj])
     );

   update_users("vless"; {"name": $name, "uuid": $uuid, "flow": "xtls-rprx-vision"}) |
   update_users("trojan"; {"name": $name, "password": $trojan_pass}) |
   update_users("hysteria2"; {"name": $name, "password": $h2_pass})
   ' \
   "$SINGBOX_CONFIG" > /tmp/config.json.tmp && mv /tmp/config.json.tmp "$SINGBOX_CONFIG"

systemctl restart sing-box-vpn || systemctl restart sing-box || echo "Warning: Failed to restart sing-box"

echo "Updating TrustTunnel credentials..."
if [[ -f "$TT_CRED_FILE" ]]; then
  TMP_TT_CRED=$(mktemp)
  awk -v user="$USERNAME" '
    BEGIN { skip=0; block="" }
    /^\[\[client\]\]/ { 
      if (block != "") { if (skip == 0) print block; }
      block = $0 "\n"
      skip=0
      next
    }
    {
      if (block != "") {
        block = block $0 "\n"
        if ($0 ~ "username = \""user"\"") { skip=1 }
      } else {
        print $0
      }
    }
    END {
      if (block != "" && skip == 0) { print block }
    }
  ' "$TT_CRED_FILE" > "$TMP_TT_CRED"
  
  cat >> "$TMP_TT_CRED" <<INNER_EOF

[[client]]
username = "${USERNAME}"
password = "${TT_PASSWORD}"
INNER_EOF
  mv "$TMP_TT_CRED" "$TT_CRED_FILE"
  systemctl restart trusttunnel || echo "Warning: Failed to restart trusttunnel"
else
  echo "Warning: TrustTunnel credentials file not found at $TT_CRED_FILE. Skipping."
fi

# Load settings for client files
SETTINGS_FILE="/etc/vpn_settings.env"
if [[ -f "$SETTINGS_FILE" ]]; then
  source "$SETTINGS_FILE"
else
  echo "Warning: $SETTINGS_FILE not found. Using auto-detected or default values."
  # Detect public IP using the default interface of the main routing table to bypass tunnels
  WAN_IF=$(ip -4 route show table main default | awk '{print $5; exit}')
  if [[ -n "$WAN_IF" ]]; then
    SERVER_IP=$(curl -s4 --interface "$WAN_IF" https://api.ipify.org || curl -s4 https://api.ipify.org || echo "YOUR_SERVER_IP")
  else
    SERVER_IP=$(curl -s4 https://api.ipify.org || echo "YOUR_SERVER_IP")
  fi
  PORT_PUBLIC=443
  PORT_TROJAN_TLS_TCP=2053
  REALITY_PUBLIC_KEY="UNKNOWN_PUBKEY"
  REALITY_SHORT_ID="UNKNOWN_SID"
  REALITY_SERVER_NAME="www.yandex.ru"
  DOMAIN="example.com"
fi

CLIENT_DIR="/root/vpn_clients/${USERNAME}"
mkdir -p "${CLIENT_DIR}"

# Render client files from templates
render_template() {
  local src="$1"
  local dst="$2"
  local proto="$3"
  
  local pass="$TROJAN_PASSWORD"
  local port="$PORT_PUBLIC"
  [[ "$proto" == "hysteria2" ]] && pass="$HYSTERIA2_PASSWORD"
  [[ "$proto" == "trojan" ]] && port="$PORT_TROJAN_TLS_TCP"

  sed -e "s/__SERVER__/${SERVER_IP}/g" \
      -e "s/__PORT__/${port}/g" \
      -e "s/__TROJAN_PORT__/${PORT_TROJAN_TLS_TCP}/g" \
      -e "s/__UUID__/${VLESS_UUID}/g" \
      -e "s/__PASSWORD__/${pass}/g" \
      -e "s/__H2_PASSWORD__/${HYSTERIA2_PASSWORD}/g" \
      -e "s/__TLS_SNI__/${DOMAIN}/g" \
      -e "s/__REALITY_SNI__/${REALITY_SERVER_NAME}/g" \
      -e "s/__REALITY_SERVER_NAME__/${REALITY_SERVER_NAME}/g" \
      -e "s/__REALITY_PUBKEY__/${REALITY_PUBLIC_KEY}/g" \
      -e "s/__REALITY_SHORTID__/${REALITY_SHORT_ID}/g" \
      "$src" > "$dst"
}

if [[ -d "$TEMPLATES_DIR" ]]; then
  echo "Generating client files from templates in ${TEMPLATES_DIR}..."
  
  # iPhone templates
  [[ -f "${TEMPLATES_DIR}/iphone_vless_reality.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/iphone_vless_reality.tmpl.json" "${CLIENT_DIR}/singbox_ios_vless_tun.json" "vless"
  [[ -f "${TEMPLATES_DIR}/iphone_trojan.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/iphone_trojan.tmpl.json" "${CLIENT_DIR}/singbox_ios_trojan_tun.json" "trojan"
  [[ -f "${TEMPLATES_DIR}/iphone_hysteria2.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/iphone_hysteria2.tmpl.json" "${CLIENT_DIR}/singbox_ios_hysteria2_tun.json" "hysteria2"
  
  # Windows TUN templates
  [[ -f "${TEMPLATES_DIR}/windows_vless_reality_tun.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/windows_vless_reality_tun.tmpl.json" "${CLIENT_DIR}/singbox_windows_vless_tun.json" "vless"
  [[ -f "${TEMPLATES_DIR}/windows_trojan_tun.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/windows_trojan_tun.tmpl.json" "${CLIENT_DIR}/singbox_windows_trojan_tun.json" "trojan"
  [[ -f "${TEMPLATES_DIR}/windows_hysteria2_tun.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/windows_hysteria2_tun.tmpl.json" "${CLIENT_DIR}/singbox_windows_hysteria2_tun.json" "hysteria2"

  # Windows Proxy (local-only) templates
  [[ -f "${TEMPLATES_DIR}/windows_vless_reality_proxy.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/windows_vless_reality_proxy.tmpl.json" "${CLIENT_DIR}/singbox_vless.json" "vless"
  [[ -f "${TEMPLATES_DIR}/windows_trojan_proxy.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/windows_trojan_proxy.tmpl.json" "${CLIENT_DIR}/singbox_trojan.json" "trojan"
  [[ -f "${TEMPLATES_DIR}/windows_hysteria2_proxy.tmpl.json" ]] && render_template "${TEMPLATES_DIR}/windows_hysteria2_proxy.tmpl.json" "${CLIENT_DIR}/singbox_hysteria2.json" "hysteria2"
else
  echo "Warning: Templates directory ${TEMPLATES_DIR} not found. Skipping template-based config generation."
fi

# Links generation
VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${PORT_PUBLIC}?security=reality&encryption=none&pbk=${REALITY_PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SERVER_NAME}&sid=${REALITY_SHORT_ID}#${USERNAME}-VLESS"
TROJAN_LINK="trojan://${TROJAN_PASSWORD}@${SERVER_IP}:${PORT_TROJAN_TLS_TCP}?security=tls&sni=${DOMAIN}&type=tcp&headerType=none#${USERNAME}-Trojan"
HY2_LINK="hy2://${HYSTERIA2_PASSWORD}@${SERVER_IP}:${PORT_PUBLIC}?sni=${DOMAIN}#${USERNAME}-Hysteria2"

# TrustTunnel Deeplink & Manual
TT_DEEPLINK=""
if [[ -d "/opt/trusttunnel" ]]; then
  cd /opt/trusttunnel
  TT_DEEPLINK=$(./trusttunnel_endpoint vpn.toml hosts.toml -c "${USERNAME}" -a "${SERVER_IP}:${PORT_PUBLIC}" --format deeplink 2>/dev/null || echo "Failed to generate deeplink")
  ./trusttunnel_endpoint vpn.toml hosts.toml -c "${USERNAME}" -a "${SERVER_IP}:${PORT_PUBLIC}" --format toml > "${CLIENT_DIR}/trusttunnel_client.toml" 2>/dev/null || echo "Failed to generate toml"
  
  # Manual JSON
  TT_CERT_PEM=""
  [[ -f /opt/trusttunnel/cert.pem ]] && TT_CERT_PEM="$(cat /opt/trusttunnel/cert.pem)"
  
  cat > "${CLIENT_DIR}/trusttunnel_manual.json" <<EOF
{
  "address": "${SERVER_IP}:${PORT_PUBLIC}",
  "domain_name_from_server_cert": "${TRUSTTUNNEL_DOMAIN:-$DOMAIN}",
  "username": "${USERNAME}",
  "password": "${TT_PASSWORD}",
  "dns_server_addresses": ["77.88.8.8", "77.88.8.1"],
  "client_random_hex_seq": "",
  "self_signed_certificate": $(jq -Rs . <<<"$TT_CERT_PEM")
}
EOF
fi

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

echo "========================================================="
echo "✅ User '${USERNAME}' processed successfully."
echo "Secrets used:"
echo "  VLESS UUID: ${VLESS_UUID}"
echo "  Trojan Pass: ${TROJAN_PASSWORD}"
echo "  Hysteria2 Pass: ${HYSTERIA2_PASSWORD}"
echo "  TrustTunnel Pass: ${TT_PASSWORD}"
echo "Client configurations have been saved to: ${CLIENT_DIR}/"
echo "========================================================="
