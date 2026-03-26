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

if [[ -z "${SSIP}" || -z "${SSPORT}" ]]; then
  echo "ERROR: TUN_SSIP/TUN_SSPORT must be set in ${ENV_FILE}" >&2
  exit 1
fi

echo "Checking TCP reachability of server2 Shadowsocks: ${SSIP}:${SSPORT}"

if timeout 3 bash -c 'cat < /dev/null > /dev/tcp/'"${SSIP}"'/'"${SSPORT}"''; then
  echo "OK: ${SSIP}:${SSPORT} is reachable from this server"
  exit 0
else
  echo "FAIL: cannot connect to ${SSIP}:${SSPORT}" >&2
  echo "Check on server2:" >&2
  echo "  - shadowsocks-libev is running" >&2
  echo "  - your server1 public IP is in nft allowlist (ALLOWED_SPROXY)" >&2
  exit 2
fi
