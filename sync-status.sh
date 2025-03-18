#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

blacklist=()
while IFS= read -r line; do
    # Add each line to the array
    blacklist+=("$line")
done < "$BASEPATH/path-blacklist.txt"

if $NO_SSL; then
    PROTO="http"
    DOMAIN="${DOMAIN:-0.0.0.0}"
else
    PROTO="https"
fi

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "(?<=PathPrefix).*\"" | cut -d'`' -f2-2)

for path in $pathlist; do
    include=true
    for word in "${blacklist[@]}"; do
        if echo "$path" | grep -qE "$word"; then
            include=false
        fi
    done
        
    if $include; then
        RPC_URL="$PROTO://$DOMAIN$path"

        ref=''
        if [ -n "$2" ]; then
            ref="$2"
        else
            chain_id=$(curl --ipv4 -m 1 -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' $RPC_URL | jq -r '.result')
            chain_id_decimal=$((16#${chain_id#0x}))
            ref=$($BASEPATH/reference-rpc-endpoint.sh $chain_id_decimal)
        fi

        # Call the health check script with RPC_URL and ref
        $BASEPATH/check-health.sh "$RPC_URL" "$ref"
        exit $?
    fi
done

echo "not found"
exit 1
