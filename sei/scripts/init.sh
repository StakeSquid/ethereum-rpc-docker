#!/bin/sh

set -e  # Exit on failure

echo "MONIKER: $MONIKER"

HOME_DIR="/root/.sei"
CONFIG_DIR="$HOME_DIR/config"

# Create config directory
mkdir -p "$CONFIG_DIR"

P2P_STRING="tcp:\\/\\/0\\.0\\.0\\.0\\:${P2P_PORT:-55696}"
NAT_STRING="${IP}:${P2P_PORT:-55696}"

env

if seid init ${MONIKER} --chain-id ${CHAIN_SPEC:-sei} --home $HOME_DIR/; then
   
    # somehow it's better to make home static to /root
    sed -i 's|~/|/root/|g' "$CONFIG_DIR/config.toml"
    sed -i 's|~/|/root/|g' "$CONFIG_DIR/app.toml"

    sed -i 's/minimum-gas-prices = ""/minimum-gas-prices = "0.01usei"/g' $CONFIG_DIR/app.toml
else
    echo "Already initialized, continuing!" >&2
fi

# apply a port change to the config
sed -i "/^\[p2p\]/,/^\[/{s|^laddr = .*|laddr = \"$P2P_STRING\"|}" "$CONFIG_DIR/config.toml"
#sed -i "s/^laddr = \".*\"/laddr = \"$P2P_STRING\"/" "$CONFIG_DIR/config.toml"
sed -i "/^\[p2p\]/,/^\[/{s|^external_address = .*|external_address = \"$NAT_STRING\"|}" "$CONFIG_DIR/config.toml"

# Update moniker if set
if [ -n "$MONIKER" ] && [ -f "$CONFIG_DIR/config.toml" ]; then
    sed -i "s/^moniker = \".*\"/moniker = \"$MONIKER\"/" "$CONFIG_DIR/config.toml"
fi

if [ -e $CONFIG_DIR/priv_validator_state.json ]; then
if [ ! -e $HOME_DIR/data/priv_validator_state.json ]; then
  cp $CONFIG_DIR/priv_validator_state.json $HOME_DIR/data/priv_validator_state.json
fi
fi

exec seid start --chain-id ${CHAIN_SPEC:-sei-testnet-1} --home $HOME_DIR --db_dir $HOME_DIR/data $@
