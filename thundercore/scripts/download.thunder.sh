#!/bin/sh

# Exit on error and show commands
set -ex

# Verify snapshot URL is provided
if [ -z "$SNAPSHOT_URL" ]; then
  echo "Error: SNAPSHOT_URL environment variable not set"
  exit 1
fi

# Install required tools
apk add --no-cache wget tar gzip

# Create and prepare directories
rm -rf /datadir/*

url=$(wget -q -O - $SNAPSHOT_URL)
echo "downloading $url"

wget --show-progress -c $url -O - | tar -C /datadir -zx

echo "Download and extraction complete"
