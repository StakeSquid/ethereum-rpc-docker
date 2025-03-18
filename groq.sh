#!/bin/bash

# Determine the script's base directory
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables from .env file
if [ -f "$BASEDIR/.env" ]; then
    source "$BASEDIR/.env"
fi

# Ensure GROQ_API_KEY is set
if [ -z "$GROQ_API_KEY" ]; then
    echo "Error: GROQ_API_KEY is not set. Please define it in $BASEDIR/.env"
    exit 1
fi

# Validate input argument
if [ -z "$1" ] || [ ! -f "$BASEDIR/rpc/$1.yml" ]; then
    echo "Error: Either no argument provided or $BASEDIR/rpc/$1.yml does not exist."
    exit 1
fi

# Build the container
docker build -t rpc_sync_checker "$BASEDIR/groq"

# Run logs.sh and feed logs into the sync checker container
"$BASEDIR/logs.sh" "$1" | docker run --rm -i -e GROQ_API_KEY="$GROQ_API_KEY" rpc_sync_checker
