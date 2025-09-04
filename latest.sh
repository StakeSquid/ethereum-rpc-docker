#!/bin/bash

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
fi

blocktag=${2:-latest}

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "stripprefix\.prefixes.*?/\K[^\"]+")
                                                     
for path in $pathlist; do                                                                                  
    include=true                                                                                           
    for word in "${blacklist[@]}"; do
        if echo "$path" | grep -qE "$word"; then
            include=false
        fi
    done

    if $include; then
        RPC_URL="${PROTO:-https}://$DOMAIN/$path"

	if curl -L -s -X POST $RPC_URL      -H "Content-Type: application/json"      --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["${blocktag}",false],"id":1}' | jq -r '.result.number, .result.hash' | gawk '{if (NR==1) print "Block Number:", strtonum($0); else print "Block Hash:", $0}'; then
	    exit 0
	else
	    if curl -L -s -X POST $RPC_URL      -H "Content-Type: application/json"      --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["${blocktag}",false],"id":1}' | jq; then
		exit 1
	    else
		curl -L -vv -X POST $RPC_URL      -H "Content-Type: application/json"      --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["${blocktag}",false],"id":1}'
	    fi		 
	fi
    fi
done
