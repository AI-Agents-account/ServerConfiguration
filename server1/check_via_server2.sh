#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"
MODE="${2:-safe}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC2046
export $(grep -v '^#' "$ENV_FILE" | xargs -d '\n' || true)

: "${TUN_SSIP:?TUN_SSIP is required}"
: "${TUN_SSPORT:=6666}"
: "${LOCAL_SOCKS_ADDR:=127.0.0.1}"
: "${LOCAL_SOCKS_PORT:=1080}"

mode="$(echo "$MODE" | tr '[:upper:]' '[:lower:]')"

echo "[1/5] TCP reachability to server2 Shadowsocks: ${TUN_SSIP}:${TUN_SSPORT}"
if timeout 5 bash -c 'cat < /dev/null > /dev/tcp/'"${TUN_SSIP}"'/'"${TUN_SSPORT}"''; then
  echo "OK"
else
  echo "FAIL: cannot connect to ${TUN_SSIP}:${TUN_SSPORT}" >&2
  exit 2
fi

echo "[2/5] Local SOCKS check via ss-local"
SOCKS_IP="$(curl -4 --socks5-hostname "${LOCAL_SOCKS_ADDR}:${LOCAL_SOCKS_PORT}" -s --max-time 20 https://ifconfig.me || true)"
[[ -n "$SOCKS_IP" ]] || { echo "FAIL: local SOCKS test failed" >&2; exit 3; }
echo "OK: SOCKS egress IP = $SOCKS_IP"

echo "[3/5] tun2socks service state"
systemctl is-active --quiet tun2socks-server2.service || { echo "FAIL: tun2socks-server2.service is not active" >&2; exit 4; }
echo "OK"

echo "[4/5] tun0 state"
ip -br addr show "${TUN2SOCKS_TUN_DEV:-tun0}" || true

echo "[5/5] mode-specific smoke test: $mode"
case "$mode" in
  safe)
    command -v via-server2 >/dev/null 2>&1 || { echo "FAIL: via-server2 wrapper not found" >&2; exit 5; }
    IP_OUT="$(via-server2 curl -4 -s --max-time 20 https://ifconfig.me || true)"
    [[ -n "$IP_OUT" ]] || { echo "FAIL: safe-mode tunnel test failed" >&2; exit 6; }
    echo "OK: safe-mode egress IP = $IP_OUT"
    ;;
  full)
    IP_OUT="$(curl -4 -s --max-time 20 https://ifconfig.me || true)"
    [[ -n "$IP_OUT" ]] || { echo "FAIL: full-tunnel test failed" >&2; exit 7; }
    echo "OK: full-tunnel egress IP = $IP_OUT"
    ;;
  *)
    echo "ERROR: mode must be safe or full" >&2
    exit 8
    ;;
esac
