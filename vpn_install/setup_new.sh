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
: "${PORT_PUBLIC:=443}" # public entrypoint for ALL protocols (TCP/UDP)

# Internal ports (loopback only). Public traffic is multiplexed on PORT_PUBLIC.
: "${PORT_VLESS_REALITY_TCP:=8443}"
: "${PORT_TROJAN_TLS_TCP:=2053}"
: "${PORT_HYSTERIA2_QUIC_UDP:=8443}"
: "${PORT_TRUSTTUNNEL:=9443}"
: "${PORT_NGINX:=8080}"
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
cd /opt/trusttunnel
cp "${FULLCHAIN}" /opt/trusttunnel/cert.pem
cp "${PRIVKEY}" /opt/trusttunnel/key.pem
# TrustTunnel wizard can hang on some hosts even in non-interactive mode.
# Run with a timeout and fall back to self-signed if the provided-cert path fails.
if ! timeout 180s ./setup_wizard -m non-interactive \
    -a 127.0.0.1:${PORT_TRUSTTUNNEL} \
    -c "${TRUSTTUNNEL_USERNAME}:${TRUSTTUNNEL_PASSWORD}" \
    -n "${TRUSTTUNNEL_DOMAIN}" \
    --lib-settings vpn.toml \
    --hosts-settings hosts.toml \
    --cert-type provided \
    --cert-chain-path /opt/trusttunnel/cert.pem \
    --cert-key-path /opt/trusttunnel/key.pem; then
  echo "[TrustTunnel] setup_wizard failed or timed out with provided cert; retrying with self-signed..." >&2
  timeout 180s ./setup_wizard -m non-interactive \
      -a 127.0.0.1:${PORT_TRUSTTUNNEL} \
      -c "${TRUSTTUNNEL_USERNAME}:${TRUSTTUNNEL_PASSWORD}" \
      -n "${TRUSTTUNNEL_DOMAIN}" \
      --lib-settings vpn.toml \
      --hosts-settings hosts.toml \
      --cert-type self-signed
fi

cp trusttunnel.service.template /etc/systemd/system/trusttunnel.service
sed -i 's|ExecStart=.*|ExecStart=/opt/trusttunnel/trusttunnel_endpoint /opt/trusttunnel/vpn.toml /opt/trusttunnel/hosts.toml|' /etc/systemd/system/trusttunnel.service
systemctl daemon-reload || true
systemctl enable trusttunnel || true
systemctl restart trusttunnel || true

# sing-box config
install -d -m 0755 /etc/sing-box
cat >/etc/sing-box/config.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "direct",
      "tag": "tcp-mux",
      "listen": "::",
      "listen_port": ${PORT_PUBLIC},
      "network": "tcp"
    },
    {
      "type": "direct",
      "tag": "udp-mux",
      "listen": "::",
      "listen_port": ${PORT_PUBLIC},
      "network": "udp"
    },
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "127.0.0.1",
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
      "listen": "127.0.0.1",
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
      "listen": "127.0.0.1",
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
  "route": {
    "rules": [
      {
        "inbound": ["tcp-mux", "udp-mux"],
        "action": "sniff"
      },
      {
        "inbound": "tcp-mux",
        "domain": ["${REALITY_SERVER_NAME}"],
        "action": "route",
        "outbound": "direct",
        "override_address": "127.0.0.1",
        "override_port": ${PORT_VLESS_REALITY_TCP}
      },
      {
        "inbound": "tcp-mux",
        "domain": ["${DOMAIN}"],
        "action": "route",
        "outbound": "direct",
        "override_address": "127.0.0.1",
        "override_port": ${PORT_TROJAN_TLS_TCP}
      },
      {
        "inbound": "tcp-mux",
        "domain": ["${TRUSTTUNNEL_DOMAIN}"],
        "action": "route",
        "outbound": "direct",
        "override_address": "127.0.0.1",
        "override_port": ${PORT_TRUSTTUNNEL}
      },
      {
        "inbound": "tcp-mux",
        "action": "route",
        "outbound": "direct",
        "override_address": "127.0.0.1",
        "override_port": ${PORT_NGINX}
      },
      {
        "inbound": "udp-mux",
        "domain": ["${TRUSTTUNNEL_DOMAIN}"],
        "action": "route",
        "outbound": "direct",
        "override_address": "127.0.0.1",
        "override_port": ${PORT_TRUSTTUNNEL}
      },
      {
        "inbound": "udp-mux",
        "action": "route",
        "outbound": "direct",
        "override_address": "127.0.0.1",
        "override_port": ${PORT_HYSTERIA2_QUIC_UDP}
      }
    ],
    "final": "direct"
  }
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

systemctl daemon-reload || true
systemctl enable sing-box || true
systemctl restart sing-box || true

# Save settings for add_user_new.sh
SERVER_IP=$(curl -s4 ifconfig.me || echo "YOUR_SERVER_IP")
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

echo "========================================================="
echo "✅ Server configured successfully."
echo "Client configurations have been saved to: ${CLIENT_DIR}/"
echo "  1. trusttunnel_client.toml    (For TrustTunnel CLI / App)"
echo "  2. singbox_vless.json         (sing-box VLESS config)"
echo "  3. singbox_trojan.json        (sing-box Trojan config)"
echo "  4. singbox_hysteria2.json     (sing-box Hysteria2 config)"
echo "  5. links.txt                  (vless://, trojan:// URIs & TT link)"
echo "========================================================="
