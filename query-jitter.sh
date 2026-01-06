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
echo "Running 1000 requests..."
echo ""

# Hit the endpoint 1000 times and measure response time distribution
for i in {1..1000}; do
    curl -w "%{time_total}\n" -o /dev/null -s "$RPC_URL" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
done | awk '{
    sum+=$1
    sumsq+=$1*$1
    if(NR==1||$1<min)min=$1
    if($1>max)max=$1
} END {
    if(NR>0) {
        avg=sum/NR
        variance=sumsq/NR-(avg*avg)
        stddev=sqrt(variance)
        print "min:", min*1000, "ms"
        print "avg:", avg*1000, "ms"
        print "max:", max*1000, "ms"
        print "stddev:", stddev*1000, "ms"
        print "count:", NR
    } else {
        print "Error: No successful requests"
    }
}'

