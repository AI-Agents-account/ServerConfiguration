#!/usr/bin/env bash
set -euo pipefail

log() { echo "[install_singbox] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

main() {
  require_root

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    jq \
    tar

  local arch sb_arch url bin_name
  arch="$(dpkg --print-architecture)"

  case "$arch" in
    amd64) sb_arch="linux-amd64" ;;
    arm64) sb_arch="linux-arm64" ;;
    *) echo "Unsupported arch: $arch" >&2; exit 1 ;;
  esac

  # Version 1.13.6 is stable and supports rule_set
  local version="1.13.6"
  
  if command -v sing-box >/dev/null 2>&1; then
    local current_version
    current_version=$(sing-box version | head -n1 | awk '{print $3}')
    if [[ "$current_version" == "$version" ]]; then
      log "sing-box $version already installed."
      return
    fi
  fi

  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-${sb_arch}.tar.gz"

  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' EXIT

  log "Downloading $url"
  curl -fL "$url" -o "$tmpd/sing-box.tar.gz"
  tar -xzf "$tmpd/sing-box.tar.gz" -C "$tmpd"

  bin_name="$(find "$tmpd" -type f -name "sing-box" | head -n1)"
  [[ -n "$bin_name" ]] || { echo "ERROR: extracted sing-box binary not found" >&2; exit 1; }

  install -m 0755 "$bin_name" /usr/local/bin/sing-box
  log "Installed sing-box $(/usr/local/bin/sing-box version | head -n1)"

  mkdir -p /etc/sing-box/
  mkdir -p /var/lib/sing-box/
}

main "$@"
