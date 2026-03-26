#!/usr/bin/env bash
set -euo pipefail

log() { echo "[tun2socks_install.sh] $*"; }

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

  # Auto-detect primary interface if not provided
  if [[ -z "${TUN2SOCKS_IFACE:-}" ]]; then
    TUN2SOCKS_IFACE="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    [[ -n "${TUN2SOCKS_IFACE}" ]] || TUN2SOCKS_IFACE="eth0"
  fi

  : "${TUN2SOCKS_TUN_DEV:=tun0}"
  : "${TUN2SOCKS_TUN_ADDR:=192.168.0.33/24}"

  : "${TUN_SSIP:?TUN_SSIP is required}"
  : "${TUN_SSPORT:=6666}"
  : "${TUN_SSPASSWORD:?TUN_SSPASSWORD is required}"
  : "${TUN_SSMETHOD:=chacha20-ietf-poly1305}"
}

install_packages() {
  log "Installing dependencies (git, make, snapd)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y git make snapd

  systemctl enable --now snapd || true
}

install_go() {
  if command -v go >/dev/null 2>&1; then
    log "Go already installed: $(go version || true)"
    return
  fi

  log "Installing Go via snap (classic)..."
  snap install go --classic
  log "Go installed: $(go version || true)"
}

build_and_install_tun2socks() {
  local base="/usr/local/projects/tun2socks"
  local src="${base}/src"

  mkdir -p "${base}"

  if [[ ! -d "${src}/.git" ]]; then
    log "Cloning tun2socks source..."
    git clone https://github.com/xjasonlyu/tun2socks.git "${src}"
  else
    log "Updating tun2socks source..."
    git -C "${src}" fetch --all --prune
  fi

  log "Building tun2socks..."
  make -C "${src}" tun2socks

  log "Installing binary to /usr/local/bin/tun2socks"
  install -m 0755 "${src}/build/tun2socks" /usr/local/bin/tun2socks
}

enable_ip_forward() {
  log "Enabling IPv4 forwarding..."
  cat > /etc/sysctl.d/99-tun2socks.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

ensure_rt_table() {
  if ! grep -qE '^\s*20\s+lip\s*$' /etc/iproute2/rt_tables; then
    log "Adding routing table 'lip' (id 20) to /etc/iproute2/rt_tables"
    echo "20 lip" >> /etc/iproute2/rt_tables
  fi
}

write_defaults() {
  log "Writing /etc/default/tun2socks"
  cat > /etc/default/tun2socks <<EOF
SSIP=${TUN_SSIP}
SSPORT=${TUN_SSPORT}
SSPASSWORD=${TUN_SSPASSWORD}
SSMETHOD=${TUN_SSMETHOD}
IFACE=${TUN2SOCKS_IFACE}
TUNDEV=${TUN2SOCKS_TUN_DEV}
TUNADDR=${TUN2SOCKS_TUN_ADDR}
EOF
}

write_poststart_script() {
  log "Writing /usr/local/bin/tun2socks-poststart.sh"
  cat > /usr/local/bin/tun2socks-poststart.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Expects EnvironmentFile=/etc/default/tun2socks
: "${SSIP:?}"
: "${IFACE:?}"
: "${TUNDEV:?}"

MIP=$(ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
if [[ -z "${MIP}" ]]; then
  echo "[tun2socks-poststart] ERROR: cannot detect default gateway (MIP)" >&2
  exit 1
fi

LIP=$(ip -4 addr show dev "${IFACE}" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
if [[ -z "${LIP}" ]]; then
  echo "[tun2socks-poststart] ERROR: cannot detect local IPv4 on IFACE=${IFACE}" >&2
  exit 1
fi

# Ensure primary route via IFACE exists as fallback
ip route del default dev "${IFACE}" 2>/dev/null || true
ip route replace default via "${MIP}" dev "${IFACE}" metric 200

# Policy routing table for local IP
ip rule add from "${LIP}" table lip 2>/dev/null || true
ip route replace default via "${MIP}" dev "${IFACE}" table lip

# Route to SS server directly via IFACE (so we don't tunnel the tunnel)
ip route replace "${SSIP}/32" via "${MIP}" dev "${IFACE}"

# Primary default route via tun
ip route replace default dev "${TUNDEV}" metric 50
EOF
  chmod +x /usr/local/bin/tun2socks-poststart.sh
}

write_service() {
  log "Writing /etc/systemd/system/tun2socks.service"
  cat > /etc/systemd/system/tun2socks.service <<'EOF'
[Unit]
Description=Tun2Socks
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/default/tun2socks

ExecStartPre=-/sbin/ip tuntap add mode tun dev ${TUNDEV}
ExecStartPre=/sbin/ip addr replace ${TUNADDR} dev ${TUNDEV}
ExecStartPre=/sbin/ip link set dev ${TUNDEV} up

ExecStart=/usr/local/bin/tun2socks -device tun://${TUNDEV} -proxy ss://${SSMETHOD}:${SSPASSWORD}@${SSIP}:${SSPORT}

ExecStartPost=/usr/local/bin/tun2socks-poststart.sh

ExecStopPost=-/sbin/ip r flush table lip
ExecStopPost=-/sbin/ip rule delete table lip
ExecStopPost=-/sbin/ip link set dev ${TUNDEV} down
ExecStopPost=-/sbin/ip link del dev ${TUNDEV}
ExecStopPost=-/sbin/ip r del ${SSIP}/32 dev ${IFACE}

Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

enable_service() {
  log "Reloading systemd and enabling tun2socks"
  systemctl daemon-reload
  systemctl enable --now tun2socks
  systemctl restart tun2socks
  systemctl --no-pager --full status tun2socks || true

  log "Routes (main):"
  ip route show || true
  log "Routes (table lip):"
  ip route show table lip || true
}

main() {
  require_root
  load_env "${1:-}"
  install_packages
  install_go
  build_and_install_tun2socks
  enable_ip_forward
  ensure_rt_table
  write_defaults
  write_poststart_script
  write_service
  enable_service
  log "Done."
}

main "$@"
