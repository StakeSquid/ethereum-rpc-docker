#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

blacklist=()
while IFS= read -r line; do
    # Add each line to the array
    blacklist+=("$line")
done < "$BASEPATH/path-blacklist.txt"

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "stripprefix\.prefixes.*?/\K[^\"]+")

for path in $pathlist; do
    include=true
    for word in "${blacklist[@]}"; do
	if echo "$path" | grep -qE "$word"; then
	    include=false
	fi
    done
		
    if $include; then
	RPC_URL="https://$DOMAIN/$path"
	response_file=$(mktemp)

	# Detect Starknet vs Ethereum based on path
	if echo "$path" | grep -qi "starknet"; then
	    rpc_method='{"jsonrpc":"2.0","method":"starknet_getBlockWithTxHashes","params":["latest"],"id":1}'
	    is_starknet=true
	else
	    rpc_method='{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}'
	    is_starknet=false
	fi

	http_status_code=$(curl --ipv4 -m 1 -s -X POST -w "%{http_code}" -o "$response_file" -H "Content-Type: application/json" --data "$rpc_method" $RPC_URL)

	if [ $? -eq 0 ]; then

	    if [[ $http_status_code -eq 200 ]]; then
		response=$(cat "$response_file")

		if $is_starknet; then
		    # Starknet returns decimal block_number
		    latest_block_number_decimal=$(echo "$response" | jq -r '.result.block_number')
		else
		    # Ethereum returns hex number
		    latest_block_number=$(echo "$response" | jq -r '.result.number')
		    latest_block_number_decimal=$((16#${latest_block_number#0x}))
		fi

		echo "$latest_block_number_decimal"

		exit 0;
	    fi
	fi
	break;
    fi
done

exit 1;
		
