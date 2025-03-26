#!/bin/sh

# exit script on any error
set -e

datadir=/datadir
FANTOM_HOME="$datadir"

url="${GENESIS:-https://download.fantom.network/opera/mainnet/mainnet-5577-full-mpt.g}"
filename=$(basename "$url")

if [ ! -f "$datadir/bootstrapped" ]; then
    echo "Initializing Opera..."

    if [ ! -f "$datadir/$filename" ]; then
        wget -P "$datadir" "$url"
    fi
    
    touch "$datadir/bootstrapped"

    echo "Initialization complete."
else
    echo "Opera is already initialized."
fi

# uncomment the next line and do docker-compose build in case you have to try to fix the db after unclean shutdown etc.
# opera --db.preset pbl-1 --datadir=$datadir db heal --experimental

# always make a new nodekey

echo "Generating new Geth node key..."
openssl rand 32 | xxd -p -c 32 | tr -d '\n' > "$datadir/nodekey"

exec opera --nodekey="$datadir/nodekey" --genesis="$datadir/$filename" --datadir="$datadir" "$@"
