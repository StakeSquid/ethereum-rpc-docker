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

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "(?<=stripprefix\.prefixes).*\"" | cut -d'=' -f2- | sed 's/.$//')
                                                     
for path in $pathlist; do                                                                                  
    include=true                                                                                           
    for word in "${blacklist[@]}"; do
        if echo "$path" | grep -qE "$word"; then
            include=false
        fi
    done

    if $include; then
        RPC_URL="${PROTO:-https}://$DOMAIN$path"

	if curl -s -X POST $RPC_URL      -H "Content-Type: application/json"      --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' | jq -r '.result.number, .result.hash' | gawk '{if (NR==1) print "Block Number:", strtonum($0); else print "Block Hash:", $0}'; then
	    exit 0
	else
	    if curl -s -X POST $RPC_URL      -H "Content-Type: application/json"      --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' | jq; then
		exit 1
	    else
		curl -vv -X POST $RPC_URL      -H "Content-Type: application/json"      --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}'
	    fi		 
	fi
    fi
done
