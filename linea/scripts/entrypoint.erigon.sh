#!/bin/sh

# exit script on any error
set -e

ERIGON_HOME=/root/.local/share/erigon

# only needed once but doesn't hurt every time we start the container
echo "write the custom genesis block"
mkdir -p ${ERIGON_HOME:-/root/.local/share/erigon}
erigon init --datadir ${ERIGON_HOME:-/root/.local/share/erigon} /configs/mainnet/shared/genesis.json

exec erigon $@
