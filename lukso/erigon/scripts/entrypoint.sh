#!/bin/sh

# exit script on any error
set -e

ERIGON_HOME=/datadir

if [ "${BOOTSTRAP}" == 1 ] && [ -n "${SNAPSHOT_URL}" ] && [ ! -f "${ERIGON_HOME}/bootstrapped" ];
then
  echo "downloading snapshot from ${SNAPSHOT_URL}"
  mkdir -p ${ERIGON_HOME:-/datadir}
  erigon init --datadir $ERIGON_HOME /configs/mainnet/shared/genesis_42.json
fi

exec erigon $@
