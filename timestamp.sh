#!/bin/bash

ms_to_human_readable() {
    local ms=$1
    local days=$((ms / 86400000))
    ms=$((ms % 86400000))
    local hours=$((ms / 3600000))
    ms=$((ms % 3600000))
    local minutes=$((ms / 60000))
    ms=$((ms % 60000))
    local seconds=$((ms / 1000))
    local milliseconds=$((ms % 1000))
    
    printf "%d days, %02d hours, %02d minutes, %02d seconds, %03d milliseconds\n" $days $hours $minutes $seconds $milliseconds
}

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

blacklist=()
while IFS= read -r line; do
    # Add each line to the array
    blacklist+=("$line")
done < "$BASEPATH/path-blacklist.txt"

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "(?<=stripprefix\.prefixes).*\"" | cut -d'=' -f2- | sed 's/.$//')

for path in $pathlist; do
    include=true
    for word in "${blacklist[@]}"; do
	if echo "$path" | grep -qE "$word"; then
	    include=false
	fi
    done
		
    if $include; then
	RPC_URL="https://$DOMAIN$path"
	response_file=$(mktemp)

	http_status_code=$(curl --ipv4 -m 1 -s -X POST -w "%{http_code}" -o "$response_file" -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}' $RPC_URL)

	if [ $? -eq 0 ]; then
	    
	    if [[ $http_status_code -eq 200 ]]; then
		response=$(cat "$response_file")
		latest_block_number=$(echo "$response" | jq -r '.result.number')
		latest_block_number_decimal=$((16#${latest_block_number#0x}))

		latest_block_timestamp=$(echo "$response" | jq -r '.result.timestamp')
                latest_block_timestamp_decimal=$((16#${latest_block_timestamp#0x}))
                current_time=$(date +%s)
                time_difference=$((current_time - latest_block_timestamp_decimal))	       

		if [[ $2 == "true" ]]; then
		    ms_to_human_readable "$time_difference"
		else
		    echo "$latest_block_number_decimal"
		fi
		   
		exit 0;
	    fi
	fi
	break;
    fi
done

exit 1;
		
