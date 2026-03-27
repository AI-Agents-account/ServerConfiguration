#!/usr/bin/env bash
set -euo pipefail

PROJECTS_DIR="/usr/local/projects"
WG_DIR="${PROJECTS_DIR}/wireguard"
WG_URL="https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

log() { echo "[start.sh] $*"; }

install_prereqs() {
  log "Updating apt indexes..."
  apt-get update -y

  log "Upgrading installed packages (non-interactive)..."
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

  log "Installing prerequisites..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    git \
    gnupg \
    lsb-release \
    inetutils-traceroute
}

install_docker() {
  log "Installing Docker Engine + Compose plugin (official Docker repo)..."

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  # Detect codename (focal/jammy/etc.)
  . /etc/os-release
  CODENAME="${VERSION_CODENAME:-focal}"
  ARCH="$(dpkg --print-architecture)"

  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker

  # Optional: add invoking user to docker group
  if [[ -n "${SUDO_USER:-}" ]]; then
    if ! getent group docker >/dev/null; then
      groupadd docker || true
    fi
    usermod -aG docker "${SUDO_USER}" || true
    log "Added ${SUDO_USER} to docker group (will take effect after re-login)."
  fi

  log "Docker version: $(docker --version || true)"
  log "Docker Compose plugin: $(docker compose version || true)"
}

download_wireguard_installer() {
  log "Ensuring projects directory exists: ${PROJECTS_DIR}"
  mkdir -p "${PROJECTS_DIR}"

  log "Downloading WireGuard installer into ${WG_DIR}"
  mkdir -p "${WG_DIR}"
  curl -fsSL "${WG_URL}" -o "${WG_DIR}/wireguard-install.sh"
  chmod +x "${WG_DIR}/wireguard-install.sh"

  log "WireGuard installer saved to: ${WG_DIR}/wireguard-install.sh"
}

main() {
  require_root
  install_prereqs
  install_docker
  download_wireguard_installer
  log "Done."
}

main "$@"
