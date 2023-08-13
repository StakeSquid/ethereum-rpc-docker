#!/bin/sh

# exit script on any error
set -e

ERIGON_HOME=/root/.local/share/erigon

if [ ! -f "${ERIGON_HOME}/bootstrapped" ];
then
  echo "write the custom genesis block"
  mkdir -p ${ERIGON_HOME:-/root/.local/share/erigon}
  erigon init --datadir ${ERIGON_HOME:-/root/.local/share/erigon} /configs/mainnet/shared/genesis_42.json
fi

exec erigon $@
