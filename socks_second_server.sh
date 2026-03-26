#!/usr/bin/env bash
set -euo pipefail

log() { echo "[socks_second_server.sh] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

load_env() {
  if [[ -f ./.env ]]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' ./.env | xargs -d '\n' || true)
  fi

  : "${ALLOWED_IPS:?ALLOWED_IPS is required (CSV list)}"
  : "${SS_SERVER_PORT:=6666}"
  : "${SS_PASSWORD:?SS_PASSWORD is required}"
  : "${SS_METHOD:=chacha20-ietf-poly1305}"
  : "${SS_TIMEOUT:=86400}"
}

install_packages() {
  log "Installing shadowsocks-libev + nftables..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y shadowsocks-libev nftables
}

write_config() {
  log "Writing /etc/shadowsocks-libev/config.json"
  install -d -m 0755 /etc/shadowsocks-libev

  cat > /etc/shadowsocks-libev/config.json <<EOF
{
  "server": ["0.0.0.0"],
  "mode": "tcp_and_udp",
  "server_port": ${SS_SERVER_PORT},
  "password": "${SS_PASSWORD}",
  "timeout": ${SS_TIMEOUT},
  "method": "${SS_METHOD}"
}
EOF
}

configure_nftables() {
  log "Configuring nftables allowlist for port ${SS_SERVER_PORT}"

  systemctl enable --now nftables || true

  # Create a dedicated table/chain so we don't depend on existing distro rules.
  nft list table inet sproxy >/dev/null 2>&1 || nft add table inet sproxy
  nft list chain inet sproxy input >/dev/null 2>&1 || nft add chain inet sproxy input '{ type filter hook input priority 0; policy accept; }'

  # Create or recreate the set
  nft list set inet sproxy allowed_ips >/dev/null 2>&1 && nft delete set inet sproxy allowed_ips || true
  nft add set inet sproxy allowed_ips '{ type ipv4_addr; flags interval; }'

  IFS=',' read -r -a IPS <<< "${ALLOWED_IPS}"
  for ip in "${IPS[@]}"; do
    ip="${ip// /}"
    [[ -n "${ip}" ]] || continue
    nft add element inet sproxy allowed_ips "{ ${ip} }" || true
  done

  # Remove previous rules for this port (best-effort)
  # We match by comment to avoid nuking unrelated rules.
  while nft -a list chain inet sproxy input | grep -q 'comment "SPROXY"'; do
    handle=$(nft -a list chain inet sproxy input | awk '/comment "SPROXY"/ {print $NF; exit}')
    [[ -n "${handle:-}" ]] || break
    nft delete rule inet sproxy input handle "${handle}" || break
  done

  nft add rule inet sproxy input ip saddr @allowed_ips tcp dport "${SS_SERVER_PORT}" accept comment "SPROXY"
  nft add rule inet sproxy input ip saddr @allowed_ips udp dport "${SS_SERVER_PORT}" accept comment "SPROXY"
  nft add rule inet sproxy input tcp dport "${SS_SERVER_PORT}" drop comment "SPROXY"
  nft add rule inet sproxy input udp dport "${SS_SERVER_PORT}" drop comment "SPROXY"

  nft list ruleset >/dev/null
}

enable_service() {
  log "Enabling and starting shadowsocks-libev"
  systemctl enable --now shadowsocks-libev
  systemctl restart shadowsocks-libev
  systemctl --no-pager --full status shadowsocks-libev || true
}

main() {
  require_root
  load_env
  install_packages
  write_config
  configure_nftables
  enable_service
  log "Done."
}

main "$@"
