#!/bin/bash
# Search for compose files matching specified criteria
# 
# Usage:
#   ./search-compose.sh <network> <chain> <type> [client] [node]
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
#   Prints matching compose file paths (without .yml extension), one per line

dir="$(dirname "$0")"
registry_file="${dir}/compose_registry.json"

if [ ! -f "$registry_file" ]; then
    echo "Error: compose_registry.json not found at $registry_file" >&2
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

network="$1"
chain="$2"
type="$3"
client="${4:-}"
node="${5:-}"

# Build jq filter
condition_parts=(
    ".network == \"$network\""
    ".chain == \"$chain\""
    ".type == \"$type\""
)

if [ -n "$client" ]; then
    condition_parts+=(".client == \"$client\"")
fi

if [ -n "$node" ]; then
    # Handle null node values - if node is specified, it must match (or be null if searching for null)
    if [ "$node" = "null" ] || [ "$node" = "NULL" ]; then
        condition_parts+=(".node == null")
    else
        condition_parts+=(".node == \"$node\"")
    fi
fi

# Join conditions with " and "
condition_str=""
for i in "${!condition_parts[@]}"; do
    if [ $i -eq 0 ]; then
        condition_str="${condition_parts[$i]}"
    else
        condition_str="${condition_str} and ${condition_parts[$i]}"
    fi
done

# Query the registry and extract compose_file paths
jq_filter=".[] | select($condition_str) | .compose_file"

# Execute query and output results
results=$(jq -r "$jq_filter" "$registry_file")

if [ -z "$results" ]; then
    # No results found
    exit 1
else
    # Output each result on a separate line
    echo "$results"
fi

