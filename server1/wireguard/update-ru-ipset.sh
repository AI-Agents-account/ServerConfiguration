#!/usr/bin/env bash
# /usr/local/bin/update-ru-ipset.sh
# Maintained by OpenClaw - WireGuard RU Split Routing

set -euo pipefail

IPSET_NAME="ru_cidrs"
RU_ZONE_URL="https://www.ipdeny.com/ipblocks/data/countries/ru.zone"
TMP_FILE="/tmp/ru.zone"

# Ensure ipset exists
if ! ipset list "$IPSET_NAME" >/dev/null 2>&1; then
    ipset create "$IPSET_NAME" hash:net -!
fi

# Download fresh list
if curl -fsSL "$RU_ZONE_URL" -o "$TMP_FILE"; then
    # Use a temporary ipset for atomic swap
    TMP_IPSET="${IPSET_NAME}_new"
    ipset create "$TMP_IPSET" hash:net -!
    ipset flush "$TMP_IPSET"
    
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        ipset add "$TMP_IPSET" "$line" -!
    done < "$TMP_FILE"
    
    # Swap
    ipset swap "$IPSET_NAME" "$TMP_IPSET"
    ipset destroy "$TMP_IPSET"
    rm -f "$TMP_FILE"
    echo "$(date): RU ipset updated successfully."
else
    echo "$(date): Failed to download RU zones." >&2
    exit 1
fi
