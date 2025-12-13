#!/bin/bash

# Usage: clone-peers.sh <compose-file> <target-host> [target-compose-file]
#   compose-file: Path to compose file (without .yml) for source node
#   target-host: Target host identifier (e.g., "2" for 2.stakesquid.eu)
#   target-compose-file: Optional. If provided, use this compose file for target node
#                        If not provided, use the same compose file for both source and target

if [ $# -lt 2 ]; then
    echo "Usage: $0 <compose-file> <target-host> [target-compose-file]"
    echo "  compose-file: Path to compose file (without .yml) for source node"
    echo "  target-host: Target host identifier (e.g., '2' for 2.stakesquid.eu)"
    echo "  target-compose-file: Optional. If provided, use this compose file for target node"
    exit 1
fi

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

COMPOSE_FILE="$1"
TARGET_HOST="$2"
TARGET_COMPOSE_FILE="${3:-$COMPOSE_FILE}"  # Use source compose file if not provided

# Check if DOMAIN is set
if [ -z "$DOMAIN" ]; then
    echo "Error: DOMAIN variable not found in $BASEPATH/.env" >&2
    exit 1
fi

# Function to extract RPC path from compose file
extract_rpc_path() {
    local compose_path="$1"
    local full_path="$BASEPATH/${compose_path}.yml"
    
    if [ ! -f "$full_path" ]; then
        echo "Error: Compose file not found: $full_path" >&2
        return 1
    fi
    
    # Get all services from compose file
    services=$(cat "$full_path" | yaml2json - 2>/dev/null | jq -r '.services | keys | .[]' 2>/dev/null)
    
    if [ -z "$services" ]; then
        echo "Error: No services found in compose file: $full_path" >&2
        return 1
    fi
    
    # Find the first service with a stripprefix.prefixes label
    for service in $services; do
        labels=($(cat "$full_path" | yaml2json - 2>/dev/null | jq -r ".services[\"$service\"].labels[]?" 2>/dev/null))
        
        for label in "${labels[@]}"; do
            if [[ "$label" == *"stripprefix.prefixes"* ]]; then
                # Extract path from label
                # Format examples:
                #   prefixes=/plume-mainnet-archive
                #   prefixes=`/plume-mainnet-archive`
                #   prefixes="/plume-mainnet-archive"
                path=$(echo "$label" | sed -n 's/.*prefixes=\([^ `"]*\).*/\1/p')
                # Remove backticks and quotes if present
                path=$(echo "$path" | sed 's|`||g' | sed 's|"||g' | sed "s|'||g")
                # Ensure path starts with /
                if [[ ! "$path" =~ ^/ ]]; then
                    path="/$path"
                fi
                # Remove trailing slash if present
                path=$(echo "$path" | sed 's|/$||')
                if [ -n "$path" ] && [ "$path" != "/" ]; then
                    echo "$path"
                    return 0
                fi
            fi
        done
    done
    
    echo "Error: Could not extract RPC path from compose file: $full_path" >&2
    return 1
}

# Extract RPC paths
echo "Extracting RPC path from source compose file: $COMPOSE_FILE"
SOURCE_RPC_PATH=$(extract_rpc_path "$COMPOSE_FILE")
if [ $? -ne 0 ]; then
    exit 1
fi

echo "Extracting RPC path from target compose file: $TARGET_COMPOSE_FILE"
TARGET_RPC_PATH=$(extract_rpc_path "$TARGET_COMPOSE_FILE")
if [ $? -ne 0 ]; then
    exit 1
fi

# Construct URLs
SOURCE_URL="https://${DOMAIN}${SOURCE_RPC_PATH}"
TARGET_URL="https://${TARGET_HOST}.stakesquid.eu${TARGET_RPC_PATH}"

echo "=========================================="
echo "DEBUG: Configuration"
echo "=========================================="
echo "Source RPC path: $SOURCE_RPC_PATH"
echo "Target RPC path: $TARGET_RPC_PATH"
echo "Source domain: $DOMAIN"
echo "Target host: $TARGET_HOST.stakesquid.eu"
echo ""
echo "Source URL: $SOURCE_URL"
echo "Target URL: $TARGET_URL"
echo ""
echo "=========================================="
echo "DEBUG: Manual curl commands"
echo "=========================================="
echo "To fetch peers from source, run:"
echo "curl --ipv4 -X POST -H \"Content-Type: application/json\" --data '{\"jsonrpc\":\"2.0\",\"method\":\"admin_peers\",\"params\":[],\"id\":1}' \"$SOURCE_URL\""
echo ""
echo "To add a peer to target, run:"
echo "curl --ipv4 -X POST -H \"Content-Type: application/json\" --data '{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"<enode>\"],\"id\":1}' \"$TARGET_URL\""
echo "=========================================="
echo ""

# Run the command to get the list of enode strings from source
echo "Fetching peers from source node..."
echo "DEBUG: Executing: curl --ipv4 -X POST -H \"Content-Type: application/json\" --data '{\"jsonrpc\":\"2.0\",\"method\":\"admin_peers\",\"params\":[],\"id\":1}' \"$SOURCE_URL\""
enodes=$(curl --ipv4 -X POST -H "Content-Type: application/json" --silent --data "{\"jsonrpc\":\"2.0\",\"method\":\"admin_peers\",\"params\":[],\"id\":1}" "$SOURCE_URL" | jq -r '.result[].enode' 2>/dev/null)

# Check if the command was successful
if [ $? -ne 0 ] || [ -z "$enodes" ]; then
    echo "Error: Failed to fetch enode list from source node."
    exit 1
fi

peer_count=$(echo "$enodes" | grep -v '^$' | wc -l | tr -d ' ')
echo "Found $peer_count peer(s) to copy"
echo ""

# Iterate over each enode and add it to the target node
success_count=0
failed_count=0

while IFS= read -r enode; do
    if [ -z "$enode" ]; then
        continue
    fi
    
    echo "Adding peer: ${enode:0:50}..."
    echo "DEBUG: Executing: curl --ipv4 -X POST -H \"Content-Type: application/json\" --data '{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"${enode}\"],\"id\":1}' \"$TARGET_URL\""
    result=$(curl --ipv4 -X POST -H "Content-Type: application/json" --silent --data "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"${enode}\"],\"id\":1}" "$TARGET_URL" | jq -r '.result' 2>/dev/null)
    
    if [ "$result" = "true" ] || [ "$result" = "null" ]; then
        echo "  ✓ Success"
        success_count=$((success_count + 1))
    else
        echo "  ✗ Failed: $result"
        failed_count=$((failed_count + 1))
    fi
done <<< "$enodes"

echo ""
echo "Summary:"
echo "  Successful: $success_count/$peer_count"
if [ $failed_count -gt 0 ]; then
    echo "  Failed: $failed_count/$peer_count"
    exit 1
fi
