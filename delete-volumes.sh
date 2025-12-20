#!/bin/bash

# Function to find and delete symlinked directories
delete_symlinked_dirs() {
    local volume_path=$1
    local key=$2
    
    if [[ ! -d "$volume_path/_data" ]]; then
        return 0
    fi
    
    # Find all symlinks in the volume's _data directory
    find "$volume_path/_data" -type l -print0 2>/dev/null | while IFS= read -r -d '' symlink; do
        # Get the target of the symlink (resolve to absolute path)
        local target=$(readlink -f "$symlink" 2>/dev/null)
        
        if [[ -n "$target" ]] && [[ -d "$target" ]]; then
            echo "  Found symlink: $symlink -> $target"
            
            # Verify the target path matches expected patterns (safety check)
            # Allow /slowdisk and other common backup/storage locations
            local safe_to_delete=false
            
            if [[ "$target" =~ ^/slowdisk/rpc_${key}__data_ ]]; then
                safe_to_delete=true
                echo "    Target is in /slowdisk, will delete"
            elif [[ "$target" =~ ^/backup/ ]] || [[ "$target" =~ ^/storage/ ]] || [[ "$target" =~ ^/data/ ]]; then
                # Additional safety: only delete if it matches the volume pattern
                if [[ "$target" =~ rpc_${key} ]]; then
                    safe_to_delete=true
                    echo "    Target matches volume pattern, will delete"
                fi
            else
                # For other locations, be more cautious - only delete if explicitly matches pattern
                if [[ "$target" =~ rpc_${key}__data_ ]]; then
                    safe_to_delete=true
                    echo "    Target matches expected pattern, will delete"
                else
                    echo "    Warning: Target doesn't match expected pattern, skipping: $target"
                fi
            fi
            
            if [[ "$safe_to_delete" == "true" ]]; then
                echo "    Deleting symlinked directory: $target"
                if rm -rf "$target" 2>/dev/null; then
                    echo "    ✓ Deleted successfully"
                else
                    echo "    ✗ Failed to delete (may require root or may not exist)"
                fi
            fi
        fi
    done
}

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

# Iterate over the list of keys
for key in $keys; do
    volume_path="/var/lib/docker/volumes/rpc_$key"
    
    echo "removing: $volume_path"
    
    # Before removing the volume, check for and delete symlinked directories
    if [[ -d "$volume_path/_data" ]]; then
        echo "  Checking for symlinked directories..."
        delete_symlinked_dirs "$volume_path" "$key"
    else
        echo "  Volume _data directory not found, skipping symlink check"
    fi
    
    # Remove the docker volume (ignore error if volume doesn't exist)
    if docker volume rm "rpc_$key" 2>/dev/null; then
        echo "  ✓ Volume removed successfully"
    else
        # Check if volume exists - if not, that's fine, exit with 0
        if ! docker volume inspect "rpc_$key" &>/dev/null; then
            echo "  Volume does not exist, skipping"
        else
            echo "  ✗ Failed to remove volume (may require root or may be in use)"
        fi
    fi

done

# Exit successfully even if some volumes didn't exist
exit 0
