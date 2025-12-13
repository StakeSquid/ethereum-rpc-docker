#!/bin/bash

if [ -z "$1" ] || [ ! -f "/root/rpc/$1.yml" ]; then
    echo "Error: Either no argument provided or /root/rpc/$1.yml does not exist."
    exit 1
fi

SERVICES=$(cat /root/rpc/$1.yml | yaml2json - | jq '.services' | jq -r 'keys[]' | tr '\n' ' ')

# Check if -f flag is provided
FOLLOW_FLAG=""
TAIL_COUNT=""

# Parse arguments (skip first argument which is the compose file)
shift
for arg in "$@"; do
    if [ "$arg" = "-f" ]; then
        FOLLOW_FLAG="-f"
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        TAIL_COUNT="$arg"
    fi
done

# Build the command
if [ -n "$TAIL_COUNT" ]; then
    if [ -n "$FOLLOW_FLAG" ]; then
        docker compose logs -f --tail "$TAIL_COUNT" $SERVICES
    else
        docker compose logs --tail "$TAIL_COUNT" $SERVICES
    fi
else
    if [ -n "$FOLLOW_FLAG" ]; then
        docker compose logs -f $SERVICES
    else
        docker compose logs $SERVICES
    fi
fi
