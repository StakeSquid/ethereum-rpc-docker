#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

IFS=':' read -ra parts <<< $COMPOSE_FILE

blacklist=("drpc.yml" "base.yml" "rpc.yml" "monitoring.yml")

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
	    #echo "The path $path contains a blacklisted word: $word"
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
		url="$DOMAIN$path"
		
		#echo "$url"
		
		export ID=$(echo "$url" | sed -E 's/^rpc-(.*)\.stakesquid\.eu\/(.*)$/\1-\2/')
		export PROVIDER=${ORGANIZATION}-${ID}
		export RPC_URL="https://$url"
		export WS_URL="wss://$url"
		
		chain_id=$(curl --ipv4 -m 1 -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' $RPC_URL | jq -r '.result')
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

printf "%s\n" "${upstreams[@]}"

