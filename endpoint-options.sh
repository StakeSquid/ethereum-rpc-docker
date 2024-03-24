#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

IFS=':' read -ra parts <<< $COMPOSE_FILE

json=$(cat "$BASEPATH/reference-rpc-endpoint.json")

default_array=()
for key in $(jq -r 'keys[]' <<< "$json"); do
    default_values=$(jq -r ".[\"$key\"].default[]" <<< "$json")
    default_array+=($default_values)
done

for node in "${default_array[@]}"; do
#echo "check $node"
    size_in_gb=$($BASEPATH/restore-volumes.sh "$node" --print-size-only)

    if [ $? -eq 0 ]; then
	echo "$node: $size_in_gb"
#    else
#   	echo "$node can not"
    fi
done

# Print the combined array
#printf "%s\n" "${default_array[@]}"
