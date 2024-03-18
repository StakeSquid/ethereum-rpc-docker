#!/bin/bash

# Check if the script is provided with the correct number of arguments
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <id> [<index>]"
    exit 1
fi

# ID and index provided as arguments
id="$1"

# Set index to 0 if not provided as the second argument
index="${2:-0}"

# Check if the JSON file exists
json_file="reference-rpc-endpoint.json"
if [ ! -f "$json_file" ]; then
    exit 1
fi

# Use jq to find the object with the provided id
object=$(jq --arg id "$id" '.[] | select(.id == ($id | tonumber))' "$json_file")

# Check if the object exists
if [ -z "$object" ]; then
    exit 1
fi

# Extract the URLs array from the object
urls=$(echo "$object" | jq -r '.urls')

# Check if the index is out of range
num_urls=$(echo "$urls" | jq -r 'length')
if [ "$index" -ge "$num_urls" ]; then
    #echo "Error: Index '$index' is out of range for ID '$id'."
    exit 1
fi

# Extract the URL at the specified index
url=$(echo "$urls" | jq -r ".[$index]")

# Print the URL
echo "$url"
