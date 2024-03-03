#!/bin/sh

# exit script on any error
set -e

GETH_HOME=/root/.ethereum

if [ ! -f "${GETH_HOME}/bootstrapped.new" ];
then
  echo "write the custom genesis block"
  mkdir -p ${GETH_HOME:-/root/.ethereum}
  geth --datadir ${GETH_HOME:-/root/.ethereum} init /configs/mainnet/shared/genesis.new.json
fi

exec geth $@
