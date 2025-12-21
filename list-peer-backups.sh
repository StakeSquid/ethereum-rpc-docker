#!/bin/bash

# Script to list available peer backups
# Usage: ./list-peer-backups.sh [backup-directory] [filter]

BASEPATH="$(dirname "$0")"
BACKUP_DIR="${1:-$BASEPATH/peer-backups}"
FILTER="${2:-}"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Backup directory does not exist: $BACKUP_DIR"
    echo "Run backup-peers.sh first to create backups"
    exit 1
fi

# Count files
json_count=$(find "$BACKUP_DIR" -name "*.json" -type f | wc -l | tr -d ' ')
txt_count=$(find "$BACKUP_DIR" -name "*.txt" -type f | wc -l | tr -d ' ')

if [ "$json_count" -eq 0 ] && [ "$txt_count" -eq 0 ]; then
    echo "No backups found in $BACKUP_DIR"
    exit 0
fi

echo "Peer backups in: $BACKUP_DIR"
echo "Total backups: $json_count JSON, $txt_count TXT"
echo ""

# List JSON backups with details
if [ "$json_count" -gt 0 ]; then
    echo "JSON Backups (with metadata):"
    echo "=========================================="
    
    for backup_file in $(find "$BACKUP_DIR" -name "*.json" -type f | sort -r); do
        if [ -n "$FILTER" ] && ! echo "$backup_file" | grep -qi "$FILTER"; then
            continue
        fi
        
        if command -v jq &> /dev/null; then
            compose_file=$(jq -r '.compose_file // "unknown"' "$backup_file" 2>/dev/null)
            rpc_path=$(jq -r '.rpc_path // "unknown"' "$backup_file" 2>/dev/null)
            timestamp=$(jq -r '.timestamp // "unknown"' "$backup_file" 2>/dev/null)
            peer_count=$(jq -r '.peer_count // 0' "$backup_file" 2>/dev/null)
            rpc_url=$(jq -r '.rpc_url // "unknown"' "$backup_file" 2>/dev/null)
            
            file_size=$(du -h "$backup_file" | cut -f1)
            file_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup_file" 2>/dev/null || stat -c "%y" "$backup_file" 2>/dev/null | cut -d'.' -f1)
            
            echo "File: $(basename "$backup_file")"
            echo "  Compose: $compose_file"
            echo "  Path: $rpc_path"
            echo "  URL: $rpc_url"
            echo "  Peers: $peer_count"
            echo "  Timestamp: $timestamp"
            echo "  Size: $file_size"
            echo "  Date: $file_date"
            echo ""
        else
            # Fallback if jq is not available
            file_size=$(du -h "$backup_file" | cut -f1)
            file_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup_file" 2>/dev/null || stat -c "%y" "$backup_file" 2>/dev/null | cut -d'.' -f1)
            echo "$(basename "$backup_file") - $file_size - $file_date"
        fi
    done
fi

# Show usage examples
echo ""
echo "To restore a backup, use:"
echo "  ./restore-peers.sh <backup-file> [rpc-url]"
echo ""
echo "Examples:"
if [ "$json_count" -gt 0 ]; then
    latest_json=$(find "$BACKUP_DIR" -name "*.json" -type f | sort -r | head -1)
    if [ -n "$latest_json" ]; then
        echo "  ./restore-peers.sh $latest_json"
    fi
fi
if [ "$txt_count" -gt 0 ]; then
    latest_txt=$(find "$BACKUP_DIR" -name "*.txt" -type f | sort -r | head -1)
    if [ -n "$latest_txt" ]; then
        if command -v jq &> /dev/null && [ -n "$latest_json" ]; then
            rpc_url=$(jq -r '.rpc_url // ""' "$latest_json" 2>/dev/null)
            if [ -n "$rpc_url" ]; then
                echo "  ./restore-peers.sh $latest_txt $rpc_url"
            fi
        fi
    fi
fi

