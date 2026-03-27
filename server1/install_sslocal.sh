#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"

log() { echo "[install_sslocal] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "ERROR: env file not found: $ENV_FILE" >&2; exit 1; }
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$ENV_FILE" | xargs -d '\n' || true)

  : "${TUN_SSIP:?TUN_SSIP is required}"
  : "${TUN_SSPORT:?TUN_SSPORT is required}"
  : "${TUN_SSPASSWORD:?TUN_SSPASSWORD is required}"
  : "${TUN_SSMETHOD:?TUN_SSMETHOD is required}"
  : "${TUN_TIMEOUT:=86400}"
  : "${LOCAL_SOCKS_ADDR:=127.0.0.1}"
  : "${LOCAL_SOCKS_PORT:=1080}"
}

main() {
  require_root
  load_env

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y shadowsocks-libev

  install -d -m 0755 /etc/shadowsocks-libev
  cat >/etc/shadowsocks-libev/server2-client.json <<EOF
{
  "server": "${TUN_SSIP}",
  "server_port": ${TUN_SSPORT},
  "local_address": "${LOCAL_SOCKS_ADDR}",
  "local_port": ${LOCAL_SOCKS_PORT},
  "password": "${TUN_SSPASSWORD}",
  "timeout": ${TUN_TIMEOUT},
  "method": "${TUN_SSMETHOD}",
  "mode": "tcp_and_udp"
}
EOF

  systemctl enable --now shadowsocks-libev-local@server2-client.service
  systemctl restart shadowsocks-libev-local@server2-client.service
  systemctl --no-pager --full status shadowsocks-libev-local@server2-client.service || true

  log "Smoke test via local SOCKS5"
  curl -4 --socks5-hostname "${LOCAL_SOCKS_ADDR}:${LOCAL_SOCKS_PORT}" -s https://ifconfig.me || true
  echo
}

main "$@"
