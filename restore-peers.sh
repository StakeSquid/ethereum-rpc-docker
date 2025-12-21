#!/bin/bash

# Script to restore peers from a backup file
# Usage: ./restore-peers.sh <backup-file> [rpc-url]
#   backup-file: Path to backup JSON or TXT file
#   rpc-url: Optional. If not provided, will extract from backup file

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup-file> [rpc-url]"
    echo ""
    echo "  backup-file: Path to backup JSON or TXT file"
    echo "  rpc-url: Optional. Target RPC URL to restore peers to"
    echo "           If not provided, will use rpc_url from backup file"
    echo ""
    echo "Examples:"
    echo "  $0 peer-backups/ethereum-mainnet__ethereum-mainnet-archive__20240101_120000.json"
    echo "  $0 peer-backups/ethereum-mainnet__ethereum-mainnet-archive__20240101_120000.txt https://domain.com/ethereum-mainnet-archive"
    exit 1
fi

BACKUP_FILE="$1"
TARGET_URL="$2"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE" >&2
    exit 1
fi

# Determine file type and extract enodes
if [[ "$BACKUP_FILE" == *.json ]]; then
    # JSON backup file
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required to parse JSON backup files" >&2
        exit 1
    fi
    
    # Extract RPC URL from backup if not provided
    if [ -z "$TARGET_URL" ]; then
        TARGET_URL=$(jq -r '.rpc_url // empty' "$BACKUP_FILE" 2>/dev/null)
        if [ -z "$TARGET_URL" ] || [ "$TARGET_URL" = "null" ]; then
            echo "Error: Could not extract rpc_url from backup file and no target URL provided" >&2
            exit 1
        fi
    fi
    
    # Extract enodes
    enodes=$(jq -r '.peers[]?' "$BACKUP_FILE" 2>/dev/null)
    
    if [ -z "$enodes" ]; then
        echo "Error: No peers found in backup file" >&2
        exit 1
    fi
    
    peer_count=$(jq -r '.peer_count // 0' "$BACKUP_FILE" 2>/dev/null)
    compose_file=$(jq -r '.compose_file // "unknown"' "$BACKUP_FILE" 2>/dev/null)
    rpc_path=$(jq -r '.rpc_path // "unknown"' "$BACKUP_FILE" 2>/dev/null)
    timestamp=$(jq -r '.timestamp // "unknown"' "$BACKUP_FILE" 2>/dev/null)
    
    echo "Restoring peers from backup:"
    echo "  Compose file: $compose_file"
    echo "  RPC path: $rpc_path"
    echo "  Timestamp: $timestamp"
    echo "  Peer count: $peer_count"
    echo "  Target URL: $TARGET_URL"
    echo ""
    
elif [[ "$BACKUP_FILE" == *.txt ]]; then
    # TXT backup file (one enode per line)
    enodes=$(grep -v '^$' "$BACKUP_FILE" | grep -v '^null$')
    
    if [ -z "$enodes" ]; then
        echo "Error: No peers found in backup file" >&2
        exit 1
    fi
    
    peer_count=$(echo "$enodes" | wc -l | tr -d ' ')
    
    if [ -z "$TARGET_URL" ]; then
        echo "Error: Target RPC URL required for TXT backup files" >&2
        echo "Usage: $0 <backup-file> <rpc-url>" >&2
        exit 1
    fi
    
    echo "Restoring peers from backup:"
    echo "  Backup file: $BACKUP_FILE"
    echo "  Peer count: $peer_count"
    echo "  Target URL: $TARGET_URL"
    echo ""
    
else
    echo "Error: Unsupported backup file format. Expected .json or .txt" >&2
    exit 1
fi

# Confirm before proceeding
read -p "Do you want to restore $peer_count peer(s) to $TARGET_URL? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Restore cancelled"
    exit 0
fi

# Restore peers
success_count=0
failed_count=0
skipped_count=0

echo ""
echo "Restoring peers..."

while IFS= read -r enode; do
    if [ -z "$enode" ] || [ "$enode" = "null" ]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi
    
    # Check if peer is reachable (optional, can be slow)
    if [ -f "$BASEPATH/check-enode.sh" ]; then
        if ! "$BASEPATH/check-enode.sh" "$enode" --target "$TARGET_URL" > /dev/null 2>&1; then
            echo "⚠ Skipping unreachable peer: ${enode:0:50}..."
            skipped_count=$((skipped_count + 1))
            continue
        fi
    fi
    
    echo -n "Adding peer: ${enode:0:50}... "
    
    result=$(curl --ipv4 -X POST -H "Content-Type: application/json" \
        --silent --max-time 10 \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"${enode}\"],\"id\":1}" \
        "$TARGET_URL" 2>/dev/null | jq -r '.result // .error.message // "unknown error"' 2>/dev/null)
    
    if [ "$result" = "true" ] || [ "$result" = "null" ]; then
        echo "✓ Success"
        success_count=$((success_count + 1))
    else
        echo "✗ Failed: $result"
        failed_count=$((failed_count + 1))
    fi
    
    # Small delay to avoid overwhelming the node
    sleep 0.1
done <<< "$enodes"

echo ""
echo "=========================================="
echo "Restore Summary"
echo "=========================================="
echo "Successful: $success_count/$peer_count"
echo "Failed: $failed_count/$peer_count"
echo "Skipped: $skipped_count/$peer_count"
echo ""

if [ $failed_count -gt 0 ]; then
    exit 1
fi

exit 0

