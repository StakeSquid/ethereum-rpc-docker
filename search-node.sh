#!/bin/bash
# Find compose files matching search criteria that have exactly one node running
# 
# Usage:
#   ./search-node.sh <network> <chain> <type> [client] [node]
#
# Required parameters:
#   network: Network name (e.g., ethereum, arbitrum, polygon)
#   chain:   Chain name (e.g., mainnet, sepolia, one)
#   type:    Database type (archive, pruned, minimal, full)
#
# Optional parameters:
#   client:  Client name (e.g., geth, erigon3, reth, besu)
#   node:    Node implementation (e.g., nimbus, lighthouse, dtl)
#
# Output:
#   Prints compose file paths (without .yml extension) that match the search
#   and have exactly one node running on this machine, one per line

dir="$(dirname "$0")"

# Check if docker compose is available
if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
elif command -v docker &> /dev/null && docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    echo "Error: Neither docker-compose nor docker compose is installed" >&2
    exit 1
fi

# Check if search-compose.sh exists
if [ ! -f "$dir/search-compose.sh" ]; then
    echo "Error: search-compose.sh not found at $dir/search-compose.sh" >&2
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

# Parse command-line arguments
if [ $# -lt 3 ]; then
    echo "Usage: $0 <network> <chain> <type> [client] [node]" >&2
    echo "" >&2
    echo "Required parameters:" >&2
    echo "  network: Network name (e.g., ethereum, arbitrum, polygon)" >&2
    echo "  chain:   Chain name (e.g., mainnet, sepolia, one)" >&2
    echo "  type:    Database type (archive, pruned, minimal, full)" >&2
    echo "" >&2
    echo "Optional parameters:" >&2
    echo "  client:  Client name (e.g., geth, erigon3, reth, besu)" >&2
    echo "  node:    Node implementation (e.g., nimbus, lighthouse, dtl)" >&2
    exit 1
fi

# Call search-compose.sh with the same arguments
search_results=$("$dir/search-compose.sh" "$@")

if [ $? -ne 0 ] || [ -z "$search_results" ]; then
    # No results found from search-compose
    exit 1
fi

# Change to the rpc directory to run docker compose commands
cd "$dir" || exit 1

# Process each result from search-compose
found_match=false
while IFS= read -r compose_path; do
    # Skip empty lines
    [ -z "$compose_path" ] && continue
    
    # Check if the compose file exists
    compose_file="${compose_path}.yml"
    if [ ! -f "$compose_file" ]; then
        continue
    fi
    
    # Check if base.yml and rpc.yml exist (required for docker compose)
    if [ ! -f "base.yml" ] || [ ! -f "rpc.yml" ]; then
        echo "Warning: base.yml or rpc.yml not found, skipping $compose_file" >&2
        continue
    fi
    
    # Count running containers for this compose file
    # Use docker compose ps to check running containers
    ps_output=$($COMPOSE_CMD -f base.yml -f rpc.yml -f "$compose_file" ps 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$ps_output" ]; then
        # If docker compose ps fails or returns nothing, skip this file
        continue
    fi
    
    # Count the number of running services
    # Look for lines containing "Up" (running status) but exclude the header
    # The format is typically: NAME IMAGE COMMAND SERVICE CREATED STATUS PORTS
    # We want lines that have "Up" in the STATUS column
    running_count=$(echo "$ps_output" | awk '/Up/ && !/NAME/ {count++} END {print count+0}' || echo "0")
    
    # If exactly one node is running, output the compose path
    if [ "$running_count" -eq 1 ]; then
        echo "$compose_path"
        found_match=true
    fi
done <<< "$search_results"

if [ "$found_match" = false ]; then
    exit 1
fi

