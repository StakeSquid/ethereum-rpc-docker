#!/bin/sh

# Custom initialization steps go here
echo "Starting initialization steps..."

# Check if the genesis.json file exists; if not, initialize and copy it
# if [ ! -f /goat/config/genesis.json ]; then
#     echo "Initializing goatd..."
#     exec goatd init --home /goat mainnet
#     echo "Copying genesis file..."
#     cp /genesis/goat.json /goat/config/genesis.json
# else
#     echo "Genesis file already exists; skipping initialization."
# fi

# Pass control to the final command specified in docker-compose.yml
exec goatd start --home /goat --chain-id=goat-mainnet --goat.geth /geth/geth.ipc --api.enable --api.address=tcp://0.0.0.0:1317 --p2p.external-address $IP:40258 --p2p.laddr 0.0.0.0:40258
