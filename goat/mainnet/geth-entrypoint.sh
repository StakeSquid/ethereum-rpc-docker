#!/bin/sh
# if [ ! -d "/root/.ethereum/geth/chaindata" ]; then
#     exec geth init /genesis/geth.json
# else
#     echo "Chain already initialized."
# fi

exec geth --goat=mainnet
