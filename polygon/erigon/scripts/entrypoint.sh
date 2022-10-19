#!/bin/sh

# exit script on any error
set -e

# Set Bor Home Directory
ERIGON_HOME=/datadir


if [ "${BOOTSTRAP}" == 1 ] && [ -n "${SNAPSHOT_URL}" ] && [ ! -f "${ERIGON_HOME}/bootstrapped" ];
then
  echo "downloading snapshot from ${SNAPSHOT_URL}"
  mkdir -p ${ERIGON_HOME}/bor/chaindata
  wget --tries=0 -O - "${SNAPSHOT_URL}" | tar -xz -C ${ERIGON_HOME}/bor/chaindata && touch ${ERIGON_HOME}/bootstrapped
fi

READY=$(curl -s http://heimdalld:26657/status | jq '.result.sync_info.catching_up')
while [[ "${READY}" != "false" ]];
do
    echo "Waiting for heimdalld to catch up."
    sleep 30
    READY=$(curl -s heimdalld:26657/status | jq '.result.sync_info.catching_up')
done

# add snap.keepblocks=true as mentioned on https://snapshot.polygon.technology/

exec erigon \
      --chain=bor-mainnet \
      --bor.heimdall=http://heimdallr:1317 \
      --datadir=${ERIGON_HOME} \
      --http --http.addr="0.0.0.0" --http.port="8545" --http.compression --http.vhosts="*" --http.corsdomain="*" --http.api="eth,debug,net,trace,web3,erigon,bor" \
      --ws --ws.compression \
      --snap.keepblocks=true \
      --snapshots="true" \
      --metrics --metrics.addr=0.0.0.0 --metrics.port=6060 \
      --pprof --pprof.addr=0.0.0.0 --pprof.port=6061