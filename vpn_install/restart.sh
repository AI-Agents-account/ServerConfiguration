#!/usr/bin/env bash
set -euo pipefail

echo "Restarting services (nginx, trusttunnel, sing-box)..."
# nginx is optional but used for local fallback content / ACME flows in some setups
sudo systemctl restart nginx || true
sudo systemctl restart trusttunnel || true
sudo systemctl restart sing-box || true

echo "Statuses:"
sudo systemctl --no-pager --full status sing-box 2>/dev/null | sed -n '1,12p' || true
sudo systemctl --no-pager --full status trusttunnel 2>/dev/null | sed -n '1,12p' || true
sudo systemctl --no-pager --full status nginx 2>/dev/null | sed -n '1,12p' || true

echo "Done." 
