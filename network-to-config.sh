#!/bin/bash

# Check if JSON file is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <key1> [key2 ...]"
  exit 1
fi

BASEPATH="$(dirname "$0")"

JSON_FILE="$BASEPATH/reference-rpc-endpoint.json"
shift

# Extract values under 'default' or 'archive' attributes for given keys
jq --argfile input "$JSON_FILE" '. as $in | ($IN.input | select(has("default")) | .default[]) + ($IN.input | select(has("archive")) | .archive[])' "$@"
