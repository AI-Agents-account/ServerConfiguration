#!/usr/bin/env bash
set -euo pipefail

# This script is a wrapper around server1/setup.sh full.
# It is kept for backward compatibility.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/.env}"

bash "$SCRIPT_DIR/setup.sh" full "$ENV_FILE"
