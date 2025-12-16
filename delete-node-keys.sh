#!/bin/bash

# Script to delete node key files from volumes based on glob patterns
# Usage: ./delete-node-keys.sh <config-file> [globs-file]
#   config-file: YAML config file (e.g., ethereum-mainnet.yml)
#   globs-file:  File containing glob patterns (default: node-key-globs.txt)

if [[ -z "$1" ]]; then
    echo "Error: No configuration file provided"
    echo "Usage: $0 <config-file> [globs-file]"
    exit 1
fi

CONFIG_FILE="$1.yml"
GLOBS_FILE="${2:-node-key-globs.txt}"
SCRIPT_DIR="$(dirname "$0")"

# Try to find config file in multiple locations
if [[ -f "$SCRIPT_DIR/$CONFIG_FILE" ]]; then
    CONFIG_PATH="$SCRIPT_DIR/$CONFIG_FILE"
elif [[ -f "/root/rpc/$CONFIG_FILE" ]]; then
    CONFIG_PATH="/root/rpc/$CONFIG_FILE"
else
    echo "Error: Configuration file $CONFIG_FILE not found in $SCRIPT_DIR or /root/rpc"
    exit 1
fi

# Resolve globs file path - always relative to script directory
if [[ "$GLOBS_FILE" == /* ]]; then
    # Absolute path provided, use as-is
    GLOBS_PATH="$GLOBS_FILE"
else
    # Relative path, resolve relative to script directory
    GLOBS_PATH="$SCRIPT_DIR/$GLOBS_FILE"
fi

# Check if globs file exists
if [[ ! -f "$GLOBS_PATH" ]]; then
    echo "Error: Globs file $GLOBS_PATH does not exist"
    exit 1
fi

# Read volume keys from config file
echo "Reading volume configuration from $CONFIG_PATH..."
keys=$(cat "$CONFIG_PATH" | yaml2json - | jq '.volumes' | jq -r 'keys[]')

if [[ -z "$keys" ]]; then
    echo "Error: No volumes found in configuration"
    exit 1
fi

# Read glob patterns from file (skip empty lines and comments)
globs=()
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments (lines starting with #)
    if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
        globs+=("$line")
    fi
done < "$GLOBS_PATH"

if [[ ${#globs[@]} -eq 0 ]]; then
    echo "Error: No glob patterns found in $GLOBS_PATH"
    exit 1
fi

volume_count=$(echo "$keys" | wc -l)
echo "Found $volume_count volumes to process"
echo "Using ${#globs[@]} glob pattern(s) from $GLOBS_PATH"
echo "----------------------------------------"

deleted_count=0
processed_count=0

for key in $keys; do
    volume_path="/var/lib/docker/volumes/rpc_${key}/_data"
    
    if [[ ! -d "$volume_path" ]]; then
        echo "Warning: $volume_path does not exist, skipping"
        continue
    fi
    
    echo "Processing volume: $key"
    volume_deleted=0
    
    # For each glob pattern, find and delete matching files
    # Use find instead of shell globbing for more reliable pattern matching
    for glob in "${globs[@]}"; do
        # Convert glob pattern to find pattern
        # Handle **/ patterns by using find recursively
        if [[ "$glob" =~ ^\*\*/ ]]; then
            # Pattern like **/nodekey - find recursively
            find_pattern="${glob#\*\*/}"  # Remove **/ prefix
            while IFS= read -r -d '' file; do
                if [[ -n "$file" && -f "$file" ]]; then
                    echo "  Deleting: $file"
                    rm -f "$file"
                    ((volume_deleted++))
                    ((deleted_count++))
                fi
            done < <(find "$volume_path" -type f -name "$find_pattern" -print0 2>/dev/null)
        elif [[ "$glob" == */* ]]; then
            # Pattern like staking/* - find in specific directory
            find_dir="${glob%/*}"
            find_name="${glob#*/}"
            while IFS= read -r -d '' file; do
                if [[ -n "$file" && -f "$file" ]]; then
                    echo "  Deleting: $file"
                    rm -f "$file"
                    ((volume_deleted++))
                    ((deleted_count++))
                fi
            done < <(find "$volume_path/$find_dir" -maxdepth 1 -type f -name "$find_name" -print0 2>/dev/null)
        else
            # Simple pattern like "key" or "node_key.json" - find recursively
            while IFS= read -r -d '' file; do
                if [[ -n "$file" && -f "$file" ]]; then
                    echo "  Deleting: $file"
                    rm -f "$file"
                    ((volume_deleted++))
                    ((deleted_count++))
                fi
            done < <(find "$volume_path" -type f -name "$glob" -print0 2>/dev/null)
        fi
    done
    
    if [[ $volume_deleted -eq 0 ]]; then
        echo "  No matching files found"
    else
        echo "  Deleted $volume_deleted file(s)"
    fi
    
    ((processed_count++))
    echo "----------------------------------------"
done

echo ""
echo "Summary:"
echo "  Processed: $processed_count/$volume_count volumes"
echo "  Total files deleted: $deleted_count"

