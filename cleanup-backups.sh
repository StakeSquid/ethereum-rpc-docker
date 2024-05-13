#!/bin/bash

# Directory containing the backup files
backup_dir="/backup"

# Get a list of all backup files
backup_files=$(find "$backup_dir" -type f -name 'rpc_*-*.tar.zst')

# Iterate through each backup file
for file in $backup_files; do
    # Extract volume name from the file name
    volume_name=$(basename "$file" | cut -d '-' -f 1-3)

    # Get the latest backup file for this volume name
    latest_backup=$(find "$backup_dir" -type f -name "$volume_name-*" -printf "%T@ %p\n" | sort -n | tail -1 | cut -d ' ' -f 2)

    # Keep only the latest backup file for this volume name
    if [[ "$file" != "$latest_backup" ]]; then
        echo "$file"
    fi
done
