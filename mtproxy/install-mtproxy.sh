#!/usr/bin/env bash
set -euo pipefail

# MTProto Proxy (MTProxy) installer for Ubuntu/Debian.
# Assumptions:
# - Docker is already installed and running.
# - You have root/sudo.
# - Firewall is managed externally or you will open the chosen port yourself.
#
# Usage:
#   sudo ./install-mtproxy.sh
#   sudo PORT=4443 ./install-mtproxy.sh
#
# Output:
# - Prints a ready Telegram link: tg://proxy?server=...&port=...&secret=...

NAME="mtproto-proxy"
IMAGE="telegrammessenger/proxy:latest"
PORT="${PORT:-8443}"

SECRET_DIR="/opt/mtproxy"
SECRET_FILE="${SECRET_DIR}/secret.hex"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

need_cmd docker
need_cmd curl
need_cmd xxd

if [[ ${EUID:-1000} -ne 0 ]]; then
  echo "Run as root (or via sudo): sudo PORT=${PORT} $0" >&2
  exit 1
fi

echo "[1/5] Checking if container '${NAME}' already exists..."
if docker ps -a --format '{{.Names}}' | grep -qx "${NAME}"; then
  echo "Container '${NAME}' already exists. For safety, this script will not replace it."
  echo "If you want to recreate it, do it manually:"
  echo "  sudo docker stop ${NAME}"
  echo "  sudo docker rm ${NAME}"
  echo "Then rerun this script." 
  exit 2
fi

echo "[2/5] Creating secret (persisted at ${SECRET_FILE})..."
install -d -m 0700 "${SECRET_DIR}"

if [[ -f "${SECRET_FILE}" ]]; then
  SECRET="$(tr -d '\n\r ' < "${SECRET_FILE}")"
  echo "Using existing secret from ${SECRET_FILE}"
else
  SECRET="$(head -c 16 /dev/urandom | xxd -ps)"
  echo -n "${SECRET}" > "${SECRET_FILE}"
  chmod 600 "${SECRET_FILE}"
  echo "Generated new secret and saved to ${SECRET_FILE}"
fi

echo "[3/5] Pulling image (recommended)..."
docker pull "${IMAGE}" >/dev/null

echo "[4/5] Starting MTProto Proxy on port ${PORT}..."
# Host port PORT -> container port 443

docker run -d --name "${NAME}" \
  -p "${PORT}:443" \
  -e "SECRET=${SECRET}" \
  -e "WORKERS=2" \
  --restart unless-stopped \
  "${IMAGE}" >/dev/null

echo "[5/5] Building Telegram link..."
PUB_IP="$(curl -4 -fsS https://api.ipify.org || true)"

if [[ -z "${PUB_IP}" ]]; then
  echo "WARNING: could not detect public IPv4 automatically."
  echo "Build the link manually:"
  echo "tg://proxy?server=<YOUR_SERVER_IP>&port=${PORT}&secret=${SECRET}"
else
  echo
  echo "MTProto Proxy is up."
  echo "Secret: ${SECRET}"
  echo
  echo "Telegram link:"
  echo "tg://proxy?server=${PUB_IP}&port=${PORT}&secret=${SECRET}"
fi

echo
echo "Useful commands:"
echo "  sudo docker ps"
echo "  sudo docker logs ${NAME} --tail 80"
