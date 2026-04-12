#!/usr/bin/env bash
set -euo pipefail

echo "Stopping services (sing-box, trusttunnel, nginx)..."
sudo systemctl stop sing-box || true
sudo systemctl stop trusttunnel || true
sudo systemctl stop nginx || true

echo "Done." 
