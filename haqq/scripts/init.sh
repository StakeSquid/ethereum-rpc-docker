#!/bin/sh

set -e  # Exit on failure

echo "MONIKER: $MONIKER"

CHAINID=${CHAINID:-haqq_11235-1}
CHAINNAME=${CHAINNAME:-mainnet}

CONFIG_DIR="/root/.haqqd/config"

# Create config directory
mkdir -p "$CONFIG_DIR"

JWTSECRET="$(cat /jwtsecret)" # needs to go to the config dir (default path)
P2P_STRING="tcp:\\/\\/0\\.0\\.0\\.0\\:${P2P_PORT:-10465}"
NAT_STRING="${IP}:${P2P_PORT:-10465}"

env

# this goes first because it won't overwrite shit
apk add curl
if [ $? -ne 0 ]; then exit 1; fi

if haqqd init ${MONIKER} --chain-id ${CHAINID} --home /root/.haqqd/; then
    # Define variables
    GENESIS_URL="https://raw.githubusercontent.com/haqq-network/${CHAINNAME}/master/genesis.json"    
    ADDRESSBOOK_URL="https://raw.githubusercontent.com/haqq-network/${CHAINNAME}/master/addrbook.json"
    
    # Download config files
    curl -sL "$GENESIS_URL" -o "$CONFIG_DIR/genesis.json"    
    curl -sL "$ADDRESSBOOK_URL" -o "$CONFIG_DIR/addressbook.json"

    # somehow it's better to make home static to /root
    sed -i 's|~/|/root/|g' "$CONFIG_DIR/config.toml"
    sed -i 's|~/|/root/|g' "$CONFIG_DIR/app.toml"
else
    echo "Already initialized, continuing!" >&2
fi


# apply a port change to the config
sed -i "/^\[p2p\]/,/^\[/{s|^laddr = .*|laddr = \"$P2P_STRING\"|}" "$CONFIG_DIR/config.toml"
#sed -i "s/^laddr = \".*\"/laddr = \"$P2P_STRING\"/" "$CONFIG_DIR/config.toml"
sed -i "/^\[p2p\]/,/^\[/{s|^external_address = .*|external_address = \"$NAT_STRING\"|}" "$CONFIG_DIR/config.toml"

#sed -i 's/minimum-gas-prices = ""/minimum-gas-prices = "0.01hqq"/g' $CONFIG_DIR/app.toml

sed -i -e "s/^pruning *=.*/pruning = \"custom\"/" $CONFIG_DIR/app.toml
sed -i -e "s/^pruning-keep-recent *=.*/pruning-keep-recent = \"100\"/" $CONFIG_DIR/app.toml
sed -i -e "s/^pruning-interval *=.*/pruning-interval = \"19\"/" $CONFIG_DIR/app.toml
sed -i -e "s/^indexer *=.*/indexer = \"null\"/" $CONFIG_DIR/config.toml

sed -i "/^\[json-rpc\]/,/^\[/{s|^address = .*|address = \"tcp://0.0.0.0:8545\"|}" "$CONFIG_DIR/app.toml"
sed -i "/^\[json-rpc\]/,/^\[/{s|^ws-address = .*|ws-address = \"tcp://0.0.0.0:8546\"|}" "$CONFIG_DIR/app.toml"
sed -i "/^\[json-rpc\]/,/^\[/{s|^metrics-address = .*|metrics-address = \"tcp://0.0.0.0:6065\"|}" "$CONFIG_DIR/app.toml"

# Update moniker if set
if [ -n "$MONIKER" ] && [ -f "$CONFIG_DIR/config.toml" ]; then
    sed -i "s/^moniker = \".*\"/moniker = \"$MONIKER\"/" "$CONFIG_DIR/config.toml"
fi

exec haqqd start --chain-id ${CHAINID} $@
