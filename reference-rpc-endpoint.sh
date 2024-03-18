#!/bin/bash

# Check if the script is provided with the correct number of arguments
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <key> [<index>]"
    exit 1
fi

# Key provided as the first argument
key="$1"

# Set index to 0 if not provided as the second argument
index="${2:-0}"

# Check if the JSON file exists
json_file="reference-rpc-endpoint.json"
if [ ! -f "$json_file" ]; then
    echo "Error: JSON file '$json_file' not found."
    exit 1
fi

# Use jq to extract the element of the array corresponding to the key and index
element=$(jq -r ".$key[$index]" "$json_file")

# Check if the key exists in the JSON file
if [ "$element" = "null" ]; then
    echo "Error: Key '$key' not found in the JSON file or index '$index' out of range."
    exit 1
fi

# Print the element
echo "$element"
