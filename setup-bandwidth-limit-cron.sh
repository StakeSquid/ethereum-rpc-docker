#!/bin/bash
# Helper script to set up cronjob for bandwidth limiting
# This will add a cronjob entry to apply bandwidth limits every 5 minutes
#
# Usage: ./setup-bandwidth-limit-cron.sh <compose-file> [BANDWIDTH_LIMIT]
# Example: ./setup-bandwidth-limit-cron.sh rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace.yml
# Example: ./setup-bandwidth-limit-cron.sh rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace.yml 20mbit

set -euo pipefail

BASEPATH="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$BASEPATH/limit-bandwidth.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <compose-file>"
    echo ""
    echo "This script sets up a cronjob to apply bandwidth limits every 5 minutes."
    echo "The cronjob will run: $SCRIPT_PATH <compose-file> start"
    echo ""
    echo "Example:"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace.yml"
    exit 1
fi

COMPOSE_FILE="$1"
BANDWIDTH_LIMIT="${2:-100mbit}"  # Default to 100mbit if not specified

# Resolve compose file path
if [ ! -f "$COMPOSE_FILE" ]; then
    if [ -f "$BASEPATH/$COMPOSE_FILE" ]; then
        COMPOSE_FILE="$BASEPATH/$COMPOSE_FILE"
    else
        echo "Error: Compose file not found: $1"
        exit 1
    fi
fi

COMPOSE_FILE=$(realpath "$COMPOSE_FILE")
SCRIPT_PATH=$(realpath "$SCRIPT_PATH")

# Create cronjob entry with bandwidth limit
if [ "$BANDWIDTH_LIMIT" != "100mbit" ]; then
    CRON_ENTRY="*/5 * * * * sudo BANDWIDTH_LIMIT=$BANDWIDTH_LIMIT $SCRIPT_PATH $COMPOSE_FILE start"
else
    CRON_ENTRY="*/5 * * * * sudo $SCRIPT_PATH $COMPOSE_FILE start"
fi

echo "Setting up cronjob for bandwidth limiting..."
echo ""
echo "Compose file: $COMPOSE_FILE"
echo "Script: $SCRIPT_PATH"
echo "Bandwidth limit: $BANDWIDTH_LIMIT per port"
echo "Cron entry: $CRON_ENTRY"
echo ""

# Check if cronjob already exists
if crontab -l 2>/dev/null | grep -qF "$COMPOSE_FILE start"; then
    echo "Warning: A cronjob for this compose file already exists."
    echo ""
    echo "Current crontab entries:"
    crontab -l 2>/dev/null | grep "$COMPOSE_FILE" || true
    echo ""
    read -p "Do you want to replace it? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
    
    # Remove existing entry
    crontab -l 2>/dev/null | grep -vF "$COMPOSE_FILE start" | crontab -
fi

# Add new cronjob
(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -

echo "✓ Cronjob added successfully!"
echo ""
echo "To view your crontab:"
echo "  crontab -l"
echo ""
echo "To remove this cronjob:"
echo "  crontab -e"
echo "  (then delete the line containing: $COMPOSE_FILE start)"
echo ""
echo "To test the script manually:"
echo "  sudo $SCRIPT_PATH $COMPOSE_FILE start"
