#!/bin/sh

# exit script on any error
set -e

# Set fantom Home Directory
FANTOM_HOME=/datadir

if [ ! -f "$FANTOM_HOME/testnet-16200-pruned-mpt.g" ];
then
    cd $FANTOM_HOME
    echo "downloading launch genesis file"
    wget --quiet https://files.fantom.network/testnet-16200-pruned-mpt.g
fi

# uncomment the next line and do docker-compose build in case you have to try to fix the db after unclean shutdown etc.
# opera --db.preset pbl-1 --datadir=$FANTOM_HOME db heal --experimental

exec opera \
    --genesis=$FANTOM_HOME/testnet-16200-pruned-mpt.g \
    --port=44629 \
    --maxpeers=200 \
    --datadir=$FANTOM_HOME \
    --http \
    --http.addr=0.0.0.0 \
    --http.port=18544 \
    --http.api=ftm,eth,debug,admin,web3,personal,net,txpool \
    --http.corsdomain="*" \
    --http.vhosts="*" \
    --ws \
    --ws.addr=0.0.0.0 \
    --ws.port=18544 \
    --ws.api=ftm,eth,debug,admin,web3,personal,net,txpool \
    --ws.origins="*" \
    --nat=extip:${IP} \
    --nousb \
    --db.migration.mode reformat \
    --db.preset pbl-1 \
    --cache=${CACHE_SIZE:-16000} \
    --syncmode=snap
