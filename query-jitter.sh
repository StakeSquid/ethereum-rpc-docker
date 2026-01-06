#!/bin/bash

# Script to measure query jitter for a node endpoint
# Usage: query-jitter.sh <node-path> [host]
# Example: query-jitter.sh arb/nitro/everclear-mainnet-nitro-archive-leveldb-hash
# Example: query-jitter.sh arb/nitro/everclear-mainnet-nitro-archive-leveldb-hash 192.168.1.100

if [ -z "$1" ]; then
    echo "Usage: $0 <node-path> [host]"
    echo "Example: $0 arb/nitro/everclear-mainnet-nitro-archive-leveldb-hash"
    echo "Example: $0 arb/nitro/everclear-mainnet-nitro-archive-leveldb-hash 192.168.1.100"
    exit 1
fi

BASEPATH="$(dirname "$0")"
NODE_PATH="$1"
HOST="$2"

# Source .env file if it exists
if [ -f "$BASEPATH/.env" ]; then
    source "$BASEPATH/.env"
fi

# Determine protocol and domain
if [ -n "$NO_SSL" ]; then
    PROTO="http"
    DOMAIN="${DOMAIN:-0.0.0.0}"
else
    PROTO="${PROTO:-https}"
fi

# If host is provided, replace the first segment of DOMAIN with it
if [ -n "$HOST" ]; then
    # Extract the first segment (before first dot) and replace with provided host
    if [[ "$DOMAIN" =~ ^([^.]+)\.(.*)$ ]]; then
        DOMAIN="${HOST}.${BASH_REMATCH[2]}"
    else
        # If no dots, just use the host
        DOMAIN="$HOST"
    fi
fi

# Check if compose file exists
COMPOSE_FILE="$BASEPATH/$NODE_PATH.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: Compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Extract path from compose file (same logic as latest.sh)
pathlist=$(cat "$COMPOSE_FILE" | grep -oP "stripprefix\.prefixes.*?/\K[^\"]+")

if [ -z "$pathlist" ]; then
    echo "Error: Could not extract path from compose file: $COMPOSE_FILE"
    exit 1
fi

# Use the first path found
RPC_PATH=$(echo "$pathlist" | head -n1)

# Build RPC URL
RPC_URL="${PROTO}://${DOMAIN}/${RPC_PATH}"

echo "Testing endpoint: $RPC_URL"
echo "Running 1000 requests with 10 concurrent connections..."
echo ""

# Run hey via docker and show summary output
echo "=== Hey Summary ==="
docker run --rm ricoli/hey -n 1000 -c 10 \
    -m POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" 2>&1

echo ""
echo "=== Detailed Statistics (with stddev) ==="

# Run again with CSV output to calculate stddev
CSV_OUTPUT=$(docker run --rm ricoli/hey -n 1000 -c 10 \
    -m POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    -o csv \
    "$RPC_URL" 2>&1)

# Parse CSV output to calculate statistics
echo "$CSV_OUTPUT" | awk -F',' '
NR > 1 && $1 != "" {
    # CSV format: response-time,status-code,offset
    time = $1
    # Only process numeric values (skip header and non-numeric)
    if (time ~ /^[0-9]/) {
        sum += time
        sumsq += time * time
        if (NR == 2 || time < min) min = time
        if (time > max) max = time
        count++
    }
}
END {
    if (count > 0) {
        avg = sum / count
        variance = sumsq / count - (avg * avg)
        stddev = sqrt(variance)
        print "min:", min * 1000, "ms"
        print "avg:", avg * 1000, "ms"
        print "max:", max * 1000, "ms"
        print "stddev:", stddev * 1000, "ms"
        print "count:", count
    } else {
        print "Error: No successful requests"
    }
}'

# If CSV parsing failed, show some debug info
if [ -z "$CSV_OUTPUT" ] || ! echo "$CSV_OUTPUT" | grep -q "response-time"; then
    echo ""
    echo "Warning: Could not parse CSV output. Showing first few lines:"
    echo "$CSV_OUTPUT" | head -5
fi

