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
    wget --quiet https://download.fantom.network/opera/mainnet/mainnet-5577-full-mpt.g
fi

# uncomment the next line and do docker-compose build in case you have to try to fix the db after unclean shutdown etc.
# opera --db.preset pbl-1 --datadir=$FANTOM_HOME db heal --experimental

exec opera \
    --genesis=$FANTOM_HOME/mainnet-5577-full-mpt.g \
    --port=5050 \
    --maxpeers=200 \
    --datadir=$FANTOM_HOME \
    --http \
    --bootnodes=${BOOTNODES:-enode://94dfec3eb6e50187d22d12f7dd965169bab5a63022934ef0b3b82a819574e0940b5bcb471f62360f1b58cf61a89e634bd14ae7c2e29ce48088890f4a7aff44fe@75.98.207.227:5050,enode://7fb3f43273f4dfeb19c3129c6ed999e14246d2f219ff284d0ef87417cd9514c6d542abc988a654b4a77005ea896c5b4e4ca0d40f97f3bf9ee37be33cc749835f@209.172.40.68:5050,enode://27a80a1db08a40636415d4ff9bb272882b6a6f97a9a5d596006de843f35cbbc679e5252d89d3de05bd74c36cf9f5ce2446dd66cdd5dc7e942a585eb4add61124@37.27.70.18:5050,enode://946fef1538abd165f8bd2ae1c290e7689ff5e209ab6c085eaced9b91e93684b1efe05f79a9a9b460504c450065baaeda5ecb72c03f8adf7e7a559042ce4950da@136.243.252.124:5078,enode://cf762e3a68f8a96676d6383cd3286b85ef7454ef37bb39283efe00d3d573d88f05db3daab7c35a4d3ba9edd9d089e359a25de5beeb24f79f6c1b9e5341958cee@15.235.54.211:5050} \
    --http.addr=0.0.0.0 \
    --http.port=18544 \
    --http.api=ftm,eth,debug,admin,web3,personal,net,txpool,sfc,trace \
    --http.corsdomain="*" \
    --http.vhosts="*" \
    --ws \
    --ws.addr=0.0.0.0 \
    --ws.port=18544 \
    --ws.api=ftm,eth,debug,admin,web3,personal,net,txpool,sfc \
    --ws.origins="*" \
    --nousb \
    --db.migration.mode reformat \
    --db.preset pbl-1 \
    --cache=${CACHE_SIZE:-16000} \
    --tracenode
