#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
ENV_FILE="${2:-server1/.env}"

usage() {
  cat <<'EOF'
Usage:
  bash ./server1/setup.sh safe [server1/.env]
  bash ./server1/setup.sh full [server1/.env]
  bash ./server1/setup.sh split [server1/.env]
EOF
}

case "$MODE" in
  safe|full|split) ;;
  *)
    usage
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/install_tun2socks_binary.sh"
bash "$SCRIPT_DIR/install_sslocal.sh" "$ENV_FILE"

case "$MODE" in
  safe)
    bash "$SCRIPT_DIR/install_safe_mode.sh" "$ENV_FILE"
    ;;
  full)
    bash "$SCRIPT_DIR/install_full_tunnel_mode.sh" "$ENV_FILE"
    ;;
  split)
    bash "$SCRIPT_DIR/install_split_mode.sh" "$ENV_FILE"
    ;;
esac

echo "[setup] Done: mode=$MODE env=$ENV_FILE"
