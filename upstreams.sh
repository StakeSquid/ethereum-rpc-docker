#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

GENERATE_ID_FROM_PATH_EXPRESSION=${GENERATE_ID_FROM_PATH_EXPRESSION:-'s/^rpc-(.*)\.stakesquid\.eu\/(.*)$/\1-\2/'}

LOCAL=${1:-false}

if [ -n "$NO_SSL" ]; then
    PROTO="http"
    DOMAIN="${DOMAIN:-0.0.0.0}"
else
    PROTO="https"
fi

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

	#pathlist=$(cat $BASEPATH/$part | grep -oP "(?<=stripprefix\.prefixes).*\"" | cut -d'=' -f2- | sed 's/.$//')
        pathlist=$(cat $BASEPATH/$part | grep -oP "(?<=PathPrefix).*\"" | cut -d'`' -f2-2)

	for path in $pathlist; do
	    path_include=true
	    for word in "${path_blacklist[@]}"; do
		if echo "$path" | grep -qE "$word"; then
		    path_include=false
		fi
	    done
	    
	    if $path_include; then
		
		#echo "LOCAL: $LOCAL"
		if $LOCAL; then
		    url=$("$BASEPATH/get-local-url.sh" "${part%.yml}")
                    export TEST_URL="$PROTO://$DOMAIN$path"
		    export RPC_URL="http://$url"
		    export WS_URL="ws://$url"		   
		    export ID=$(echo "$DOMAIN$path" | sed -E "$GENERATE_ID_FROM_PATH_EXPRESSION")
		else
		    url="$DOMAIN$path"
		    export RPC_URL="$PROTO://$url"
		    export TEST_URL="$RPC_URL"
		    export WS_URL="wss://$url"		    
                    export ID=$(echo "$url" | sed -E "$GENERATE_ID_FROM_PATH_EXPRESSION")
		fi
		
		export PROVIDER=${ORGANIZATION}-${ID}

		response_file=$(mktemp)
		
		http_status_code=$(curl -L --ipv4 -m 5 -s -o "$response_file" -w "%{http_code}" -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' $TEST_URL)

		curl_status=$?
		
		if [ $? -eq 0 ] && [[ $http_status_code -ne 200 ]]; then
		    echo "have error response from $TEST_URL: $(cat $response_file)" >&2
		    rm "$response_file"
		    continue  # Skip to the next iteration of the loop
		fi
		
		chain_id=$(cat "$response_file" | jq -r '.result')
		#echo "$http_status_code: $(cat $response_file)"
		rm "$response_file"
		
		#echo "$TEST_URL $chain_id" >&2
		chain_id_decimal=$((16#${chain_id#0x}))
		export CHAIN=$($BASEPATH/get-shortname.sh $chain_id_decimal)
		
		# Define the path to the input YAML file
		input_file="$BASEPATH/${part%.yml}.cfg"

		[ -f "$input_file" ] || input_file="$BASEPATH/default.cfg"

		# Run envsubst to replace environment variables in the input file and save the result to the output file
		if yaml2json < "$BASEPATH/$part" | jq -e '.upstreams' >/dev/null 2>&1; then
		    echo "upstreams key exists in $part"
		    upstreams+=($(yaml2json < "$BASEPATH/$part" | jq '.upstreams' | sed 's/^/  /' | envsubst | json2yaml))
		else
		    echo "upstreams config $input_file for $part"
		    upstreams+=("$(envsubst < "$input_file")")		    
		fi
		
		break
	    fi
	done	
    fi
done


if [[ -f $BASEPATH/external-rpcs.txt ]]; then
while IFS= read -r url; do
    #echo $url
    export RPC_URL="$url"
    export TEST_URL="$RPC_URL"
    export WS_URL=$(echo "$url" | sed -e 's|^http://|ws://|' -e 's|^https://|wss://|')
    export PROVIDER=$(echo "$url" | sed -e 's|^https\?://||' -e 's|/|-|g' -e 's|\.|-|g')
    export ID="id-$PROVIDER"
    
    response_file=$(mktemp)

    http_status_code=$(curl -L --ipv4 -m 5 -s -o "$response_file" -w "%{http_code}" -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' $TEST_URL < /dev/null)
    # if I do not echo that one then the script doesn't iterate over the list of urls properly ^^
    echo "$(cat $response_file)" >&2
    #echo $http_status_code
    
    if [ $? -eq 0 ] && [[ $http_status_code -ne 200 ]]; then
	echo "have error response from $TEST_URL: $(cat $response_file)" >&2
	rm "$response_file"
	continue  # Skip to the next iteration of the loop
    fi
		
    chain_id=$(cat "$response_file" | jq -r '.result')		
    rm "$response_file"
    
    echo "$TEST_URL $chain_id" >&2
    chain_id_decimal=$((16#${chain_id#0x}))
    export CHAIN=$($BASEPATH/get-shortname.sh $chain_id_decimal)

    input_file="$BASEPATH/$(echo $url | sed -E 's|https?://([^.]+\.)*([^.]+\.[^.]+).*|\2|').cfg"

    #echo "$input_file"
    
    [ -f "$input_file" ] || input_file="$BASEPATH/default.cfg"


		
    # Run envsubst to replace environment variables in the input file and save the result to the output file
    upstreams+=("$(envsubst < "$input_file")")

done < $BASEPATH/external-rpcs.txt
fi

printf "%s\n" "${upstreams[@]}"

