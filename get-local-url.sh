#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

blacklist=()
while IFS= read -r line; do
    # Add each line to the array                                                                                                                                                                                      
    blacklist+=("$line")
done < "$BASEPATH/path-blacklist.txt"

# Parse Docker Compose file to get all services
services=$(cat $BASEPATH/$1.yml | yaml2json | jq -r '.services | keys | .[]')
echo $services
for service in $services; do

    IFS=$'\t' read -r -a labels <<< $(cat "$BASEPATH/$1.yml" | yaml2json | jq -r ".services[\"$service\"].labels[]")
    
    for label in "${labels[@]}"; do
	if [[ "$label" == *"stripprefix.prefixes"* ]]; then
echo $label
	    path=$(echo "$label" | cut -d "=" -f 2)
            break  # Stop looping after finding the first match
	fi
    done

    include=true
    for word in "${blacklist[@]}"; do
        if echo "$path" | grep -qE "$word"; then
            include=false
        fi
    done
    
    if $include; then

        for label in "${labels[@]}"; do
            if [[ "$label" == *"loadbalancer.server.port"* ]]; then
		port=$(echo "$label" | cut -d "=" -f 2)
		echo "$service:$port"
		#print("Value after '=' for the first string containing 'loadbalancer.server.port':", port)
		break  # Stop looping after finding the first match
            fi
	done
    fi
done

#echo "No service found with the specified labels."
exit 1

