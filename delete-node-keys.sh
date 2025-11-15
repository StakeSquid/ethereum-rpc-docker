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

CONFIG_FILE="$1"
GLOBS_FILE="${2:-node-key-globs.txt}"

# Check if config file exists
if [[ ! -f "/root/rpc/$CONFIG_FILE" ]]; then
    echo "Error: Configuration file /root/rpc/$CONFIG_FILE does not exist"
    exit 1
fi

# Check if globs file exists
if [[ ! -f "$(dirname "$0")/$GLOBS_FILE" ]]; then
    echo "Error: Globs file $(dirname "$0")/$GLOBS_FILE does not exist"
    exit 1
fi

# Read volume keys from config file
echo "Reading volume configuration from $CONFIG_FILE..."
keys=$(cat /root/rpc/$CONFIG_FILE | yaml2json - | jq '.volumes' | jq -r 'keys[]')

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
done < "$(dirname "$0")/$GLOBS_FILE"

if [[ ${#globs[@]} -eq 0 ]]; then
    echo "Error: No glob patterns found in $GLOBS_FILE"
    exit 1
fi

volume_count=$(echo "$keys" | wc -l)
echo "Found $volume_count volumes to process"
echo "Using ${#globs[@]} glob pattern(s) from $GLOBS_FILE"
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
    # Use subshell to safely change directory and enable globstar
    for glob in "${globs[@]}"; do
        # Process in subshell to avoid affecting parent shell state
        while IFS= read -r file; do
            if [[ -n "$file" && -f "$file" ]]; then
                echo "  Deleting: $file"
                rm -f "$file"
                ((volume_deleted++))
                ((deleted_count++))
            fi
        done < <(
            # Enable extended globbing and globstar for recursive patterns
            shopt -s globstar nullglob
            cd "$volume_path" || exit 1
            # Expand glob pattern and output full paths
            for f in $glob; do
                if [[ -f "$f" ]]; then
                    echo "$volume_path/$f"
                fi
            done
        )
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

