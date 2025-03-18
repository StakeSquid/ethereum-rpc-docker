#!/bin/bash

if [ -z "$1" ] || [ ! -f "/root/rpc/$1.yml" ]; then
    echo "Error: Either no argument provided or /root/rpc/$1.yml does not exist."
    exit 1
fi

docker compose logs -f --since "2h" $(cat /root/rpc/$1.yml | yaml2json - | jq '.services' | jq -r 'keys[]' | tr '\n' ' ')
