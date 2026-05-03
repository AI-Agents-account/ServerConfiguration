#!/usr/bin/env bash
set -euo pipefail

# This script is a wrapper around setup.sh split.
# It is kept for backward compatibility.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/.env}"

bash "$SCRIPT_DIR/setup.sh" split "$ENV_FILE"
