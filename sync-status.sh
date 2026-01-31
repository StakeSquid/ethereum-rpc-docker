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
else
    PROTO="https"
fi

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "stripprefix\.prefixes.*?/\K[^\"]+")

for path in $pathlist; do
    include=true
    for word in "${blacklist[@]}"; do
        if echo "$path" | grep -qE "$word"; then
            if echo "$path" | grep -qE "viction"; then
              # excemption
              include=$include
            else
              include=false
            fi
        fi
    done
        
    if $include; then
        RPC_URL="$PROTO://$DOMAIN/$path"

        # Detect Starknet vs Ethereum vs Aztec based on path
        if echo "$path" | grep -qi "starknet"; then
            is_starknet=true
            is_aztec=false
        elif echo "$path" | grep -qi "aztec"; then
            is_starknet=false
            is_aztec=true
        else
            is_starknet=false
            is_aztec=false
        fi

        ref=''
        if [ -n "$2" ]; then
            ref="$2"
        else
            if $is_aztec; then
                # Aztec: resolve ref by rollup_version from node (result.header.globalVariables.version)
                aztec_block_response=$(curl -L --ipv4 -m 1 -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"node_getBlock","params":["latest"],"id":1}' $RPC_URL)
                if [ $? -ne 0 ]; then
                    echo "error: failed to get Aztec block from $RPC_URL"
                    exit 1
                fi
                version_hex=$(echo "$aztec_block_response" | jq -r '.result.header.globalVariables.version' 2>/dev/null)
                if [ -z "$version_hex" ] || [ "$version_hex" = "null" ]; then
                    echo "error: could not parse rollup version from Aztec node"
                    exit 1
                fi
                # Convert hex (e.g. 0x950a893d) to decimal for JSON lookup
                version_decimal=$((16#${version_hex#0x}))
                ref=$($BASEPATH/reference-rpc-endpoint.sh --rollup-version "$version_decimal")
                if [ $? -ne 0 ]; then
                    echo "error: no reference endpoint for Aztec rollup_version $version_decimal"
                    exit 1
                fi
            elif $is_starknet; then
                # Starknet chain ID detection
                chain_id_response=$(curl -L --ipv4 -m 1 -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"starknet_chainId","params":[],"id":1}' $RPC_URL)

                if [ $? -eq 0 ]; then
                    chain_id=$(echo "$chain_id_response" | jq -r '.result' 2>/dev/null)

                    # Map Starknet chain IDs to reference endpoints
                    # Chain ID can be plain string or hex-encoded ASCII
                    case "$chain_id" in
                        "SN_MAIN"|"0x534e5f4d41494e")
                            ref=$($BASEPATH/reference-rpc-endpoint.sh 23448594291968336)
                            ;;
                        "SN_SEPOLIA"|"0x534e5f5345504f4c4941")
                            ref=$($BASEPATH/reference-rpc-endpoint.sh 393402133025997800000000)
                            ;;
                        *)
                            echo "error: unknown starknet chain $chain_id"
                            exit 1
                            ;;
                    esac
                else
                    echo "error"
                    exit 1
                fi
            else
                # Ethereum chain ID detection
                chain_id_response=$(curl -L --ipv4 -m 1 -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' $RPC_URL)

                if [ $? -eq 0 ]; then
                    chain_id=$(echo "$chain_id_response" | jq -r '.result' 2>/dev/null)

                    # echo "$RPC_URL: $chain_id"

                    if [[ "$chain_id" =~ ^0x[0-9a-fA-F]+$ ]]; then
                        chain_id_decimal=$((16#${chain_id#0x}))
                        ref=$($BASEPATH/reference-rpc-endpoint.sh $chain_id_decimal)
                    else
                        echo "error"
                        exit 1
                    fi
                else
                    echo "error"
                    exit 1
                fi
            fi
        fi

        # Call the health check script with RPC_URL, ref, and chain-type flag
        if $is_aztec; then
            $BASEPATH/check-health.sh "$RPC_URL" --aztec $ref
        elif $is_starknet; then
            $BASEPATH/check-health.sh "$RPC_URL" --starknet $ref
        else
            $BASEPATH/check-health.sh "$RPC_URL" $ref
        fi
        exit $?
    fi
done

echo "unverified"
exit 1
