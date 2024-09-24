#!/bin/bash

# Check if JSON file is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <key1> [key2 ...]"
  exit 1
fi

BASEPATH="$(dirname "$0")"

JSON_FILE="$BASEPATH/reference-rpc-endpoint.json"

# Function to extract values for a given key
extract_values() {
  local key=$1
  cat "$JSON_FILE" | jq -r --arg key "$key" '.[$key] | if .default then .default[] else [] end, if .archive then .archive[] else [] end'
}

# Initialize an empty result string
result=""

# Iterate over each key passed as a parameter
for key in "$@"; do
  # Append the values from the key to the result string
  values=$(extract_values "$key")
  result="$result $values"
done

# Trim and display the result
echo $result | xargs
