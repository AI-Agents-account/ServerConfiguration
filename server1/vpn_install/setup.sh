#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-}"
if [[ -z "${ENV_FILE}" || ! -f "${ENV_FILE}" ]]; then
  echo "Usage: $0 path/to/.env" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

VPN_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${VPN_INSTALL_DIR}/clients"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 3; }; }

# Defaults
: "${ENABLE_LETSENCRYPT:=1}"
: "${ALLOW_SELF_SIGNED:=1}"
: "${REQUIRE_TRUSTTUNNEL_LE:=1}"  # if 1: fail setup if TrustTunnel cannot use a Let's Encrypt cert
: "${PORT_PUBLIC:=443}" # public entrypoint for ALL protocols (TCP/UDP)

# Internal ports (loopback only). Public traffic is multiplexed on PORT_PUBLIC.
: "${PORT_VLESS_REALITY_TCP:=8443}"
: "${PORT_TROJAN_TLS_TCP:=2053}"
: "${PORT_HYSTERIA2_QUIC_UDP:=8443}"
: "${PORT_TRUSTTUNNEL:=9443}"
: "${PORT_NGINX:=8080}"
: "${WG_PORT:=7666}"
: "${REALITY_SERVER_NAME:=www.cloudflare.com}"
: "${REALITY_HANDSHAKE_SERVER:=www.cloudflare.com}"
: "${REALITY_HANDSHAKE_PORT:=443}"
: "${SINGBOX_USER:=singbox}"

if [[ -z "${DOMAIN:-}" ]]; then echo "DOMAIN is required" >&2; exit 4; fi
if [[ -z "${TRUSTTUNNEL_DOMAIN:-}" ]]; then echo "TRUSTTUNNEL_DOMAIN is required for the new architecture" >&2; exit 4; fi
if [[ "${ENABLE_LETSENCRYPT}" == "1" && -z "${EMAIL:-}" ]]; then echo "EMAIL is required when ENABLE_LETSENCRYPT=1" >&2; exit 4; fi

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl unzip jq ufw fail2ban unattended-upgrades nginx

# Enable unattended upgrades (non-interactive). Avoid dpkg-reconfigure (can block on some hosts).
if dpkg -s unattended-upgrades >/dev/null 2>&1; then
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
fi

# Basic firewall (Only expose 443 TCP/UDP, 80 TCP for Let's Encrypt, 22 SSH)
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow "${PORT_PUBLIC}"/tcp
ufw allow "${PORT_PUBLIC}"/udp

# Also allow WireGuard port if it's already configured or at least its default
WG_PORT_TO_ALLOW="${WG_PORT:-7666}"
if [[ -f "/etc/wireguard/wg0.conf" ]]; then
  DETECTED_WG_PORT=$(grep -i "^ListenPort" /etc/wireguard/wg0.conf | awk '{print $3}')
  if [[ -n "$DETECTED_WG_PORT" ]]; then
    WG_PORT_TO_ALLOW="$DETECTED_WG_PORT"
  fi
fi
ufw allow "${WG_PORT_TO_ALLOW}"/udp

ufw --force enable

# fail2ban (sshd)
cat >/etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
EOF
systemctl restart fail2ban

# Create service user
if ! id -u "${SINGBOX_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SINGBOX_USER}"
fi

# Install sing-box 1.13.6
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.6}"
ARCH="amd64"
TMPDIR="/tmp/vpn_install"
mkdir -p "${TMPDIR}"
cd "${TMPDIR}"

if ! command -v sing-box >/dev/null 2>&1; then
  echo "Installing sing-box v${SINGBOX_VERSION}..."
  curl -fsSL -o sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
  tar -xzf sing-box.tar.gz
  install -m 0755 "sing-box-${SINGBOX_VERSION}-linux-${ARCH}/sing-box" /usr/local/bin/sing-box
fi

# Install TrustTunnel
TRUSTTUNNEL_VERSION="1.0.33"
if [[ ! -f /opt/trusttunnel/trusttunnel_endpoint ]]; then
  echo "Installing TrustTunnel v${TRUSTTUNNEL_VERSION}..."
  curl -fsSL -o trusttunnel.tar.gz "https://github.com/TrustTunnel/TrustTunnel/releases/download/v${TRUSTTUNNEL_VERSION}/trusttunnel-v${TRUSTTUNNEL_VERSION}-linux-x86_64.tar.gz"
  mkdir -p /opt/trusttunnel
  tar -xzf trusttunnel.tar.gz -C /opt/trusttunnel --strip-components=1
fi

# Install xray only for key generation (small, one-time)
XRAY_VERSION="${XRAY_VERSION:-1.8.24}"
if ! command -v xray >/dev/null 2>&1; then
  echo "Installing xray v${XRAY_VERSION} (for key generation)..."
  curl -fsSL -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"
  unzip -o xray.zip xray geoip.dat geosite.dat >/dev/null
  install -m 0755 xray /usr/local/bin/xray
  mkdir -p /usr/local/share/xray
  install -m 0644 geoip.dat /usr/local/share/xray/geoip.dat
  install -m 0644 geosite.dat /usr/local/share/xray/geosite.dat
fi

# Secrets generation (if missing)
if [[ -z "${VLESS_UUID:-}" ]]; then
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
fi
if [[ -z "${TROJAN_PASSWORD:-}" ]]; then
  TROJAN_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/\n' | head -c 32)"
fi
if [[ -z "${HYSTERIA2_PASSWORD:-}" ]]; then
  HYSTERIA2_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/\n' | head -c 32)"
fi
if [[ -z "${TRUSTTUNNEL_USERNAME:-}" ]]; then
  TRUSTTUNNEL_USERNAME="admin"
fi
if [[ -z "${TRUSTTUNNEL_PASSWORD:-}" ]]; then
  TRUSTTUNNEL_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/\n' | head -c 16)"
fi

# Reality keypair
XRAY_KEYS="$(xray x25519)"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-$(echo "${XRAY_KEYS}" | awk -F': ' '/Private key/ {print $2}' | tr -d '\r')}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-$(echo "${XRAY_KEYS}" | awk -F': ' '/Public key/ {print $2}' | tr -d '\r')}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 4)}"

# TLS certs
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
FULLCHAIN="${CERT_PATH}/fullchain.pem"
PRIVKEY="${CERT_PATH}/privkey.pem"

if [[ "${ENABLE_LETSENCRYPT}" == "1" ]]; then
  apt-get install -y certbot
  if [[ ! -f "${FULLCHAIN}" || ! -f "${PRIVKEY}" ]]; then
    echo "Requesting Let's Encrypt cert for ${DOMAIN} and ${TRUSTTUNNEL_DOMAIN} via standalone HTTP-01 on :80..."
    systemctl stop nginx 2>/dev/null || true
    set +e
    certbot certonly --standalone --preferred-challenges http \
      -d "${DOMAIN}" -d "${TRUSTTUNNEL_DOMAIN}" -m "${EMAIL}" --agree-tos --non-interactive
    RC=$?
    set -e
    if [[ $RC -ne 0 ]]; then
      echo "Let's Encrypt failed. Most common cause: inbound port 80 blocked by provider firewall/security group." >&2
    fi
  fi
fi

# Fallback: self-signed cert if needed
if [[ ( ! -f "${FULLCHAIN}" || ! -f "${PRIVKEY}" ) ]]; then
  if [[ "${ALLOW_SELF_SIGNED}" == "1" ]]; then
    echo "Generating self-signed certificate for ${DOMAIN} (fallback)..." >&2
    mkdir -p /etc/sing-box/certs
    FULLCHAIN="/etc/sing-box/certs/${DOMAIN}.crt"
    PRIVKEY="/etc/sing-box/certs/${DOMAIN}.key"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj "/CN=${DOMAIN}" \
      -keyout "${PRIVKEY}" -out "${FULLCHAIN}"
    chown root:${SINGBOX_USER} "${PRIVKEY}" || true
    chmod 640 "${PRIVKEY}" || true
  else
    echo "TLS cert not available (Let's Encrypt failed or disabled, and ALLOW_SELF_SIGNED=0)." >&2
    exit 10
  fi
fi

# Ensure sing-box can read the TLS key (service runs as ${SINGBOX_USER}).
# Let's Encrypt keys are typically root-only; copy them to /etc/sing-box/certs with group access.
install -d -m 0755 /etc/sing-box/certs
cp -f "${FULLCHAIN}" "/etc/sing-box/certs/${DOMAIN}.fullchain.pem"
cp -f "${PRIVKEY}" "/etc/sing-box/certs/${DOMAIN}.privkey.pem"
chown root:${SINGBOX_USER} "/etc/sing-box/certs/${DOMAIN}.privkey.pem" || true
chmod 640 "/etc/sing-box/certs/${DOMAIN}.privkey.pem" || true
chmod 644 "/etc/sing-box/certs/${DOMAIN}.fullchain.pem" || true
FULLCHAIN="/etc/sing-box/certs/${DOMAIN}.fullchain.pem"
PRIVKEY="/etc/sing-box/certs/${DOMAIN}.privkey.pem"

# Nginx Fallback setup
cat >/etc/nginx/sites-available/fallback <<EOF
server {
    listen 127.0.0.1:${PORT_NGINX};
    server_name _;
    
    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
ln -sf /etc/nginx/sites-available/fallback /etc/nginx/sites-enabled/fallback
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx || true
systemctl enable nginx || true

# TrustTunnel setup (Non-interactive)
# NOTE: FULLCHAIN/PRIVKEY may be repointed to /etc/sing-box/certs later; TrustTunnel must use the original Let's Encrypt files.
LE_FULLCHAIN="${CERT_PATH}/fullchain.pem"
LE_PRIVKEY="${CERT_PATH}/privkey.pem"

if [[ "${REQUIRE_TRUSTTUNNEL_LE}" == "1" ]]; then
  if [[ "${ENABLE_LETSENCRYPT}" != "1" ]]; then
    echo "[TrustTunnel] ERROR: REQUIRE_TRUSTTUNNEL_LE=1 requires ENABLE_LETSENCRYPT=1" >&2
    exit 20
  fi
  if [[ ! -f "${LE_FULLCHAIN}" || ! -f "${LE_PRIVKEY}" ]]; then
    echo "[TrustTunnel] ERROR: REQUIRE_TRUSTTUNNEL_LE=1 but Let's Encrypt files are missing: ${LE_FULLCHAIN} / ${LE_PRIVKEY}" >&2
    echo "[TrustTunnel] Likely cause: certbot failed (often inbound :80 blocked)." >&2
    exit 20
  fi
fi

cd /opt/trusttunnel
cp "${LE_FULLCHAIN}" /opt/trusttunnel/cert.pem
cp "${LE_PRIVKEY}" /opt/trusttunnel/key.pem
# TrustTunnel wizard can hang on some hosts even in non-interactive mode.
# Run with a timeout. If REQUIRE_TRUSTTUNNEL_LE=1, do NOT fall back to self-signed.
if ! timeout 60s ./setup_wizard -m non-interactive \
    -a 127.0.0.1:${PORT_TRUSTTUNNEL} \
    -c "${TRUSTTUNNEL_USERNAME}:${TRUSTTUNNEL_PASSWORD}" \
    -n "${TRUSTTUNNEL_DOMAIN}" \
    --lib-settings vpn.toml \
    --hosts-settings hosts.toml \
    --cert-type provided \
    --cert-chain-path /opt/trusttunnel/cert.pem \
    --cert-key-path /opt/trusttunnel/key.pem; then
  
  # Workaround: If wizard failed but we have provided certs, create files manually.
  if [[ -f /opt/trusttunnel/cert.pem && -f /opt/trusttunnel/key.pem ]]; then
    echo "[TrustTunnel] setup_wizard failed; creating config files manually as a fallback..." >&2
    
    # Generate credentials.toml
    cat >credentials.toml <<EOF
[[client]]
username = "${TRUSTTUNNEL_USERNAME}"
password = "${TRUSTTUNNEL_PASSWORD}"
EOF

    # Generate rules.toml (empty but valid)
    cat >rules.toml <<EOF
# Filter rules
EOF

    # Generate hosts.toml
    cat >hosts.toml <<EOF
ping_hosts = []
speedtest_hosts = []
reverse_proxy_hosts = []

[[main_hosts]]
hostname = "${TRUSTTUNNEL_DOMAIN}"
cert_chain_path = "/opt/trusttunnel/cert.pem"
private_key_path = "/opt/trusttunnel/key.pem"
allowed_sni = []
EOF

    # Generate vpn.toml (minimal working config)
    cat >vpn.toml <<EOF
listen_address = "127.0.0.1:${PORT_TRUSTTUNNEL}"
credentials_file = "credentials.toml"
rules_file = "rules.toml"
ipv6_available = true
allow_private_network_connections = false
tls_handshake_timeout_secs = 10
client_listener_timeout_secs = 600
connection_establishment_timeout_secs = 30
tcp_connections_timeout_secs = 604800
udp_connections_timeout_secs = 300
speedtest_enable = false
ping_enable = false
auth_failure_status_code = 407
[forward_protocol]
[forward_protocol.direct]
[listen_protocols]
[listen_protocols.http1]
upload_buffer_size = 32768
[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 16384
header_table_size = 65536
[listen_protocols.quic]
recv_udp_payload_size = 1350
send_udp_payload_size = 1350
initial_max_data = 104857600
initial_max_stream_data_bidi_local = 1048576
initial_max_stream_data_bidi_remote = 1048576
initial_max_stream_data_uni = 1048576
initial_max_streams_bidi = 4096
initial_max_streams_uni = 4096
max_connection_window = 25165824
max_stream_window = 16777216
disable_active_migration = true
enable_early_data = true
message_queue_capacity = 4096
EOF
  else
    if [[ "${REQUIRE_TRUSTTUNNEL_LE}" == "1" ]]; then
      echo "[TrustTunnel] ERROR: setup_wizard failed and no certs available." >&2
      exit 21
    fi

    echo "[TrustTunnel] setup_wizard failed or timed out with provided cert; retrying with self-signed (REQUIRE_TRUSTTUNNEL_LE=0)..." >&2
    timeout 60s ./setup_wizard -m non-interactive \
        -a 127.0.0.1:${PORT_TRUSTTUNNEL} \
        -c "${TRUSTTUNNEL_USERNAME}:${TRUSTTUNNEL_PASSWORD}" \
        -n "${TRUSTTUNNEL_DOMAIN}" \
        --lib-settings vpn.toml \
        --hosts-settings hosts.toml \
        --cert-type self-signed
  fi
fi

cp trusttunnel.service.template /etc/systemd/system/trusttunnel.service
sed -i 's|ExecStart=.*|ExecStart=/opt/trusttunnel/trusttunnel_endpoint /opt/trusttunnel/vpn.toml /opt/trusttunnel/hosts.toml|' /etc/systemd/system/trusttunnel.service
systemctl daemon-reload || true
systemctl enable trusttunnel || true
systemctl restart trusttunnel || true

# sing-box config (vpn-server)
# Requirement: split-routing must apply to ALL VPN clients (WireGuard + Public VPN).
# For Public VPN, routing is implemented INSIDE sing-box using rule_sets:
# - RU -> direct
# - Telegram + all non-RU -> proxy (Shadowsocks to server2)
install -d -m 0755 /etc/sing-box

# Shadowsocks (server2) vars from server1/.env
SS_SERVER="${TUN_SSIP:-${SS_SERVER:-}}"
SS_PORT="${TUN_SSPORT:-${SS_SERVER_PORT:-}}"
SS_METHOD="${TUN_SSMETHOD:-${SS_METHOD:-chacha20-ietf-poly1305}}"
SS_PASSWORD="${TUN_SSPASSWORD:-${SS_PASSWORD:-}}"
if [[ -z "${SS_SERVER}" || -z "${SS_PORT}" || -z "${SS_PASSWORD}" ]]; then
  echo "ERROR: Missing Shadowsocks variables for split routing (TUN_SSIP/TUN_SSPORT/TUN_SSPASSWORD)" >&2
  exit 6
fi

GEOIP_RU_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"
GEOSITE_RU_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs"
GEOSITE_TG_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-telegram.srs"

cat >/etc/sing-box/vpn-server.json <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": 443,
      "users": [{"uuid": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER_NAME}",
        "alpn": ["h2", "http/1.1"],
        "reality": {
          "enabled": true,
          "handshake": {"server": "${REALITY_HANDSHAKE_SERVER}", "server_port": ${REALITY_HANDSHAKE_PORT}},
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": ["${REALITY_SHORT_ID}"]
        }
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-tls",
      "listen": "::",
      "listen_port": 2053,
      "users": [{"password": "${TROJAN_PASSWORD}"}],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h2", "http/1.1"],
        "certificate_path": "${FULLCHAIN}",
        "key_path": "${PRIVKEY}"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": 443,
      "users": [{"name": "admin", "password": "${HYSTERIA2_PASSWORD}"}],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"],
        "certificate_path": "${FULLCHAIN}",
        "key_path": "${PRIVKEY}"
      }
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "${SS_SERVER}",
      "server_port": ${SS_PORT},
      "method": "${SS_METHOD}",
      "password": "${SS_PASSWORD}"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rule_set": [
      {"tag": "geoip-ru", "type": "remote", "format": "binary", "url": "${GEOIP_RU_URL}", "download_detour": "direct"},
      {"tag": "geosite-ru", "type": "remote", "format": "binary", "url": "${GEOSITE_RU_URL}", "download_detour": "direct"},
      {"tag": "geosite-telegram", "type": "remote", "format": "binary", "url": "${GEOSITE_TG_URL}", "download_detour": "direct"}
    ],
    "rules": [
      {"protocol": "dns", "action": "hijack-dns"},

      {"ip_cidr": ["10.0.0.0/8","192.168.0.0/16","172.16.0.0/12","127.0.0.0/8","169.254.0.0/16"], "action": "route", "outbound": "direct"},
      {"ip_cidr": ["${SS_SERVER}/32"], "action": "route", "outbound": "direct"},

      {"rule_set": ["geosite-telegram"], "action": "route", "outbound": "proxy"},
      {"rule_set": ["geoip-ru", "geosite-ru"], "action": "route", "outbound": "direct"},

      {"action": "route", "outbound": "proxy"}
    ]
  },
  "dns": {
    "servers": [
      {"type": "udp", "tag": "dns-direct", "server": "1.1.1.1"},
      {"type": "udp", "tag": "dns-proxy", "server": "8.8.8.8", "detour": "proxy"}
    ],
    "final": "dns-direct"
  }
}
EOF
chown root:${SINGBOX_USER} /etc/sing-box/vpn-server.json
chmod 640 /etc/sing-box/vpn-server.json

# systemd service
cat >/etc/systemd/system/sing-box-vpn.service <<'EOF'
[Unit]
Description=sing-box VPN Server Service
After=network.target

[Service]
User=singbox
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/vpn-server.json
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload || true
systemctl enable sing-box-vpn || true
systemctl restart sing-box-vpn || true

# Standalone Hysteria2 server on UDP :443 (separate from sing-box)
HYSTERIA_VERSION="${HYSTERIA_VERSION:-2.8.1}"
HYSTERIA_URL="https://github.com/apernet/hysteria/releases/download/app/v${HYSTERIA_VERSION}/hysteria-linux-amd64"
if [[ ! -x /usr/local/bin/hysteria ]]; then
  echo "Installing hysteria v${HYSTERIA_VERSION}..."
  curl -fsSL -o /usr/local/bin/hysteria "${HYSTERIA_URL}"
  chmod +x /usr/local/bin/hysteria
fi

install -d -m 0755 /etc/hysteria
cat >/etc/hysteria/config.yaml <<HYCFG
auth:
  type: password
  password: "${HYSTERIA2_PASSWORD}"

listen: :${PORT_PUBLIC}

tls:
  cert: ${FULLCHAIN}
  key: ${PRIVKEY}
HYCFG

cat >/etc/systemd/system/hysteria.service <<'HYUNIT'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
HYUNIT

systemctl daemon-reload || true
systemctl enable hysteria || true
systemctl restart hysteria || true

# Save settings for add_user_new.sh
# Detect the VPS public IPv4. Do NOT rely on ifconfig.me here because the host may be behind a full-tunnel (egress != ingress).
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="$(curl -s4 ifconfig.me || echo "YOUR_SERVER_IP")"
fi
cat >/etc/vpn_settings.env <<ENV_EOF
SERVER_IP="${SERVER_IP}"
PORT_PUBLIC="${PORT_PUBLIC}"
DOMAIN="${DOMAIN}"
TRUSTTUNNEL_DOMAIN="${TRUSTTUNNEL_DOMAIN}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME}"
PORT_VLESS_REALITY_TCP="${PORT_VLESS_REALITY_TCP}"
PORT_TROJAN_TLS_TCP="${PORT_TROJAN_TLS_TCP}"
PORT_HYSTERIA2_QUIC_UDP="${PORT_HYSTERIA2_QUIC_UDP}"
PORT_TRUSTTUNNEL="${PORT_TRUSTTUNNEL}"
ENV_EOF

# Generate Client Configs
CLIENT_DIR="/root/vpn_clients/${TRUSTTUNNEL_USERNAME}"
mkdir -p "${CLIENT_DIR}"

cd /opt/trusttunnel
TT_DEEPLINK=$(./trusttunnel_endpoint vpn.toml hosts.toml -c "${TRUSTTUNNEL_USERNAME}" -a "${SERVER_IP}:${PORT_PUBLIC}" --format deeplink)
./trusttunnel_endpoint vpn.toml hosts.toml -c "${TRUSTTUNNEL_USERNAME}" -a "${SERVER_IP}:${PORT_PUBLIC}" --format toml > "${CLIENT_DIR}/trusttunnel_client.toml"

# TrustTunnel manual-entry helper (some clients require manual fields besides deeplink)
TT_CERT_PEM=""
if [[ -f /opt/trusttunnel/cert.pem ]]; then
  TT_CERT_PEM="$(cat /opt/trusttunnel/cert.pem)"
fi
TT_USERNAME="${TRUSTTUNNEL_USERNAME}"
TT_PASSWORD="${TRUSTTUNNEL_PASSWORD}"  # from earlier in the script
TT_ADDR="${SERVER_IP}:${PORT_PUBLIC}"
TT_HOSTNAME="${TRUSTTUNNEL_DOMAIN}"
TT_OUT_PATH="${CLIENT_DIR}/trusttunnel_manual.json" TT_CERT_PEM="$TT_CERT_PEM" TT_ADDR="$TT_ADDR" TT_HOSTNAME="$TT_HOSTNAME" TT_USERNAME="$TT_USERNAME" TT_PASSWORD="$TT_PASSWORD" python3 - <<'PY'
import json, os
manual = {
  "address": os.environ.get("TT_ADDR", ""),
  "domain_name_from_server_cert": os.environ.get("TT_HOSTNAME", ""),
  "username": os.environ.get("TT_USERNAME", ""),
  "password": os.environ.get("TT_PASSWORD", ""),
  "dns_server_addresses": ["77.88.8.8", "77.88.8.1"],
  "client_random_hex_seq": "",
  "self_signed_certificate": os.environ.get("TT_CERT_PEM", ""),
}
out_path = os.environ.get("TT_OUT_PATH")
with open(out_path, "w", encoding="utf-8") as f:
  json.dump(manual, f, ensure_ascii=False, indent=2)
  f.write("\n")
PY

VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${PORT_PUBLIC}?security=reality&encryption=none&pbk=${REALITY_PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SERVER_NAME}&sid=${REALITY_SHORT_ID}#${TRUSTTUNNEL_USERNAME}-VLESS"
TROJAN_LINK="trojan://${TROJAN_PASSWORD}@${SERVER_IP}:${PORT_PUBLIC}?security=tls&sni=${DOMAIN}&type=tcp&headerType=none#${TRUSTTUNNEL_USERNAME}-Trojan"
HY2_LINK="hy2://${HYSTERIA2_PASSWORD}@${SERVER_IP}:${PORT_PUBLIC}?sni=${DOMAIN}#${TRUSTTUNNEL_USERNAME}-Hysteria2"


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
  "inbounds": [
    {"type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 1080}
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "out",
      "server": "${SERVER_IP}",
      "server_port": ${PORT_PUBLIC},
      "uuid": "${VLESS_UUID}",
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
  ],
  "route": {"final": "out"}
}
VLESS_EOF

cat > "${CLIENT_DIR}/singbox_trojan.json" <<TROJAN_EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 1080}
  ],
  "outbounds": [
    {
      "type": "trojan",
      "tag": "out",
      "server": "${SERVER_IP}",
      "server_port": ${PORT_PUBLIC},
      "password": "${TROJAN_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "utls": {"enabled": true, "fingerprint": "chrome"}
      }
    }
  ],
  "route": {"final": "out"}
}
TROJAN_EOF

cat > "${CLIENT_DIR}/singbox_hysteria2.json" <<HY2_EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 1080}
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "out",
      "server": "${SERVER_IP}",
      "server_port": ${PORT_PUBLIC},
      "password": "${HYSTERIA2_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"]
      }
    }
  ],
  "route": {"final": "out"}
}
HY2_EOF

# iOS sing-box (TUN) configs (full-tunnel)
# Note: iOS often needs explicit DNS routing to avoid "no downlink" symptoms.
cat > "${CLIENT_DIR}/singbox_ios_vless_tun.json" <<IOS_VLESS_EOF
{
  "log": {"level": "debug", "timestamp": true},
  "dns": {
    "servers": [
      {"tag": "yandex1", "address": "77.88.8.8", "detour": "direct"},
      {"tag": "yandex2", "address": "77.88.8.1", "detour": "direct"}
    ],
    "final": "yandex1",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "sniff": true
    }
  ],
  "outbounds": [
    {"type": "dns", "tag": "dns-out"},
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${DOMAIN}",
      "server_port": ${PORT_PUBLIC},
      "uuid": "${VLESS_UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER_NAME}",
        "alpn": ["h2", "http/1.1"],
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${REALITY_SHORT_ID}"
        }
      }
    },
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {"protocol": "dns", "outbound": "dns-out"}
    ],
    "final": "proxy"
  }
}
IOS_VLESS_EOF

cat > "${CLIENT_DIR}/singbox_ios_trojan_tun.json" <<IOS_TROJAN_EOF
{
  "log": {"level": "info", "timestamp": true},
  "dns": {
    "servers": [
      {"tag": "yandex1", "address": "77.88.8.8", "detour": "direct"},
      {"tag": "yandex2", "address": "77.88.8.1", "detour": "direct"}
    ],
    "final": "yandex1",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "inet4_address": "172.19.0.1/30", "auto_route": true, "strict_route": true, "stack": "system", "sniff": true}
  ],
  "outbounds": [
    {
      "type": "trojan",
      "tag": "proxy",
      "server": "${DOMAIN}",
      "server_port": ${PORT_PUBLIC},
      "password": "${TROJAN_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h2", "http/1.1"],
        "insecure": false
      }
    },
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"auto_detect_interface": true, "rules": [{"network": "udp", "port": 53, "action": "hijack-dns"}], "final": "proxy"}
}
IOS_TROJAN_EOF

cat > "${CLIENT_DIR}/singbox_ios_hysteria2_tun.json" <<IOS_HY2_EOF
{
  "log": {"level": "info", "timestamp": true},
  "dns": {
    "servers": [
      {"tag": "yandex1", "address": "77.88.8.8", "detour": "direct"},
      {"tag": "yandex2", "address": "77.88.8.1", "detour": "direct"}
    ],
    "final": "yandex1",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "inet4_address": "172.19.0.1/30", "auto_route": true, "strict_route": true, "stack": "system", "sniff": true}
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "${DOMAIN}",
      "server_port": ${PORT_PUBLIC},
      "password": "${HYSTERIA2_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"],
        "insecure": true
      }
    },
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"auto_detect_interface": true, "rules": [{"network": "udp", "port": 53, "action": "hijack-dns"}], "final": "proxy"}
}
IOS_HY2_EOF

# Windows sing-box (TUN) configs (full-tunnel)
# Generated from templates in vpn_install/clients
export TEMPLATES_DIR CLIENT_DIR DOMAIN PORT_PUBLIC VLESS_UUID TROJAN_PASSWORD REALITY_SERVER_NAME REALITY_PUBLIC_KEY REALITY_SHORT_ID HYSTERIA2_PASSWORD
python3 - <<'PY'
import os, pathlib

templates_dir = pathlib.Path(os.environ.get('TEMPLATES_DIR',''))
client_dir = pathlib.Path(os.environ['CLIENT_DIR'])

mapping = {
  '__SERVER__': os.environ['DOMAIN'],
  '__PORT__': os.environ['PORT_PUBLIC'],
  '__UUID__': os.environ['VLESS_UUID'],
  '__PASSWORD__': os.environ.get('TROJAN_PASSWORD',''),
  '__TLS_SNI__': os.environ['DOMAIN'],
  '__REALITY_SERVER_NAME__': os.environ['REALITY_SERVER_NAME'],
  '__REALITY_PUBKEY__': os.environ['REALITY_PUBLIC_KEY'],
  '__REALITY_SHORTID__': os.environ['REALITY_SHORT_ID'],
}

def render(tmpl_name: str, out_name: str, extra: dict | None = None):
  src = (templates_dir / tmpl_name).read_text(encoding='utf-8')
  m = dict(mapping)
  if extra:
    m.update(extra)
  for k,v in m.items():
    src = src.replace(k, str(v))
  (client_dir / out_name).write_text(src + "\n", encoding='utf-8')

render('windows_vless_reality_tun.tmpl.json', 'singbox_windows_vless_tun.json')
render('windows_trojan_tun.tmpl.json', 'singbox_windows_trojan_tun.json')
render('windows_hysteria2_tun.tmpl.json', 'singbox_windows_hysteria2_tun.json', {'__PASSWORD__': os.environ.get('HYSTERIA2_PASSWORD','')})
PY

echo "========================================================="
echo "✅ Server configured successfully."
echo "Client configurations have been saved to: ${CLIENT_DIR}/"
echo "  1. trusttunnel_client.toml        (For TrustTunnel CLI / App)"
echo "  2. singbox_vless.json             (sing-box VLESS config, local proxy)"
echo "  3. singbox_trojan.json            (sing-box Trojan config, local proxy)"
echo "  4. singbox_hysteria2.json         (sing-box Hysteria2 config, local proxy)"
echo "  5. singbox_ios_vless_tun.json     (iOS sing-box VLESS config, full-tunnel)"
echo "  6. singbox_ios_trojan_tun.json    (iOS sing-box Trojan config, full-tunnel)"
echo "  7. singbox_ios_hysteria2_tun.json (iOS sing-box Hysteria2 config, full-tunnel)"
echo "  8. singbox_windows_vless_tun.json     (Windows sing-box VLESS config, full-tunnel)"
echo "  9. singbox_windows_trojan_tun.json    (Windows sing-box Trojan config, full-tunnel)"
echo " 10. singbox_windows_hysteria2_tun.json (Windows sing-box Hysteria2 config, full-tunnel)"
echo " 11. links.txt                      (vless://, trojan:// URIs & TT link)"
echo "========================================================="
