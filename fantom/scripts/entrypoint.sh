#!/bin/sh

# exit script on any error
set -e

# Set fantom Home Directory
FANTOM_HOME=/datadir

if [ -n "${SNAPSHOT_URL}" ] && [ ! -f "${FANTOM_HOME}/bootstrapped" ];
then
  echo "downloading snapshot from ${SNAPSHOT_URL}"
  wget --tries=0 -O - "${SNAPSHOT_URL}" | tar -xz --strip-components=1 -C ${FANTOM_HOME}/ && touch ${FANTOM_HOME}/bootstrapped
fi

if [ ! -f "$FANTOM_HOME/mainnet-5577-full-mpt.g" ];
then
    cd $FANTOM_HOME
    echo "downloading launch genesis file"
    wget --quiet https://download.fantom.network/mainnet-5577-full-mpt.g
fi

opera \
    --genesis=$FANTOM_HOME/mainnet-5577-full-mpt.g \
    --port=5050 \
    --maxpeers=200 \
    --datadir=$FANTOM_HOME \
    --http \
    --http.addr=0.0.0.0 \
    --http.port=18545 \
    --http.api=ftm,eth,debug,admin,web3,personal,net,txpool,sfc,trace \
    --http.corsdomain="*" \
    --http.vhosts="*" \
    --ws \
    --ws.addr=0.0.0.0 \
    --ws.port=18545 \
    --ws.api=ftm,eth,debug,admin,web3,personal,net,txpool,sfc \
    --ws.origins="*" \
    --nousb \
    --db.migration.mode reformat \
    --db.preset pbl-1 \
    --cache=${CACHE_SIZE:-16000} \
    --tracenode
