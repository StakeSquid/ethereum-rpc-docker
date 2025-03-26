#!/bin/bash

# Check if more than two arguments are provided
if [ $# -gt 2 ]; then
    echo "Usage: $0 <chainid> [<index>]"
    exit 1
fi

id="$1"
index="${2:-all}"

# Convert hex id to decimal if necessary
if [[ "$id" == "0x"* ]]; then
    id=$(printf "%d" "$id")
fi

json_file="/root/rpc/reference-rpc-endpoint.json"

# Check if JSON file exists
if [ ! -f "$json_file" ]; then
    echo "JSON file not found: $json_file"
    exit 1
fi

# Find the object with matching id
object=$(jq --arg id "$id" '.[] | select(.id == ($id | tonumber))' "$json_file")

# If object not found, exit
if [ -z "$object" ]; then
    echo "Chain ID not found: $id"
    exit 1
fi

# Extract URLs from the object
urls=$(echo "$object" | jq -r '.urls')

# If index is set to 'all', return all URLs separated by whitespace
if [ "$index" = "all" ]; then
    echo "$urls" | jq -r '.[]' | tr '\n' ' '
    exit
fi

# Otherwise, treat index as numeric
# Validate that index is a number
if ! [[ "$index" =~ ^[0-9]+$ ]]; then
    echo "Invalid index: $index"
    exit 1
fi

# Get the number of URLs
num_urls=$(echo "$urls" | jq -r 'length')

# Check if index is within bounds
if [ "$index" -ge "$num_urls" ]; then
    echo "Index out of bounds: $index (max $(($num_urls - 1)))"
    exit 1
fi

# Get and print the URL at the specified index
url=$(echo "$urls" | jq -r ".[$index]")
echo "$url"
