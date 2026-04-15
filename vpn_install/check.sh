#!/usr/bin/env bash
set -euo pipefail

fail() { echo "[FAIL] $*" >&2; exit 1; }
ok() { echo "[OK] $*"; }

# Find a free local TCP port in [1081..1099] for temporary sing-box client checks.
find_free_port() {
  for p in {1081..1099}; do
    if ! ss -lnt | awk '{print $4}' | grep -q ":${p}$"; then
      echo "${p}"
      return 0
    fi
  done
  return 1
}

source /etc/vpn_settings.env 2>/dev/null || true

ok "Checking services..."
sudo systemctl is-active --quiet sing-box || fail "sing-box is not active"

# TrustTunnel may be disabled/optional depending on env; warn instead of fail.
if systemctl list-unit-files | grep -q '^trusttunnel\.service'; then
  sudo systemctl is-active --quiet trusttunnel || fail "trusttunnel is not active"
else
  echo "[WARN] trusttunnel.service not installed; skipping"
fi

sudo systemctl is-active --quiet hysteria || fail "hysteria (Hysteria2 standalone) is not active"

ok "Checking listeners (expected: TCP :443 by sing-box, UDP :443 by hysteria; TrustTunnel on 127.0.0.1:9443 if enabled)..."
sudo ss -lntup | grep -qE 'LISTEN.*\*:443' || fail "no TCP :443 listener"
# Ensure UDP :443 is served by hysteria (not sing-box)
sudo ss -lnup | grep -qE '\*:443' || fail "no UDP :443 listener"
sudo ss -lnup | grep -qE '\*:443.*hysteria' || fail "UDP :443 is not owned by hysteria"
if systemctl list-unit-files | grep -q '^trusttunnel\.service'; then
  sudo ss -lntup | grep -qE '127\.0\.0\.1:9443' || fail "no TCP 127.0.0.1:9443 listener"
fi

if [[ -n "${TRUSTTUNNEL_DOMAIN:-}" ]]; then
  ok "Checking TrustTunnel TLS issuer on 127.0.0.1:9443 (Let's Encrypt expected when REQUIRE_TRUSTTUNNEL_LE=1)..."
  ISSUER=$(echo | openssl s_client -connect 127.0.0.1:9443 -servername "$TRUSTTUNNEL_DOMAIN" 2>/dev/null | openssl x509 -noout -issuer || true)
  echo "issuer: $ISSUER"

  if [[ "${REQUIRE_TRUSTTUNNEL_LE:-1}" == "1" ]]; then
    echo "$ISSUER" | grep -qi "Let's Encrypt" || fail "TrustTunnel does not present a Let's Encrypt cert (REQUIRE_TRUSTTUNNEL_LE=1)"
  else
    if ! echo "$ISSUER" | grep -qi "Let's Encrypt"; then
      echo "[WARN] TrustTunnel does not present a Let's Encrypt cert (REQUIRE_TRUSTTUNNEL_LE=0; self-signed/fallback allowed)"
    fi
  fi
fi

# Quick e2e check for VLESS/Trojan/HY2 using generated admin client configs (local proxy mode)
CLIENT_DIR=/root/vpn_clients/admin
if [[ -d "$CLIENT_DIR" ]]; then
  for cfg in "$CLIENT_DIR"/singbox_vless.json "$CLIENT_DIR"/singbox_trojan.json "$CLIENT_DIR"/singbox_hysteria2.json; do
    [[ -f "$cfg" ]] || continue

    PORT=$(find_free_port || echo "")
    if [[ -z "${PORT}" ]]; then
      echo "[WARN] No free port found in 1081-1099; skipping e2e check for $cfg"
      continue
    fi

    TMP_CFG=$(mktemp /tmp/sb_client_XXXX.json)

    # Rewrite inbound listen_port from 1080 to the chosen free port.
    # If jq is missing or rewrite fails, fall back to original cfg (may conflict with existing 1080 listeners).
    if command -v jq >/dev/null 2>&1; then
      if ! jq --argjson p "${PORT}" '(.inbounds[]? | select(.listen_port == 1080) | .listen_port) |= $p' "$cfg" >"${TMP_CFG}"; then
        echo "[WARN] Failed to rewrite $cfg for port ${PORT}; using original config (may conflict on :1080)"
        cp "$cfg" "${TMP_CFG}"
      fi
    else
      echo "[WARN] jq not found; using original config for $cfg (may conflict on :1080)"
      cp "$cfg" "${TMP_CFG}"
    fi

    ok "E2E: $cfg -> curl ipify via local proxy (127.0.0.1:${PORT})"
    /usr/local/bin/sing-box run -c "${TMP_CFG}" >/tmp/sb_check.log 2>&1 &
    PID=$!
    sleep 1
    IP=$(curl -s --max-time 10 --proxy "http://127.0.0.1:${PORT}" https://api.ipify.org?format=json || true)
    kill "$PID" 2>/dev/null || true
    sleep 0.2
    rm -f "${TMP_CFG}" 2>/dev/null || true

    echo "ipify: $IP"
    [[ -n "$IP" ]] || fail "curl via proxy failed for $cfg"
  done
else
  echo "[WARN] $CLIENT_DIR not found; skipping client e2e checks"
fi

ok "All checks passed."