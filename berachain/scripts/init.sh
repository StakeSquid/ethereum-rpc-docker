#!/bin/sh

set -e  # Exit on failure

echo "MONIKER: $MONIKER"

CHAINID=${CHAINID:-80069}
CHAINNAME=${CHAINNAME:-bepolia}
AUTH_RPC=${AUTH_RPC:-http://berachain-bepolia:8551} # just as example

#if [ "$CHAINNAME" == "mainnet" ]; then
#    export CHAIN_SPEC="mainnet"
#else
#    export CHAIN_SPEC="testnet"
#fi

BEACOND=${BEACOND_PATH:-beacond}
CONFIG_DIR="/root/.beacond/config"

# Create config directory
mkdir -p "$CONFIG_DIR"

JWTSECRET="$(cat /jwtsecret)" # needs to go to the config dir (default path)
P2P_STRING="tcp:\\/\\/0\\.0\\.0\\.0\\:${P2P_PORT:-55696}"
NAT_STRING="${IP}:${P2P_PORT:-55696}"

echo "$JWTSECRET" > "$CONFIG_DIR/jwt.hex"

SEEDS_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/$CHAINID/cl-seeds.txt"


env

# this goes first because it won't overwrite shit
apk add curl
if [ $? -ne 0 ]; then exit 1; fi

if $BEACOND init ${MONIKER} --beacon-kit.chain-spec ${CHAIN_SPEC:-mainnet} --chain-id ${CHAINNAME}-beacon-${CHAINID} --home /root/.beacond/; then
    # Define variables
    CONFIG_TOML_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/$CHAINID/config.toml"
    APP_TOML_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/$CHAINID/app.toml"
    # SEEDS_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/$CHAINID/cl-seeds.txt"
    KZG_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/$CHAINID/kzg-trusted-setup.json"
    ETH_GENESIS_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/$CHAINID/eth-genesis.json"
    GENESIS_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/$CHAINID/genesis.json"    
    
    # Download config files
    curl -sL "$GENESIS_URL" -o "$CONFIG_DIR/genesis.json"    
    curl -sL "$ETH_GENESIS_URL" -o "$CONFIG_DIR/eth-genesis.json"
    curl -sL "$KZG_URL" -o "$CONFIG_DIR/kzg-trusted-setup.json"
    curl -sL "$CONFIG_TOML_URL" -o "$CONFIG_DIR/config.toml"
    curl -sL "$APP_TOML_URL" -o "$CONFIG_DIR/app.toml"

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


# Fetch and format SEEDS
# Add fresh seeds to the config from the official repository
# curl will fail with error status if the file is not found due to the -f flag

OFFICIAL_SEEDS=$(curl -f -s "$SEEDS_URL" | tail -n +2 | tr '\n' ',' | sed 's/,$//')
CURL_EXIT_CODE=$?

if [ $CURL_EXIT_CODE -ne 0 ]; then
    echo "Failed to fetch seeds from the official repository: $SEEDS_URL" >&2
else
    echo "Fetched seeds from the official repository, merging with configured seeds"
    SEEDS=$(echo "${SEEDS},${OFFICIAL_SEEDS}" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd,)
fi

# Update the config.toml file
if [ -n "$SEEDS" ]; then
    sed -i "s/^seeds = \".*\"/seeds = \"${SEEDS}\"/" "$CONFIG_DIR/config.toml"
fi

if [ -n "$PERSISTENT_PEERS" ]; then
    sed -i "s/^persistent_peers = \".*\"/persistent_peers = \"${PERSISTENT_PEERS}\"/" "$CONFIG_DIR/config.toml"
fi

# Update RPC dial URL in app.toml
if [ -f "$CONFIG_DIR/app.toml" ]; then
    sed -i "s|^rpc-dial-url = \".*\"|rpc-dial-url = \"$AUTH_RPC\"|" "$CONFIG_DIR/app.toml"
fi

# Update moniker if set
if [ -n "$MONIKER" ] && [ -f "$CONFIG_DIR/config.toml" ]; then
    sed -i "s/^moniker = \".*\"/moniker = \"$MONIKER\"/" "$CONFIG_DIR/config.toml"
fi


#echo "$CONFIG_DIR/jwt.hex: $(cat $CONFIG_DIR/jwt.hex)"

#cd "$CONFIG_DIR"

# Execute beacond
#exec $BEACOND start --beacon-kit.kzg.trusted-setup-path /root/.beacond/config/kzg-trusted-setup.json --minimum-gas-prices 0atom "$@"


if [ "$CHAIN_SPEC" = "testnet" ]; then
    exec $BEACOND start --beacon-kit.chain-spec testnet --home /root/.beacond $@
else
    exec $BEACOND start --home /root/.beacond $@
fi
# --beacon-kit.engine.jwt-secret-path $CONFIG_DIR/jwt.hex --beacon-kit.kzg.trusted-setup-path $CONFIG_DIR/kzg-trusted-setup.json --home /root/.beacond 
#--minimum-gas-prices 0atom
