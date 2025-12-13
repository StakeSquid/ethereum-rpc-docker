#!/bin/bash
dir="$(dirname "$0")"

# Path to the backup directory
backup_dir="/backup"

# Path to the volume directory
volume_dir="/var/lib/docker/volumes"

if [ ! -d "$volume_dir" ]; then
    echo "Error: /var/lib/docker/volumes directory does not exist"
    exit 1
fi

# Read the JSON input and extract the list of keys
keys=$(cat $dir/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]' | grep -E '^["'\'']?[0-9a-z]')

restore_files=()
cleanup_folders=()

echo "$keys"

while IFS= read -r key; do
    volume_name="rpc_$key"
    declare newest_file
    
    if [[ -n $2 ]]; then
	volume_name="rpc_$key-20" # needs to be followed by a date 2024
	newest_file=$($dir/list-backups.sh $2 | grep "${volume_name}" | sort | tail -n 1)
    else
	newest_file=$(ls -1 "$backup_dir"/"${volume_name}"-[0-9]*G.tar.zst 2>/dev/null | sort | tail -n 1)	
    fi
    
    directory="$volume_dir/rpc_$key/_data/"

    if [ -z "$newest_file" ]; then
	echo "Error: No backup found for volume '$volume_name'"
	exit 1
    else
	restore_files+=("$newest_file")
	cleanup_folders+=("$directory")      
    fi
done <<< "$keys"

echo "${cleanup_folders[@]}"

for folder in "${cleanup_folders[@]}"; do
    echo "delete '$folder'"
    [ -d "$folder" ] && rm -rf "$folder"/*
done

echo "done cleanup"

for file in "${restore_files[@]}"; do
    echo "Processing: $file"

    if [[ -n $2 ]]; then
	if [ ! -d "$backup_dir" ]; then
	    echo "Error: /backup directory does not exist. download from http and extract directly to /var/lib/docker"


	    curl --ipv4 -# "${2}${file}" | zstd -d | tar -xvf - --dereference -C /

	    if [ $? -ne 0 ]; then
		echo "Error processing $file"
		exit 1
	    else
		echo "$file successfully processed."
	    fi
	else
	    echo "have backup dir to cache... $file"
	    if [ ! -e "$backup_dir/$(basename $file)" ]; then
		aria2c -c -Z -x8 -j8 -s8 -d "$backup_dir" "${2}${file}"
	    fi
	    tar -I zstd -xf "$backup_dir/$(basename $file)" --dereference -C /
	    echo "Backup '$file' processed"
	fi
    else
	tar -I zstd -xf "$file" --dereference -C /
	echo "Backup '$file' restored"
    fi
done

./delete-node-keys.sh $1

echo "node $1 restored."
