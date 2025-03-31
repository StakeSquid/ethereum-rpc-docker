#!/bin/bash

# Exit on error and show commands
set -ex

# Verify snapshot URL is provided
if [ -z "$SNAPSHOT_URL" ]; then
  echo "Error: SNAPSHOT_URL environment variable not set"
  exit 1
fi

# Install required tools
apk add --no-cache wget tar zstd

# Create and prepare directories
mkdir -p /tomochain/data/tomo/chaindata
rm -rf /tomochain/data/tomo/chaindata/*

# Download and extract chain data
echo "Downloading CHAIN_DATA from ${SNAPSHOT_URL}"
wget -q --show-progress -c "${SNAPSHOT_URL}/CHAIN_DATA.tar.zst" -O - | \
  tar -I zstd -xvf - -C /tomochain/data/tomo/chaindata

# Create and prepare tomox directory
mkdir -p /tomochain/data/tomox
rm -rf /tomochain/data/tomox/*

# Download and extract tomox data
echo "Downloading TOMOX_DATA from ${SNAPSHOT_URL}"
wget -q --show-progress -c "${SNAPSHOT_URL}/TOMOX_DATA.tar.zst" -O - | \
  tar -I zstd -xvf - -C /tomochain/data/tomox

echo "Download and extraction complete"
