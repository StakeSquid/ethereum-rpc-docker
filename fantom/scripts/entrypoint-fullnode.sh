#!/bin/sh

# exit script on any error
set -e

# Set fantom Home Directory
FANTOM_HOME=/datadir

if [ ! -f "$FANTOM_HOME/mainnet-171200-no-history.g" ];
then
    cd $FANTOM_HOME
    echo "downloading launch genesis file"
    wget --quiet https://files.fantom.network/mainnet-171200-no-history.g
fi

# uncomment the next line and do docker-compose build in case you have to try to fix the db after unclean shutdown etc.
# opera --db.preset pbl-1 --datadir=$FANTOM_HOME db heal --experimental

# Generate nodekey only if it doesn't exist
if [ ! -f /config/nodekey ]; then
    echo "Generating new Geth node key..."
    openssl rand 32 | xxd -p -c 32 | tr -d '\n' > /config/nodekey
    echo "Node key generated: $(cat /config/nodekey)"
else
    echo "Node key already exists, skipping generation."
fi

exec opera \
    --genesis=$FANTOM_HOME/mainnet-171200-no-history.g \
    --port=19921 \
    --maxpeers=200 \
    --datadir=$FANTOM_HOME \
    --http \
    --http.addr=0.0.0.0 \
    --http.port=18544 \
    --http.api=ftm,eth,debug,admin,web3,personal,net,txpool,sfc,trace \
    --http.corsdomain="*" \
    --http.vhosts="*" \
    --nat extip:${IP} \
    --nodekey=/config/nodekey \
    --ws \
    --ws.addr=0.0.0.0 \
    --ws.port=18544 \
    --ws.api=ftm,eth,debug,admin,web3,personal,net,txpool,sfc,trace \
    --ws.origins="*" \
    --nousb \
    --rpc.gascap=600000000 \
    --db.migration.mode reformat \
    --tracenode \
    --db.preset pbl-1 \
    --cache=${CACHE_SIZE:-16000} \
    --syncmode=snap
