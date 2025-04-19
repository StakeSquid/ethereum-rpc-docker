#!/bin/bash

# USAGE:
#  ./op-wheel-finalize-latest-block.sh <client_service_name> (<node_service_name>)

RPC_URL="http://$1:8545"

latest=$(docker run -it --network=rpc_chains --rm docker.io/curlimages/curl -L -s -X POST $RPC_URL      -H "Content-Type: application/json"      --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' | jq -r '.result.number')

if [ $? -ne 0 ]; then
    echo "Failed to get latest block number"
    exit 1
fi

if [ -z "$latest" ]; then
    echo "Latest block number is empty"
    exit 1
fi

if [ -n "$2" ]; then
    docker stop rpc-${2}-1 
else
    docker stop rpc-${1}-node-1 
fi

./op-wheel.sh engine set-forkchoice --unsafe=$latest --safe=$latest --finalized=$latest --engine=http://$1:8551 --engine.jwt-secret-path=/jwtsecret --engine.open=http://$1:8545
docker compose up -d


