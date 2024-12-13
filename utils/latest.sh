#!/bin/bash

curl -s -X POST $1      -H "Content-Type: application/json"      --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' | jq -r '.result.number, .result.hash' | awk '{if (NR==1) print "Block Number:", strtonum($0); else print "Block Hash:", $0}'
