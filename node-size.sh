#!/bin/bash

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

total_size=0

# Iterate over the list of keys
for key in $keys; do
    source_folder="/var/lib/docker/volumes/rpc_$key/_data"
    folder_size=$(du -shL "$source_folder" | awk '{
     size = $1
     sub(/[Kk]$/, "", size)  # Remove 'K' suffix if present
     sub(/[Mm]$/, "", size)  # Remove 'M' suffix if present
     sub(/[Gg]$/, "", size)  # Remove 'G' suffix if present
     sub(/[Tt]$/, "", size)  # Remove 'T' suffix if present
     if ($1 ~ /[Kk]$/) {
         size *= 0.001   # Convert kilobytes to gigabytes
     } else if ($1 ~ /[Mm]$/) {
         size *= 0.001   # Convert megabytes to gigabytes
     } else if ($1 ~ /[Tt]$/) {
     	 size *= 1000 # convert terabytes to gigabytes
     }
     print size
    }')

    folder_size_gb=$(printf "%.0f" "$folder_size")
    
    total_size=$((total_size + folder_size))

done

echo "$total_size"
