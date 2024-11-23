#!/bin/sh
if [ ! -d "/root/.ethereum/geth/chaindata" ]; then
    geth init /genesis/geth.json
else
    echo "Chain already initialized."
fi

geth --goat=testnet3
