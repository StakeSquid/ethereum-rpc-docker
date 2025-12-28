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

        if [ -z "$(ls -A "$GETH_DATA_DIR")" ]; then
            if [ -f /0g/genesis.json ]; then
                /0g/bin/geth init --datadir $GETH_DATA_DIR /0g/genesis.json
            elif [ -f /0g/eth-genesis.json ]; then
                /0g/bin/geth init --datadir $GETH_DATA_DIR /0g/eth-genesis.json
            else
                echo "No genesis file found at /0g/genesis.json or /0g/eth-genesis.json" >&2
                exit 1
            fi
        else
            echo "Datadir not empty, continuing!" >&2
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

mkdir -p $CONFIG_DIR
mkdir -p $DATA_DIR

if [ "$CHAIN_NAME" = "galileo" ]; then
    CHAIN_SPEC=devnet
else
    CHAIN_SPEC=mainnet
fi
env

# seems to be the same for all the 0g chains

if [ ! -f "$DATA_DIR/priv_validator_state.json" ]; then
    echo "priv_validator_state.json not found in $HOME_DIR. Proceeding with initialization steps..."
    TMP_DIR=$(mktemp -d)
    # You can add any additional initialization logic here if needed
    if /0g/bin/0gchaind init ${MONIKER} --chaincfg.chain-spec ${CHAIN_SPEC} --home $TMP_DIR; then
        cp -r /0g/0g-home/0gchaind-home/config/* $CONFIG_DIR
        cp $TMP_DIR/data/priv_validator_state.json $DATA_DIR
        cp $TMP_DIR/config/node_key.json $CONFIG_DIR
        cp $TMP_DIR/config/priv_validator_key.json $CONFIG_DIR
    else
        echo "Already initialized, continuing!" >&2
    fi
    rm -rf $TMP_DIR # delete tmp dir

else
    echo "priv_validator_state.json found in $HOME_DIR. Continuing!" >&2
    echo "Already initialized, continuing!" >&2
fi

exec /0g/bin/0gchaind $@
