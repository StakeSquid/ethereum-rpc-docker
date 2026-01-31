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

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "stripprefix\.prefixes.*?/\K[^\"]+")

for path in $pathlist; do
    include=true
    for word in "${blacklist[@]}"; do
	if echo "$path" | grep -qE "$word"; then
	    include=false
	fi
    done
		
    if $include; then
	RPC_URL="$PROTO://$DOMAIN/$path"
	response_file=$(mktemp)

	# Detect Starknet vs Ethereum vs Aztec based on path
	if echo "$path" | grep -qi "starknet"; then
	    rpc_method='{"jsonrpc":"2.0","method":"starknet_getBlockWithTxHashes","params":["latest"],"id":1}'
	    is_starknet=true
	    is_aztec=false
	elif echo "$path" | grep -qi "aztec"; then
	    is_starknet=false
	    is_aztec=true
	else
	    rpc_method='{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}'
	    is_starknet=false
	    is_aztec=false
	fi

	if $is_aztec; then
	    # Aztec: node_getBlock("latest") returns block with header.globalVariables.timestamp
	    rpc_method='{"jsonrpc":"2.0","method":"node_getBlock","params":["latest"],"id":1}'
	fi

	http_status_code=$(curl -L --ipv4 -m 1 -s -X POST -w "%{http_code}" -o "$response_file" -H "Content-Type: application/json" --data "$rpc_method" $RPC_URL)

	if [ $? -eq 0 ]; then

	    if [[ $http_status_code -eq 200 ]]; then
		response=$(cat "$response_file")

		if $is_aztec; then
		    # result.header.globalVariables.timestamp, result.blockHash, result.header.globalVariables.blockNumber
		    latest_block_timestamp_decimal=$(echo "$response" | jq -r '.result.header.globalVariables.timestamp')
		    rm -f "$response_file"
		    if [ "$latest_block_timestamp_decimal" = "null" ] || [ -z "$latest_block_timestamp_decimal" ]; then
			exit 1
		    fi
		elif $is_starknet; then
		    # Starknet returns decimal timestamp
		    latest_block_timestamp_decimal=$(echo "$response" | jq -r '.result.timestamp')
		    rm -f "$response_file"
		else
		    # Ethereum returns hex timestamp
		    latest_block_timestamp=$(echo "$response" | jq -r '.result.timestamp')
		    latest_block_timestamp_decimal=$((16#${latest_block_timestamp#0x}))
		    rm -f "$response_file"
		fi

		echo "$latest_block_timestamp_decimal"

		exit 0;
	    fi
	    rm -f "$response_file"
	fi
	break;
    fi
done

exit 1;
		
