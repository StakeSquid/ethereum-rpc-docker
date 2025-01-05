#!/bin/bash

backup_dir="/backup"

if [[ -n $2 ]]; then
    echo "upload backup via webdav to $2"
else
    if [ ! -d "$backup_dir" ]; then
	echo "Error: /backup directory does not exist"
	exit 1
    fi
fi

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

# Iterate over the list of keys
for key in $keys; do
    echo "Executing command with key: /var/lib/docker/volumes/rpc_$key/_data"

    source_folder="/var/lib/docker/volumes/rpc_$key/_data"
    folder_size=$(du -sh "$source_folder" | awk '{
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
    
    target_file="rpc_$key-$(date +'%Y-%m-%d-%H-%M-%S')-${folder_size_gb}G.tar.zst"

    #echo "$target_file"

    if [[ -n $2 ]]; then
	tar -cf - "$source_folder" | pv -pterb -s $(du -sb "$source_folder" | awk '{print $1}') | zstd | curl -X PUT --upload-file - "$2/null/uploading-$target_file"
        curl -X MOVE -H "Destination: /null/$target_file" "$2/uploading-$target_file"
    else    
        tar -cf - "$source_folder" | pv -pterb -s $(du -sb "$source_folder" | awk '{print $1}') | zstd -o "/backup/uploading-$target_file"
        mv "/backup/uploading-$target_file" "/backup/$target_file"
    fi
done
