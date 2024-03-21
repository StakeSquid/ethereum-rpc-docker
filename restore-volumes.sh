#!/bin/bash

# Path to the backup directory
backup_dir="/backup"

# Path to the volume directory
volume_dir="/var/lib/docker/volumes"

if [ ! -d "$backup_dir" ]; then
    echo "Error: /backup directory does not exist"
    exit 1
fi

if [ ! -d "$volume_dir" ]; then
    echo "Error: /var/lib/docker/volumes directory does not exist"
    exit 1
fi

calculate_required_space() {
    # Extract the size from the filename
    size=$(echo "$1" | grep -oE '[0-9]+G')

    # Remove 'G' from the size and convert it to bytes
    size_bytes=$(echo "$size" | sed 's/G//')
    size_bytes=$(( size_bytes * 1024 * 1024 * 1024 ))  # Convert GB to bytes

    # Calculate 10% of the size and add it to the required space
    ten_percent=$(( size_bytes / 10 ))
    required_space=$(( size_bytes + ten_percent ))

    echo "$required_space"
}

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

# Iterate over the list of keys
for key in $keys; do
    echo "Executing command with key: /var/lib/docker/volumes/rpc_$key/_data"
    volume_name="rpc_$key"
    
    newest_file=$(ls -1 "$backup_dir"/"$volume_name"* | sort | tail -n 1)

    if [ -z "$newest_file" ]; then
	echo "Error: No backup found for volume '$volume_name'"
	exit 1
    fi

    required_space=$(calculate_required_space "$(basename "$newest_file")")

    available_space=$(df --output=avail -B1 "$volume_dir" | tail -n 1)

    if [ "$available_space" -lt "$required_space" ]; then
	echo "Error: Not enough free space in $volume_dir"
	exit 1
    fi

    tar -I zstd -xf "$newest_file" -C /

    echo "Backup '$newest_file' restored"    
done



