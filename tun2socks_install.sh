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

install_poststart_script() {
  log "Installing tun2socks-poststart.sh to /usr/local/bin"

  local src_dir
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ ! -f "${src_dir}/tun2socks-poststart.sh" ]]; then
    echo "ERROR: tun2socks-poststart.sh not found next to tun2socks_install.sh" >&2
    exit 1
  fi

  install -m 0755 "${src_dir}/tun2socks-poststart.sh" /usr/local/bin/tun2socks-poststart.sh
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

self_check() {
  log "Self-check: verifying that default route is via ${TUN2SOCKS_TUN_DEV}"

  ip link show "${TUN2SOCKS_TUN_DEV}" || true

  # Determine which interface kernel will actually use for a public IP
  local dev
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')

  if [[ "${dev:-}" != "${TUN2SOCKS_TUN_DEV}" ]]; then
    echo "[tun2socks_install.sh] FAIL: ip route get 1.1.1.1 uses dev=${dev:-<none>} (expected ${TUN2SOCKS_TUN_DEV})." >&2
    echo "[tun2socks_install.sh] Hint: check server2 allowlist (nft ALLOWED_SPROXY) and Shadowsocks reachability, then restart tun2socks." >&2
    return 1
  fi

  log "OK: ip route get 1.1.1.1 uses dev=${dev}"
  return 0
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

  self_check
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
  install_poststart_script
  write_service
  enable_service
  log "Done."
}

main "$@"
