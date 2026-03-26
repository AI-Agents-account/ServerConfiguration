#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"

log() { echo "[sslocal_install.sh] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

main() {
  require_root

  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: env file not found: ${ENV_FILE}" >&2
    exit 1
  fi

  # shellcheck disable=SC2046
  export $(grep -v '^#' "${ENV_FILE}" | xargs -d '\n' || true)

  : "${TUN_SSIP:?TUN_SSIP is required}"
  : "${TUN_SSPORT:?TUN_SSPORT is required}"
  : "${TUN_SSPASSWORD:?TUN_SSPASSWORD is required}"
  : "${TUN_SSMETHOD:?TUN_SSMETHOD is required}"

  LOCAL_SOCKS_PORT="${LOCAL_SOCKS_PORT:-1080}"

  log "Installing shadowsocks-libev client (ss-local)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y shadowsocks-libev

  log "Writing /etc/default/ss-local-tun2socks"
  cat > /etc/default/ss-local-tun2socks <<EOF
SS_SERVER=${TUN_SSIP}
SS_PORT=${TUN_SSPORT}
SS_PASSWORD=${TUN_SSPASSWORD}
SS_METHOD=${TUN_SSMETHOD}
LOCAL_ADDR=127.0.0.1
LOCAL_PORT=${LOCAL_SOCKS_PORT}
EOF

  log "Writing /etc/systemd/system/ss-local-tun2socks.service"
  cat > /etc/systemd/system/ss-local-tun2socks.service <<'EOF'
[Unit]
Description=Shadowsocks local client for tun2socks (ss-local)
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/default/ss-local-tun2socks
ExecStart=/usr/bin/ss-local -s ${SS_SERVER} -p ${SS_PORT} -k ${SS_PASSWORD} -m ${SS_METHOD} -b ${LOCAL_ADDR} -l ${LOCAL_PORT}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ss-local-tun2socks
  systemctl --no-pager --full status ss-local-tun2socks || true

  log "Done. Local SOCKS5 is on 127.0.0.1:${LOCAL_SOCKS_PORT}."
  log "Set TUN_PROXY_URL=socks5://127.0.0.1:${LOCAL_SOCKS_PORT} in server1/.env before running tun2socks_install.sh"
}

main "$@"
