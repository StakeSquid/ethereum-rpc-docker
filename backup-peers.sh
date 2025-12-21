#!/bin/bash

# Script to backup peers from all running nodes
# Can be run as a cronjob to periodically backup peer lists
# Usage: ./backup-peers.sh [backup-directory] [--verbose]

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

# Parse arguments
VERBOSE=false
BACKUP_DIR=""

for arg in "$@"; do
    case "$arg" in
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: $0 [backup-directory] [--verbose|-v]"
            echo ""
            echo "  backup-directory: Optional. Directory to store backups (default: ./peer-backups)"
            echo "  --verbose, -v:    Enable verbose output"
            exit 0
            ;;
        *)
            if [ -z "$BACKUP_DIR" ] && [[ ! "$arg" =~ ^- ]]; then
                BACKUP_DIR="$arg"
            fi
            ;;
    esac
done

# Default backup directory if not provided
if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$BASEPATH/peer-backups"
fi

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
    # For HTTPS, DOMAIN should be set
    if [ -z "$DOMAIN" ]; then
        echo "Error: DOMAIN variable not found in $BASEPATH/.env" >&2
        echo "Please set DOMAIN in your .env file" >&2
        exit 1
    fi
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
    
    # Always exclude paths ending with /node (consensus client endpoints)
    if [[ "$path" =~ /node$ ]]; then
        if [ "$VERBOSE" = true ]; then
            echo "  Path $path excluded: ends with /node"
        fi
        return 1
    fi
    
    for word in "${path_blacklist[@]}"; do
        # Unescape the pattern (handle \-node -> -node)
        pattern=$(echo "$word" | sed 's/\\-/-/g')
        if echo "$path" | grep -qE "$pattern"; then
            if [ "$VERBOSE" = true ]; then
                echo "  Path $path matches blacklist pattern: $word"
            fi
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
    
    # Ensure path starts with /
    if [[ ! "$path" =~ ^/ ]]; then
        path="/$path"
    fi
    
    local RPC_URL="${PROTO}://${DOMAIN}${path}"
    
    # Try admin_peers first (returns detailed peer info)
    response=$(curl --ipv4 -L -s -X POST "$RPC_URL" \
        -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' \
        --max-time 10 2>/dev/null)
    
    # Check for curl errors
    if [ $? -ne 0 ]; then
        echo "✗ Failed to connect to $compose_file ($path): curl error"
        return 1
    fi
    
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
                
                # Extract just the filename for display
                backup_filename=$(basename "$backup_file" 2>/dev/null || echo "${backup_file##*/}")
                echo "✓ Backed up $peer_count peer(s) from $compose_file ($path) to $backup_filename"
                return 0
            fi
        else
            if [ "$VERBOSE" = true ]; then
                echo "⚠ No peers found for $compose_file ($path)"
            fi
            return 2  # Return 2 for "no peers" (not a failure, just nothing to backup)
        fi
    else
        # Check if this is a method not found error (consensus client or admin API disabled)
        error_code=$(echo "$response" | jq -r '.error.code // empty' 2>/dev/null)
        error_message=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
        
        if [ -n "$error_code" ] && [ "$error_code" != "null" ]; then
            # Check if it's a method not found error (likely consensus client)
            if [ "$error_code" = "-32601" ] || [ "$error_code" = "32601" ]; then
                # Method not found - likely consensus client, skip silently
                return 1
            else
                # Other error
                echo "✗ $compose_file ($path): RPC error $error_code - ${error_message:-unknown error}"
                return 1
            fi
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
            else
                echo "⚠ $compose_file ($path): no peers connected"
            fi
        else
            # Couldn't get peer count either
            if [ -z "$response" ]; then
                echo "✗ $compose_file ($path): no response from RPC endpoint"
            else
                echo "✗ $compose_file ($path): RPC endpoint not accessible or invalid"
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
total_no_peers=0

echo "Starting peer backup at $(date)"
echo "Backup directory: $BACKUP_DIR"
echo "COMPOSE_FILE contains: ${#parts[@]} compose file(s)"
echo ""

# Process each compose file
for part in "${parts[@]}"; do
    # Handle compose file name - part might already have .yml or might not
    if [[ "$part" == *.yml ]]; then
        compose_file="$part"
    else
        compose_file="${part}.yml"
    fi
    
    # Check if file exists
    if [ ! -f "$BASEPATH/$compose_file" ]; then
        echo "⚠ Skipping $compose_file: file not found"
        total_skipped=$((total_skipped + 1))
        continue
    fi
    
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
        echo "⚠ Skipping $compose_file: no RPC paths found"
        total_skipped=$((total_skipped + 1))
        continue
    fi
    
    # Process each path
    path_found=false
    for path in $paths; do
        # Check path blacklist
        if should_include_path "$path"; then
            path_found=true
            backup_peers_from_path "$compose_file" "$path"
            exit_code=$?
            if [ $exit_code -eq 0 ]; then
                total_backed_up=$((total_backed_up + 1))
            elif [ $exit_code -eq 2 ]; then
                # No peers (not a failure)
                total_no_peers=$((total_no_peers + 1))
            else
                total_failed=$((total_failed + 1))
            fi
        else
            if [ "$VERBOSE" = true ]; then
                echo "⚠ Skipping path $path from $compose_file: blacklisted"
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
if [ $total_no_peers -gt 0 ]; then
    echo "Total nodes with no peers: $total_no_peers"
fi
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

