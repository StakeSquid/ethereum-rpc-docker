#!/bin/bash

if [ -z "$1" ] || [ ! -f "/root/rpc/$1.yml" ]; then
    echo "Error: Either no argument provided or /root/rpc/$1.yml does not exist."
    exit 1
fi

SERVICES=$(cat /root/rpc/$1.yml | yaml2json - | jq '.services' | jq -r 'keys[]' | tr '\n' ' ')

if [ -n "$2" ]; then
    docker compose logs -f --tail "$2" $SERVICES
else
    docker compose logs -f $SERVICES
fi
