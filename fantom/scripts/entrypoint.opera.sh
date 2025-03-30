#!/bin/sh

# exit script on any error
set -e

datadir=/datadir
FANTOM_HOME="$datadir"

if existing_file=$(ls "$datadir"/*.g 2>/dev/null | head -n1); then
    echo "Some genesis block seems to exist"
    filename=$(basename "$existing_file")
else
    url="${GENESIS:-https://download.fantom.network/opera/mainnet/mainnet-5577-full-mpt.g}"
    wget -P "$datadir" "$url"
    filename=$(basename "$url")
fi

# uncomment the next line and do docker-compose build in case you have to try to fix the db after unclean shutdown etc.
# opera --db.preset pbl-1 --datadir=$datadir db heal --experimental

# always make a new nodekey so backups can be shared

echo "Generating new Geth node key..."
rm -f "$datadir/nodekey"

exec opera --genesis="$datadir/$filename" --datadir="$datadir" "$@"
