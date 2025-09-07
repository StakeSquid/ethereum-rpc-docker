#!/bin/sh

set -e  # Exit on failure

if [ $# -lt 1 ]; then
    echo "Error: No argument provided. Please specify '0gchaind' or 'geth' as the first argument."
    exit 1
fi

MODE="$1"
shift

case "$MODE" in
    0gchaind)
        # Continue with 0gchaind-specific logic (rest of script)
        ;;
    geth)
        GETH_DATA_DIR="/root/.ethereum/"

        if [ ! -f "$GETH_DATA_DIR/initialized" ]; then
            /0g/bin/geth init --datadir $GETH_DATA_DIR /0g/genesis.json
            touch "$GETH_DATA_DIR/initialized"
        else
            echo "Already initialized, continuing!" >&2
        fi

        exec /0g/bin/geth $@
        exit 0
        ;;
    *)
        echo "Error: Unknown argument '$MODE'. Please specify '0gchaind' or 'geth'."
        exit 1
        ;;
esac

echo "MONIKER: $MONIKER"

AUTH_RPC=${AUTH_RPC:-http://0g-$CHAIN_NAME:8551} # just as example

HOME_DIR="/root/.0g"
mkdir -p $HOME_DIR

CONFIG_DIR="$HOME_DIR/config"
DATA_DIR="$HOME_DIR/data"

mkdir $CONFIG_DIR
mkdir $DATA_DIR

SEEDS_URL="https://raw.githubusercontent.com/berachain/beacon-kit/main/testing/networks/$CHAINID/cl-seeds.txt"

env

if /0g/bin/0gchaind init ${MONIKER} --home $HOME_DIR; then
    cp -r /0g/0g-home/0gchain-home/config/* $CONFIG_DIR
else
    echo "Already initialized, continuing!" >&2
fi

exec /0g/bin/0gchaind $@
