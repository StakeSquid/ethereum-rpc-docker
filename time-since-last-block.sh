#!/bin/bash

source /root/rpc/.env

blacklist=("lighthouse" "prism" "beacon" "nimbus" "ws" "arbitrum-classic" "hagall" "public")

IFS=':' read -ra parts <<< $COMPOSE_FILE

for part in "${parts[@]}"; do
    pathlist=$(cat $BASEPATH/$part | grep -oP "(?<=stripprefix\.prefixes).*\"" | cut -d'=' -f2- | sed 's/.$//')

    # echo $pathlist > $TARGETPATH/$DOMAIN
	
    for path in $pathlist; do
	include=true
	for word in "${blacklist[@]}"; do
	    if echo "$path" | grep -qE "$word"; then
		echo "The path $path contains a blacklisted word: $word"
		include=false
	    fi
	done
		
	#echo "include: $include; $DOMAIN$path"
	if $include; then
	    echo "Querying $DOMAIN$path"

	    RPC_URL="https://$DOMAIN$path"

	    # Query the Ethereum JSON-RPC endpoint for the latest block timestamp
	    latest_block_timestamp=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}' $RPC_URL | jq -r '.result.timestamp')

	    # Convert the latest block timestamp from hexadecimal to decimal
	    latest_block_timestamp_decimal=$((16#$latest_block_timestamp))

	    # Get the current system time in seconds
	    current_time=$(date +%s)

	    # Calculate the difference between the latest block timestamp and the current system time
	    time_difference=$((current_time - latest_block_timestamp_decimal))

	    # Print the time difference in seconds
	    echo "Time difference between the latest block and current system time: $time_difference seconds"
	    
	fi	    
    done
done

