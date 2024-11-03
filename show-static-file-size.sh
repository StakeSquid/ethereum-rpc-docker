#!/bin/bash

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

static_size=0
total_size=0

# Iterate over the list of keys
for key in $keys; do
    #echo "checking: /var/lib/docker/volumes/rpc_$key"

    prefix="/var/lib/docker/volumes/rpc_$key"

    volume_size=$(du -s $prefix 2>/dev/null | awk '{print $1}')

    total_size=$((total_size + volume_size))

    while IFS= read -r path; do
    # Check if the path exists
    if [[ -e "$prefix/_data/$path" ]]; then
        # Print the size of the file or directory
        size=$(du -s "$prefix/_data/$path" 2>/dev/null | awk '{print $1}')
        static_size=$((static_size + size))
        #echo "$path: $size"
    fi
    done < static-file-path-list.txt
done

ratio=$(bc -l <<< "scale=2; $static_size/$total_size")
echo "$ratio"
