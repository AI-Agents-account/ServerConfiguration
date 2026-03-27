#!/usr/bin/env bash
set -euo pipefail

log() { echo "[server2/setup.sh] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

load_env() {
  local env_file="${1:-${ENV_FILE:-./.env}}"
  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' "${env_file}" | xargs -d '\n' || true)
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

  # Use canonical names so the manual command works exactly as documented:
  # nft add element inet filter ALLOWED_SPROXY { <ip> }
  nft list table inet filter >/dev/null 2>&1 || nft add table inet filter

  # Ensure an input chain exists (on some minimal systems it may be missing)
  nft list chain inet filter input >/dev/null 2>&1 || nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'

  # Create or recreate the allowlist set
  nft list set inet filter ALLOWED_SPROXY >/dev/null 2>&1 && nft delete set inet filter ALLOWED_SPROXY || true
  nft add set inet filter ALLOWED_SPROXY '{ type ipv4_addr; flags interval; }'

  IFS=',' read -r -a IPS <<< "${ALLOWED_IPS}"
  for ip in "${IPS[@]}"; do
    ip="${ip// /}"
    [[ -n "${ip}" ]] || continue
    nft add element inet filter ALLOWED_SPROXY "{ ${ip} }" || true
  done

  # Remove previous SPROXY rules (best-effort) by comment
  while nft -a list chain inet filter input | grep -q 'comment "SPROXY"'; do
    handle=$(nft -a list chain inet filter input | awk '/comment "SPROXY"/ {print $NF; exit}')
    [[ -n "${handle:-}" ]] || break
    nft delete rule inet filter input handle "${handle}" || break
  done

  nft add rule inet filter input ip saddr @ALLOWED_SPROXY tcp dport "${SS_SERVER_PORT}" accept comment "SPROXY"
  nft add rule inet filter input ip saddr @ALLOWED_SPROXY udp dport "${SS_SERVER_PORT}" accept comment "SPROXY"
  nft add rule inet filter input tcp dport "${SS_SERVER_PORT}" drop comment "SPROXY"
  nft add rule inet filter input udp dport "${SS_SERVER_PORT}" drop comment "SPROXY"
}

persist_nftables_rules() {
  log "Persisting nftables rules to /etc/nftables.conf"
  nft list ruleset > /etc/nftables.conf
}

enable_service() {
  log "Enabling and starting shadowsocks-libev"
  systemctl enable --now shadowsocks-libev
  systemctl restart shadowsocks-libev
  systemctl --no-pager --full status shadowsocks-libev || true
}

main() {
  require_root
  load_env "${1:-}"
  install_packages
  write_config
  configure_nftables
  persist_nftables_rules
  enable_service
  log "Done."
}

main "$@"
