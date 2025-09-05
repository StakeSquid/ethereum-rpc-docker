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

apk add curl jq
if [ $? -ne 0 ]; then exit 1; fi

if seid init ${MONIKER} --chain-id ${CHAIN_SPEC:-pacific-1} --home $HOME_DIR/; then
   
    # somehow it's better to make home static to /root
    sed -i 's|~/|/root/|g' "$CONFIG_DIR/config.toml"
    sed -i 's|~/|/root/|g' "$CONFIG_DIR/app.toml"

    sed -i 's/minimum-gas-prices = ""/minimum-gas-prices = "0.01usei"/g' $CONFIG_DIR/app.toml
    sed -i -e "s/^pruning *=.*/pruning = \"custom\"/" $CONFIG_DIR/app.toml
    sed -i -e "s/^pruning-keep-recent *=.*/pruning-keep-recent = \"100\"/" $CONFIG_DIR/app.toml
    sed -i -e "s/^pruning-interval *=.*/pruning-interval = \"19\"/" $CONFIG_DIR/app.toml
    sed -i -e "s/^indexer *=.*/indexer = \"null\"/" $CONFIG_DIR/config.toml
else
    echo "Already initialized, resetting!" >&2
    seid tendermint unsafe-reset-all --home $HOME_DIR
fi

STATYSYNC_RPC=https://sei-rpc.stakeme.pro:443
LATEST_HEIGHT=$(curl -s $STATYSYNC_RPC/block | jq -r .block.header.height)
BLOCK_HEIGHT=$((LATEST_HEIGHT - 10000))
TRUST_HASH=$(curl -s "$STATYSYNC_RPC/block?height=$BLOCK_HEIGHT" | jq -r .block_id.hash)
sed -i.bak -E "s|^(enable[[:space:]]+=[[:space:]]+).*$|\1true| ; \
s|^(rpc-servers[[:space:]]+=[[:space:]]+).*$|\1\"$STATYSYNC_RPC,$STATYSYNC_RPC\"| ; \
s|^(trust-height[[:space:]]+=[[:space:]]+).*$|\1$BLOCK_HEIGHT| ; \
s|^(trust-hash[[:space:]]+=[[:space:]]+).*$|\1\"$TRUST_HASH\"| ; \
s|^(seeds[[:space:]]+=[[:space:]]+).*$|\1\"\"|" $CONFIG_DIR/config.toml

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

exec seid start --chain-id ${CHAIN_SPEC:-pacific-1} --home $HOME_DIR $@
