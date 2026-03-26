#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-server1/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file not found: ${ENV_FILE}" >&2
  echo "Hint: cp server1/.env.example server1/.env && nano server1/.env" >&2
  exit 1
fi

# Load env (simple KEY=VALUE lines)
# shellcheck disable=SC2046
export $(grep -v '^#' "${ENV_FILE}" | xargs -d '\n' || true)

SSIP="${TUN_SSIP:-}"
SSPORT="${TUN_SSPORT:-}"
TUNDEV="${TUN2SOCKS_TUN_DEV:-tun0}"

if [[ -z "${SSIP}" || -z "${SSPORT}" ]]; then
  echo "ERROR: TUN_SSIP/TUN_SSPORT must be set in ${ENV_FILE}" >&2
  exit 1
fi

echo "[1/3] Checking TCP reachability of server2 Shadowsocks: ${SSIP}:${SSPORT}"
if timeout 3 bash -c 'cat < /dev/null > /dev/tcp/'"${SSIP}"'/'"${SSPORT}"''; then
  echo "OK: ${SSIP}:${SSPORT} is reachable from this server"
else
  echo "FAIL: cannot connect to ${SSIP}:${SSPORT}" >&2
  echo "Check on server2:" >&2
  echo "  - shadowsocks-libev is running" >&2
  echo "  - your server1 public IP is in nft allowlist (ALLOWED_SPROXY)" >&2
  exit 2
fi

echo "[2/3] Restarting tun2socks client on server1"
if ! systemctl restart --now tun2socks; then
  echo "FAIL: cannot start/restart tun2socks service on server1" >&2
  exit 3
fi

echo "[3/3] Verifying routing + doing HTTP request through tun2socks"

DEV_USED=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
if [[ "${DEV_USED:-}" != "${TUNDEV}" ]]; then
  echo "FAIL: ip route get 1.1.1.1 uses dev=${DEV_USED:-<none>} (expected ${TUNDEV})." >&2
  echo "Hint: check allowlist on server2 and restart shadowsocks-libev, then restart tun2socks." >&2
  exit 4
fi

echo "OK: routing uses ${TUNDEV}"

IP_OUT=$(curl -4 --max-time 10 -sS https://api.ipify.org || true)
if [[ -z "${IP_OUT}" ]]; then
  echo "FAIL: HTTP request did not succeed (curl to api.ipify.org)." >&2
  exit 5
fi

echo "OK: HTTP works via tun2socks. Observed public IP: ${IP_OUT}"
