#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

LOCAL=${1:-false}

IFS=':' read -ra parts <<< $COMPOSE_FILE

blacklist=("drpc.yml" "drpc-free.yml" "base.yml" "rpc.yml" "monitoring.yml")

upstreams=()

path_blacklist=()
while IFS= read -r line; do
    # Add each line to the array
    path_blacklist+=("$line")
done < "$BASEPATH/path-blacklist.txt"

for part in "${parts[@]}"; do
    include=true
    for word in "${blacklist[@]}"; do
	if echo "$part" | grep -qE "$word"; then
	    # echo "The path $path contains a blacklisted word: $word"
	    include=false
	fi
    done
    
    if $include; then

	pathlist=$(cat $BASEPATH/$part | grep -oP "(?<=stripprefix\.prefixes).*\"" | cut -d'=' -f2- | sed 's/.$//')

	for path in $pathlist; do
	    path_include=true
	    for word in "${path_blacklist[@]}"; do
		if echo "$path" | grep -qE "$word"; then
		    path_include=false
		fi
	    done
	    
	    if $path_include; then
		

		if $LOCAL; then
		    url=$("$BASEPATH/get-local-url.sh" "${part%.yml}")
                    TEST_URL="https://$DOMAIN$path"
		    export RPC_URL="http://$url"
		    export WS_URL="ws://$url"		   
		    export ID=$(echo "$DOMAIN$path" | sed -E 's/^rpc-(.*)\.stakesquid\.eu\/(.*)$/\1-\2/')
		else
		    url="$DOMAIN$path"
		    export RPC_URL="https://$url"
		    export TEST_URL="$RPC_URL"
		    export WS_URL="wss://$url"		    
                    export ID=$(echo "$url" | sed -E 's/^rpc-(.*)\.stakesquid\.eu\/(.*)$/\1-\2/')
		fi
		
		export PROVIDER=${ORGANIZATION}-${ID}

		response_file=$(mktemp)
		
		http_status_code=$(curl --ipv4 -m 5 -s -o "$response_file" -w "%{http_code}" -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' $TEST_URL)

		if [ $? -eq 0 ] && [[ $http_status_code -ne 200 ]]; then
		    echo "have error response from $TEST_URL: $(cat $response_file)" >&2
		    rm "$response_file"
		    continue  # Skip to the next iteration of the loop
		fi
		
		chain_id=$(cat "$response_file" | jq -r '.result')		
		rm "$response_file"
		
		#echo "$TEST_URL $chain_id" >&2
		chain_id_decimal=$((16#${chain_id#0x}))
		export CHAIN=$($BASEPATH/get-shortname.sh $chain_id_decimal)
		
		# Define the path to the input YAML file
		input_file="$BASEPATH/${part%.yml}.cfg"

		[ -f "$input_file" ] || input_file="$BASEPATH/default.cfg"
		
		# Run envsubst to replace environment variables in the input file and save the result to the output file
		upstreams+=("$(envsubst < "$input_file")")
		break
	    fi
	done	
    fi
done


if [[ -f external-rpcs.txt ]]; then
while IFS= read -r url; do

    export RPC_URL="$url"
    export TEST_URL="$RPC_URL"
    export WS_URL=$(echo "$url" | sed -e 's|^http://|ws://|' -e 's|^https://|wss://|')
    export PROVIDER=$(echo "$url" | sed -e 's|^https\?://||' -e 's|/|-|g' -e 's|\.|-|g')
    export ID=$PROVIDER
    
    response_file=$(mktemp)
		
    http_status_code=$(curl --ipv4 -m 5 -s -o "$response_file" -w "%{http_code}" -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' $TEST_URL)

    if [ $? -eq 0 ] && [[ $http_status_code -ne 200 ]]; then
	echo "have error response from $TEST_URL: $(cat $response_file)" >&2
	rm "$response_file"
	continue  # Skip to the next iteration of the loop
    fi
		
    chain_id=$(cat "$response_file" | jq -r '.result')		
    rm "$response_file"
    
    #echo "$TEST_URL $chain_id" >&2
    chain_id_decimal=$((16#${chain_id#0x}))
    export CHAIN=$($BASEPATH/get-shortname.sh $chain_id_decimal)

    input_file="$BASEPATH/$(echo $url | sed -E 's|https?://([^.]+\.)*([^.]+\.[^.]+).*|\2|').cfg"
    
    [ -f "$input_file" ] || input_file="$BASEPATH/default.cfg"
		
    # Run envsubst to replace environment variables in the input file and save the result to the output file
    upstreams+=("$(envsubst < "$input_file")")
done < $BASEPATH/external-rpcs.txt
fi

printf "%s\n" "${upstreams[@]}"

