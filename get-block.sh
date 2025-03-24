#!/bin/bash

request="{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"${2:-latest}\",false],\"id\":1}' | jq -r '.result.number, .result.hash' | gawk '{if (NR==1) print \"Block Number:\", strtonum($0); else print \"Block Hash:\", $0}"

echo "${request}"

curl -s -X POST "${1}" -H "Content-Type: application/json" --data "'${request}'"
