#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

blacklist=()
while IFS= read -r line; do
    # Add each line to the array
    blacklist+=("$line")
done < "$BASEPATH/path-blacklist.txt"

if [ -n "$NO_SSL" ]; then
    PROTO="http"
    DOMAIN="${DOMAIN:-0.0.0.0}"
else
    PROTO="https"
fi

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "(?<=stripprefix\.prefixes).*\"" | cut -d'=' -f2- | sed 's/.$//')

for path in $pathlist; do
    include=true
    for word in "${blacklist[@]}"; do
	if echo "$path" | grep -qE "$word"; then
	    include=false
	fi
    done
		
    if $include; then
	RPC_URL="$PROTO://$DOMAIN$path"
	response_file=$(mktemp)

	http_status_code=$(curl --ipv4 -m 1 -s -X POST -w "%{http_code}" -o "$response_file" -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}' $RPC_URL)

	if [ $? -eq 0 ]; then
	    
	    if [[ $http_status_code -eq 200 ]]; then
		response=$(cat "$response_file")

		latest_block_timestamp=$(echo "$response" | jq -r '.result.timestamp')
                latest_block_timestamp_decimal=$((16#${latest_block_timestamp#0x}))

		echo "$latest_block_timestamp_decimal"
		   
		exit 0;
	    fi
	fi
	break;
    fi
done

exit 1;
		
