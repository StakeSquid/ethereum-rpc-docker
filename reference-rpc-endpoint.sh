#!/bin/bash

if [ $# -gt 2 ]; then
    exit 1
fi

read -r id
if [ -z "$id" ]; then
    id="$1"
fi

if [[ $id == 0x* ]]; then
    id=$(printf "%d" "$id")
fi

index="${2:-0}"

json_file="reference-rpc-endpoint.json"
if [ ! -f "$json_file" ]; then
    exit 1
fi

object=$(jq --arg id "$id" '.[] | select(.id == ($id | tonumber))' "$json_file")

if [ -z "$object" ]; then
    exit 1
fi

urls=$(echo "$object" | jq -r '.urls')

num_urls=$(echo "$urls" | jq -r 'length')
if [ "$index" -ge "$num_urls" ]; then
    exit 1
fi

url=$(echo "$urls" | jq -r ".[$index]")

echo "$url"
