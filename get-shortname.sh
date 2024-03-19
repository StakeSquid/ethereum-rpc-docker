#!/bin/bash

# JSON data

json_file="/root/rpc/reference-rpc-endpoint.json"
if [ ! -f "$json_file" ]; then
    exit 1
fi

# ID value to search for
search_id=$1

# Get the key of the object with the specified ID value
key=$(cat "$json_file" | jq -r "to_entries[] | select(.value.id == $search_id) | .key")

echo "$key"
