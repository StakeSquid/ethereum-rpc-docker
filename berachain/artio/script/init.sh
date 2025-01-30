#!/bin/bash

# Define variables
CONFIG_DIR="/root/.beacond/config"
CONFIG_TOML_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/80084/config.toml"
APP_TOML_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/80084/app.toml"
SEEDS_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/80084/cl-seeds.txt"

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# Download the config files
curl -sL "$CONFIG_TOML_URL" -o "$CONFIG_DIR/config.toml"
curl -sL "$APP_TOML_URL" -o "$CONFIG_DIR/app.toml"

# Update moniker
if [ -n "$MONIKER" ]; then
  sed -i "s/^moniker = \".*\"/moniker = \"$MONIKER\"/" "$CONFIG_DIR/config.toml"
fi

# Fetch and format SEEDS
SEEDS=$(curl -s "$SEEDS_URL" | tail -n +2 | tr '\n' ',' | sed 's/,$//')

# Update seeds and persistent_peers
if [ -n "$SEEDS" ]; then
  sed -i "s/^seeds = \".*\"/seeds = \"$SEEDS\"/" "$CONFIG_DIR/config.toml"
  sed -i "s/^persistent_peers = \".*\"/persistent_peers = \"$SEEDS\"/" "$CONFIG_DIR/config.toml"
fi

sed -i "s|^rpc-dial-url = \".*\"|rpc-dial-url = \"http://berachain-artio:8551\"|" "$CONFIG_DIR/app.toml";


echo "Configuration updated successfully."
