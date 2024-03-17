#!/bin/bash

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

# Iterate over the list of keys
for key in $keys; do
    echo "removing: /var/lib/docker/volumes/rpc_$key"

    docker volume rm "rpc_$key"

done
