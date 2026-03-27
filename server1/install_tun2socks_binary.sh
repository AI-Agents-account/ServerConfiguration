#!/usr/bin/env bash
set -euo pipefail

log() { echo "[install_tun2socks_binary] $*"; }

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
    unzip \
    shadowsocks-libev

  local arch tun_arch url bin
  arch="$(dpkg --print-architecture)"

  case "$arch" in
    amd64) tun_arch="linux-amd64" ;;
    arm64) tun_arch="linux-arm64" ;;
    *) echo "Unsupported arch: $arch" >&2; exit 1 ;;
  esac

  url="$(curl -fsSL https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | jq -r ".assets[] | select(.name|test(\"${tun_arch}\")) | .browser_download_url" | head -n1)"
  [[ -n "$url" ]] || { echo "ERROR: failed to resolve tun2socks download URL" >&2; exit 1; }

  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' EXIT

  log "Downloading $url"
  curl -fL "$url" -o "$tmpd/tun2socks.zip"
  unzip -o "$tmpd/tun2socks.zip" -d "$tmpd" >/dev/null

  bin="$(find "$tmpd" -maxdepth 1 -type f -name 'tun2socks-*' | head -n1)"
  [[ -n "$bin" ]] || { echo "ERROR: extracted tun2socks binary not found" >&2; exit 1; }

  install -m 0755 "$bin" /usr/local/bin/tun2socks
  /usr/local/bin/tun2socks --help >/dev/null

  log "Installed /usr/local/bin/tun2socks"
}

main "$@"
