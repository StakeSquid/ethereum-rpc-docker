#!/bin/bash

BASEPATH="$(dirname "$0")"
source "$BASEPATH/.env"

blacklist=()
while IFS= read -r line; do
    # Add each line to the array
    blacklist+=("$line")
done < "$BASEPATH/path-blacklist.txt"

pathlist=$(cat "$BASEPATH/$1.yml" | grep -oP "(?<=stripprefix\.prefixes).*\"" | cut -d'=' -f2- | sed 's/.$//')

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

        http_status_code=$(curl --ipv4 -m 1 -s -X POST -w "%{http_code}" -o "$response_file" -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}' "$RPC_URL")

        if [ $? -eq 0 ]; then
            if [[ $http_status_code -eq 200 ]]; then
                response=$(cat "$response_file")
                latest_block_timestamp=$(echo "$response" | jq -r '.result.timestamp')
                current_timestamp=$(date +%s)
                age=$((current_timestamp - ("16#${latest_block_timestamp#0x}")))
                
                if (( age < ${2:-3600} )); then
                    echo "Block is less than ${2:-3600} seconds old. Age: $age seconds"
                    exit 0
                else
                    echo "Block is older than ${2:-3600} seconds. Age: $age seconds"
                    exit 1
                fi
            fi
        fi
        break
    fi
done

exit 1
