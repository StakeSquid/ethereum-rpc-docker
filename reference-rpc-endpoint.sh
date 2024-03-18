#!/bin/bash

# Check if the script is provided with the correct number of arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <id> <index>"
    exit 1
fi

# ID and index provided as arguments
id="$1"
index="$2"

# Check if the JSON file exists
json_file="reference-rpc-endpoint.json"
if [ ! -f "$json_file" ]; then
    echo "Error: JSON file '$json_file' not found."
    exit 1
fi

# Use jq to find the object with the provided id
object=$(jq --arg id "$id" '.[] | select(.id == ($id | tonumber))' "$json_file")

# Check if the object exists
if [ -z "$object" ]; then
    echo "Error: Object with ID '$id' not found."
    exit 1
fi

# Extract the URLs array from the object
urls=$(echo "$object" | jq -r '.urls')

# Check if the index is out of range
num_urls=$(echo "$urls" | jq -r 'length')
if [ "$index" -ge "$num_urls" ]; then
    echo "Error: Index '$index' is out of range for ID '$id'."
    exit 1
fi

# Extract the URL at the specified index
url=$(echo "$urls" | jq -r ".[$index]")

# Print the URL
echo "URL at index '$index' for ID '$id': $url"
