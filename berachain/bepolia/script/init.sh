#!/bin/sh

set -e  # Exit on failure

/usr/bin/apk add --no-cache curl

# this goes first because it won't overwrite shit
/usr/bin/beacond init ${MONIKER} --chain-id bepolia-beacon-80069 --consensus-key-algo bls12_381 --home /root/.beacond/

# Define variables
CONFIG_DIR="/root/.beacond/config"
CONFIG_TOML_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/80069/config.toml"
APP_TOML_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/80069/app.toml"
SEEDS_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/80069/cl-seeds.txt"

# Create config directory
mkdir -p "$CONFIG_DIR"

# Download config files
curl -sL "$CONFIG_TOML_URL" -o "$CONFIG_DIR/config.toml"
curl -sL "$APP_TOML_URL" -o "$CONFIG_DIR/app.toml"

# Update moniker if set
if [ -n "$MONIKER" ] && [ -f "$CONFIG_DIR/config.toml" ]; then
  sed -i "s/^moniker = \".*\"/moniker = \"$MONIKER\"/" "$CONFIG_DIR/config.toml"
fi

# Fetch and format SEEDS
SEEDS=$(curl -s "$SEEDS_URL" | tail -n +2 | tr '\n' ',' | sed 's/,$//')

# Update seeds and persistent_peers
if [ -n "$SEEDS" ] && [ -f "$CONFIG_DIR/config.toml" ]; then
  sed -i "s/^seeds = \".*\"/seeds = \"$SEEDS\"/" "$CONFIG_DIR/config.toml"
  sed -i "s/^persistent_peers = \".*\"/persistent_peers = \"$SEEDS\"/" "$CONFIG_DIR/config.toml"
fi

# Update RPC dial URL in app.toml
if [ -f "$CONFIG_DIR/app.toml" ]; then
  sed -i "s|^rpc-dial-url = \".*\"|rpc-dial-url = \"http://berachain-bepolia:8551\"|" "$CONFIG_DIR/app.toml"
fi

# Execute beacond
exec /usr/bin/beacond start --beacon-kit.kzg.trusted-setup-path /root/.beacond/config/kzg-trusted-setup.json --minimum-gas-prices 0atom "$@"
