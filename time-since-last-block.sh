#!/bin/bash

BASEPATH=/root/rpc
source $BASEPATH/.env

blacklist=("lighthouse" "prism" "beacon" "nimbus" "ws" "arbitrum-classic" "hagall" "public")

IFS=':' read -ra parts <<< $COMPOSE_FILE

for part in "${parts[@]}"; do
    pathlist=$(cat $BASEPATH/$part | grep -oP "(?<=stripprefix\.prefixes).*\"" | cut -d'=' -f2- | sed 's/.$//')

    # echo $pathlist > $TARGETPATH/$DOMAIN
	
    for path in $pathlist; do
	include=true
	for word in "${blacklist[@]}"; do
	    if echo "$path" | grep -qE "$word"; then
		#echo "The path $path contains a blacklisted word: $word"
		include=false
	    fi
	done
		
	#echo "include: $include; $DOMAIN$path"
	if $include; then
	    #echo "Querying $DOMAIN$path"

	    RPC_URL="https://$DOMAIN$path"

	    response_file=$(mktemp)

	    http_status_code=$(curl --ipv4 -m 1 -s -X POST -w "%{http_code}" -o "$response_file" -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}' $RPC_URL)

	    if [ $? -eq 0 ]; then
    		# If successful, print the response
	    	#echo "Curl request succeeded:"
	    	#echo "$response"

		if [[ $http_status_code -eq 200 ]]; then
     		    # Handle successful response (HTTP 200)
    		    #echo "HTTP 200: Success"
    		    # Read and output the response body from the temporary file
    		    response=$(cat "$response_file")

                    latest_block_timestamp=$(echo "$response" | jq -r '.result.timestamp')
                   
                    # Convert the latest block timestamp from hexadecimal to decimal
                    latest_block_timestamp_decimal=$((16#${latest_block_timestamp#0x}))
           
                    # Get the current system time in seconds
                     current_time=$(date +%s)
               
                    # Calculate the difference between the latest block timestamp and the current system time
                    time_difference=$((current_time - latest_block_timestamp_decimal))

                    if [ $time_difference -lt 60 ]; then
        		echo "$path: online"
    		    else
               
		    formatted_time_difference=$(printf '%d years %d months %d weeks %d days %d hours %d minutes %d seconds\n' \
	            $((time_difference / 31536000)) \
        	    $((time_difference % 31536000 / 2592000)) \
	            $((time_difference % 2592000 / 604800)) \
	            $((time_difference % 604800 / 86400)) \
	            $((time_difference % 86400 / 3600)) \
	            $((time_difference % 3600 / 60)) \
	            $((time_difference % 60)))

                    # Print the time difference in seconds
                    echo "$path: syncing ($formatted_time_difference)"
		    fi
		elif [[ $http_status_code -eq 404 ]]; then
    		   # Handle HTTP 404 error
    		   echo "$path: offline"
		else
		    # Handle other HTTP response codes
		    echo "Unexpected HTTP status code: $http_status_code"
		fi
            else
        	    # If the command failed (timed out), print an error message
        	    echo "Error: Curl request timed out after 1 second"
            fi
	
 	    rm "$response_file"
        fi	    
    done
done

