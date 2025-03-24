#!/bin/bash

is_decimal() {
  [[ $1 =~ ^[0-9]+$ ]]
}

block_input=${2:-latest}

if is_decimal "$block_input"; then
  # Convert decimal to hexadecimal
  block_input=$(printf "%x" "$block_input")
fi

request="{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"${block_input}\",false],\"id\":1}" 

echo "${request}"

curl -s -X POST "${1}" -H "Content-Type: application/json" --data "'${request}'" | jq -r '.result.number, .result.hash' | gawk '{if (NR==1) print "Block Number:", strtonum($0); else print "Block Hash:", $0}'
