#!/bin/bash

if [ ! -d "/backup" ]; then
    echo "Error: /backup directory does not exist"
    exit 1
fi

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

# Iterate over the list of keys
for key in $keys; do
    echo "Executing command with key: /var/lib/docker/volumes/rpc_$key/_data"

    source_folder="/var/lib/docker/volumes/rpc_$key/_data"
    folder_size=$(du -sh "$source_folder" | awk '{print $1}')
    target_file="/backup/rpc_$key-$(date +'%Y-%m-%d-%H-%M-%S')-$folder_size.tar.zst"

    tar -cf - "$source_folder" | pv -pterb -s $(du -sb "$source_folder" | awk '{print $1}') | zstd -o "$target_file"
done
