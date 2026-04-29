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

  # Fetch latest release download URL for the architecture
  url="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r ".assets[] | select(.name|test(\"sing-box-.*-${sb_arch}.tar.gz\")) | .browser_download_url" | head -n1)"
  [[ -n "$url" ]] || { echo "ERROR: failed to resolve sing-box download URL" >&2; exit 1; }

  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' EXIT

  log "Downloading $url"
  curl -fL "$url" -o "$tmpd/sing-box.tar.gz"
  tar -xzf "$tmpd/sing-box.tar.gz" -C "$tmpd"

  bin_name="$(find "$tmpd" -type f -name "sing-box" | head -n1)"
  [[ -n "$bin_name" ]] || { echo "ERROR: extracted sing-box binary not found" >&2; exit 1; }

  install -m 0755 "$bin_name" /usr/local/bin/sing-box
  /usr/local/bin/sing-box version >/dev/null

  mkdir -p /etc/sing-box/
  log "Installed /usr/local/bin/sing-box and created /etc/sing-box/"
}

main "$@"
