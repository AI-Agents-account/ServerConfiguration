#!/usr/bin/env bash
set -euo pipefail

fail() { echo "[FAIL] $*" >&2; exit 1; }
ok() { echo "[OK] $*"; }

source /etc/vpn_settings.env 2>/dev/null || true

ok "Checking services..."
sudo systemctl is-active --quiet sing-box || fail "sing-box is not active"
sudo systemctl is-active --quiet trusttunnel || fail "trusttunnel is not active"

ok "Checking listeners (expected: :443 tcp+udp, :9443 loopback)..."
sudo ss -lntup | grep -qE 'LISTEN.*\*:443' || fail "no TCP :443 listener"
sudo ss -lnup  | grep -qE '\*:443' || fail "no UDP :443 listener"
sudo ss -lntup | grep -qE '127\.0\.0\.1:9443' || fail "no TCP 127.0.0.1:9443 listener"

if [[ -n "${TRUSTTUNNEL_DOMAIN:-}" ]]; then
  ok "Checking TrustTunnel TLS issuer on 127.0.0.1:9443 (should be Let's Encrypt)..."
  ISSUER=$(echo | openssl s_client -connect 127.0.0.1:9443 -servername "$TRUSTTUNNEL_DOMAIN" 2>/dev/null | openssl x509 -noout -issuer || true)
  echo "issuer: $ISSUER"
  echo "$ISSUER" | grep -qi "Let's Encrypt" || fail "TrustTunnel does not present a Let's Encrypt cert"
fi

# Quick e2e check for VLESS/Trojan/HY2 using generated admin client configs (local proxy mode)
CLIENT_DIR=/root/vpn_clients/admin
if [[ -d "$CLIENT_DIR" ]]; then
  for cfg in "$CLIENT_DIR"/singbox_vless.json "$CLIENT_DIR"/singbox_trojan.json "$CLIENT_DIR"/singbox_hysteria2.json; do
    [[ -f "$cfg" ]] || continue
    ok "E2E: $cfg -> curl ipify via local proxy (127.0.0.1:1080)"
    /usr/local/bin/sing-box run -c "$cfg" >/tmp/sb_check.log 2>&1 &
    PID=$!
    sleep 1
    IP=$(curl -s --max-time 10 --proxy http://127.0.0.1:1080 https://api.ipify.org?format=json || true)
    kill "$PID" 2>/dev/null || true
    sleep 0.2
    echo "ipify: $IP"
    [[ -n "$IP" ]] || fail "curl via proxy failed for $cfg"
  done
else
  echo "[WARN] $CLIENT_DIR not found; skipping client e2e checks"
fi

ok "All checks passed."
