#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-}"
if [[ -z "${ENV_FILE}" || ! -f "${ENV_FILE}" ]]; then
  echo "Usage: $0 path/to/.env" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 3; }; }

# Defaults
: "${ENABLE_LETSENCRYPT:=1}"
: "${ALLOW_SELF_SIGNED:=1}"
: "${PORT_VLESS_REALITY_TCP:=443}"
: "${PORT_TROJAN_TLS_TCP:=2053}"
: "${PORT_HYSTERIA2_QUIC_UDP:=443}"
: "${REALITY_SERVER_NAME:=www.cloudflare.com}"
: "${REALITY_HANDSHAKE_SERVER:=www.cloudflare.com}"
: "${REALITY_HANDSHAKE_PORT:=443}"
: "${SINGBOX_USER:=singbox}"

if [[ -z "${DOMAIN:-}" ]]; then echo "DOMAIN is required" >&2; exit 4; fi
if [[ "${ENABLE_LETSENCRYPT}" == "1" && -z "${EMAIL:-}" ]]; then echo "EMAIL is required when ENABLE_LETSENCRYPT=1" >&2; exit 4; fi

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl unzip jq ufw fail2ban unattended-upgrades

# Enable unattended upgrades (non-interactive best effort)
if dpkg -s unattended-upgrades >/dev/null 2>&1; then
  dpkg-reconfigure --priority=low unattended-upgrades || true
fi

# Basic firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow "${PORT_VLESS_REALITY_TCP}"/tcp
ufw allow "${PORT_TROJAN_TLS_TCP}"/tcp
ufw allow "${PORT_HYSTERIA2_QUIC_UDP}"/udp
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

# Install sing-box (pinned version can be set via SINGBOX_VERSION)
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

# Reality keypair
# xray x25519 output usually contains "Private key:" and "Public key:"
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
    echo "Requesting Let's Encrypt cert for ${DOMAIN} via standalone HTTP-01 on :80..."
    # Stop anything on :80 just in case
    systemctl stop nginx 2>/dev/null || true
    set +e
    certbot certonly --standalone --preferred-challenges http \
      -d "${DOMAIN}" -m "${EMAIL}" --agree-tos --non-interactive
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
    echo "Either open inbound :80 for HTTP-01, use DNS-01, or enable ALLOW_SELF_SIGNED=1." >&2
    exit 10
  fi
fi

# sing-box config
install -d -m 0755 /etc/sing-box
cat >/etc/sing-box/config.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${PORT_VLESS_REALITY_TCP},
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
      "listen_port": ${PORT_TROJAN_TLS_TCP},
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
      "listen_port": ${PORT_HYSTERIA2_QUIC_UDP},
      "users": [{"name": "user1", "password": "${HYSTERIA2_PASSWORD}"}],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"],
        "certificate_path": "${FULLCHAIN}",
        "key_path": "${PRIVKEY}"
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}
EOF
chown root:${SINGBOX_USER} /etc/sing-box/config.json
chmod 640 /etc/sing-box/config.json

# systemd service
cat >/etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box Service
After=network.target

[Service]
User=singbox
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

echo "---"
echo "Server configured. Save these client parameters:"
echo "DOMAIN=${DOMAIN}"
echo "VLESS_UUID=${VLESS_UUID}"
echo "REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}"
echo "REALITY_SHORT_ID=${REALITY_SHORT_ID}"
echo "REALITY_SERVER_NAME=${REALITY_SERVER_NAME}"
echo "TROJAN_PASSWORD=${TROJAN_PASSWORD}"
echo "HYSTERIA2_PASSWORD=${HYSTERIA2_PASSWORD}"
