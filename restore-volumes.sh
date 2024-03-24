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

total_space=0
cleanup_space=0

restore_files=()
cleanup_folders=()

for key in $keys; do
    volume_name="rpc_$key"
    
    newest_file=$(ls -1 "$backup_dir"/"$volume_name"* | sort | tail -n 1)

    if [ -z "$newest_file" ]; then

	if [ -z "$2" ]; then
	    echo "Error: No backup found for volume '$volume_name'"
	    exit 1
	fi
    fi

    directory="$volume_dir/rpc_$key/_data/"
    restore_files+=("$newest_file")
    cleanup_folders+=("$directory")
    
    required_space=$(calculate_required_space "$(basename "$newest_file")")
    total_space=$((total_space + required_space))

    [ -d "$directory" ] && existing_size=$(du -sb "$directory" | awk '{ total += $1 } END { print total }') || existing_size=0
    cleanup_space=$((cleanup_space + existing_size))    
done

if [ "$2" = "--print-size-only" ]; then
    GB=$(( $total_space / 1024 / 1024 / 1024 ))
    echo "$GB"
    exit 0
fi

available_space=$(df --output=avail -B1 "$volume_dir" | tail -n 1)
available_space=$((available_space + cleanup_space))

if [ "$available_space" -lt "$total_space" ]; then
    echo "Error: Not enough free space in $volume_dir"
    exit 1
fi

for folder in $cleanup_folders; do
    echo "delete $folder"
    [ -d "$folder" ] && rm -rf "$folder/*"
done

for file in $restore_files; do    
    tar -I zstd -xf "$file" -C /
    echo "Backup '$file' restored"        
done

echo "node $1 restored."
    
