#!/bin/bash

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

total_size=0

# Iterate over the list of keys
for key in $keys; do
    #echo "checking: /var/lib/docker/volumes/rpc_$key"

    prefix="/var/lib/docker/volumes/rpc_$key"

    volume_size=$(du -s $prefix 2>/dev/null | awk '{print $1}')

    total_size=$((total_size + volume_size))
done

echo "$total_size"
