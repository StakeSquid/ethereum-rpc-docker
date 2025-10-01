#!/bin/bash

if [[ -n $2 ]]; then
    echo "clone volumes via ssh to $2"
else
    echo "Error: No destination provided"
    exit 1
fi

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

# Iterate over the list of keys
for key in $keys; do
    echo "Executing command with key: /var/lib/docker/volumes/rpc_$key/_data"

    source_folder="/var/lib/docker/volumes/rpc_$key/_data"
    if [[ -n $2 ]]; then
        tar -cf - --dereference "$source_folder" | pv -pterb -s $(du -sb "$source_folder" | awk '{print $1}') | zstd | ssh -o Compression=no -c=chacha20-poly1305@openssh.com "$2.stakesquid.eu" "zstd -d | tar -xf - -C /"
    fi
done
