#!/bin/bash

# Script to backup peers from all running nodes
# Can be run as a cronjob to periodically backup peer lists
# Usage: ./backup-peers.sh [backup-directory]

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

# Default backup directory
BACKUP_DIR="${1:-$BASEPATH/peer-backups}"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Timestamp for this backup run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Blacklist for compose files (same as show-status.sh)
blacklist=(
    "drpc.yml" "drpc-free.yml" "drpc-home.yml" # dshackles
    "arbitrum-one-mainnet-arbnode-archive-trace.yml" # always behind and no reference rpc
    "ethereum-beacon-mainnet-lighthouse-pruned-blobs" # can't handle beacon rest api yet
    "rpc.yml" "monitoring.yml" "ftp.yml" "backup-http.yml" "base.yml" # no rpcs
)

# Path blacklist (read from file if it exists)
path_blacklist=()
if [ -f "$BASEPATH/path-blacklist.txt" ]; then
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            path_blacklist+=("$line")
        fi
    done < "$BASEPATH/path-blacklist.txt"
fi

# Protocol and domain settings
if [ -n "$NO_SSL" ]; then
    PROTO="http"
    DOMAIN="${DOMAIN:-0.0.0.0}"
else
    PROTO="https"
fi

# Function to extract RPC paths from a compose file
extract_rpc_paths() {
    local compose_file="$1"
    local full_path="$BASEPATH/${compose_file}"
    
    if [ ! -f "$full_path" ]; then
        return 1
    fi
    
    # Extract paths using grep (same method as peer-count.sh)
    pathlist=$(cat "$full_path" | grep -oP "stripprefix\.prefixes.*?/\K[^\"]+" 2>/dev/null)
    
    if [ -z "$pathlist" ]; then
        return 1
    fi
    
    echo "$pathlist"
}

# Function to check if a path should be included
should_include_path() {
    local path="$1"
    
    for word in "${path_blacklist[@]}"; do
        if echo "$path" | grep -qE "$word"; then
            return 1
        fi
    done
    
    return 0
}

# Function to backup peers from a single RPC endpoint
backup_peers_from_path() {
    local compose_file="$1"
    local path="$2"
    local compose_name="${compose_file%.yml}"
    
    # Sanitize compose name and path for filename
    local safe_compose_name=$(echo "$compose_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
    local safe_path=$(echo "$path" | sed 's|[^a-zA-Z0-9_-]|_|g')
    
    local RPC_URL="${PROTO}://${DOMAIN}${path}"
    
    # Try admin_peers first (returns detailed peer info)
    response=$(curl --ipv4 -L -s -X POST "$RPC_URL" \
        -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' \
        --max-time 10 2>/dev/null)
    
    # Check if we got a valid response
    if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
        peer_count=$(echo "$response" | jq -r '.result | length')
        
        if [ "$peer_count" -gt 0 ]; then
            # Extract enodes
            enodes=$(echo "$response" | jq -r '.result[].enode' 2>/dev/null | grep -v '^$' | grep -v '^null$')
            
            if [ -n "$enodes" ]; then
                # Create backup file
                local backup_file="$BACKUP_DIR/${safe_compose_name}__${safe_path}__${TIMESTAMP}.json"
                
                # Create JSON structure with metadata
                {
                    echo "{"
                    echo "  \"compose_file\": \"$compose_file\","
                    echo "  \"rpc_path\": \"$path\","
                    echo "  \"rpc_url\": \"$RPC_URL\","
                    echo "  \"timestamp\": \"$TIMESTAMP\","
                    echo "  \"peer_count\": $peer_count,"
                    echo "  \"peers\": ["
                    
                    # Write enodes as JSON array
                    first=true
                    while IFS= read -r enode; do
                        if [ -z "$enode" ] || [ "$enode" = "null" ]; then
                            continue
                        fi
                        
                        if [ "$first" = true ]; then
                            first=false
                        else
                            echo ","
                        fi
                        
                        # Escape the enode string for JSON
                        escaped_enode=$(echo "$enode" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
                        echo -n "    \"$escaped_enode\""
                    done <<< "$enodes"
                    
                    echo ""
                    echo "  ]"
                    echo "}"
                } > "$backup_file"
                
                # Also create a simple text file with just enodes (one per line) for easy playback
                local backup_txt_file="$BACKUP_DIR/${safe_compose_name}__${safe_path}__${TIMESTAMP}.txt"
                echo "$enodes" > "$backup_txt_file"
                
                echo "✓ Backed up $peer_count peer(s) from $compose_file ($path) to $(basename "$backup_file")"
                return 0
            fi
        else
            echo "⚠ No peers found for $compose_file ($path)"
            return 1
        fi
    else
        # Check if this is a method not found error (consensus client or admin API disabled)
        error_code=$(echo "$response" | jq -r '.error.code // empty' 2>/dev/null)
        
        if [ -n "$error_code" ] && [ "$error_code" != "null" ]; then
            # This is likely a consensus client endpoint, skip it silently
            return 1
        fi
        
        # Try net_peerCount as fallback (but we can't get enodes from this)
        response=$(curl --ipv4 -L -s -X POST "$RPC_URL" \
            -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
            --max-time 10 2>/dev/null)
        
        if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
            peer_count=$(echo "$response" | jq -r '.result' | xargs printf "%d")
            if [ "$peer_count" -gt 0 ]; then
                echo "⚠ $compose_file ($path) has $peer_count peer(s) but admin_peers not available (cannot backup enodes)"
            fi
        fi
        
        return 1
    fi
}

# Main execution
if [ -z "$COMPOSE_FILE" ]; then
    echo "Error: COMPOSE_FILE not found in $BASEPATH/.env" >&2
    exit 1
fi

# Split COMPOSE_FILE by colon
IFS=':' read -ra parts <<< "$COMPOSE_FILE"

total_backed_up=0
total_failed=0
total_skipped=0

echo "Starting peer backup at $(date)"
echo "Backup directory: $BACKUP_DIR"
echo ""

# Process each compose file
for part in "${parts[@]}"; do
    # Remove .yml extension if present for processing
    compose_file="${part%.yml}.yml"
    
    # Check blacklist
    include=true
    for word in "${blacklist[@]}"; do
        if echo "$compose_file" | grep -qE "$word"; then
            include=false
            break
        fi
    done
    
    if [ "$include" = false ]; then
        total_skipped=$((total_skipped + 1))
        continue
    fi
    
    # Extract RPC paths from compose file
    paths=$(extract_rpc_paths "$compose_file")
    
    if [ -z "$paths" ]; then
        total_skipped=$((total_skipped + 1))
        continue
    fi
    
    # Process each path
    path_found=false
    for path in $paths; do
        # Check path blacklist
        if should_include_path "$path"; then
            path_found=true
            if backup_peers_from_path "$compose_file" "$path"; then
                total_backed_up=$((total_backed_up + 1))
            else
                total_failed=$((total_failed + 1))
            fi
        fi
    done
    
    if [ "$path_found" = false ]; then
        total_skipped=$((total_skipped + 1))
    fi
done

echo ""
echo "=========================================="
echo "Backup Summary"
echo "=========================================="
echo "Total nodes backed up: $total_backed_up"
echo "Total nodes failed: $total_failed"
echo "Total nodes skipped: $total_skipped"
echo "Backup directory: $BACKUP_DIR"
echo "Completed at $(date)"
echo ""

# Optional: Clean up old backups (keep last 30 days)
if [ -n "$CLEANUP_OLD_BACKUPS" ] && [ "$CLEANUP_OLD_BACKUPS" = "true" ]; then
    echo "Cleaning up backups older than 30 days..."
    find "$BACKUP_DIR" -name "*.json" -type f -mtime +30 -delete
    find "$BACKUP_DIR" -name "*.txt" -type f -mtime +30 -delete
    echo "Cleanup complete"
fi

exit 0

