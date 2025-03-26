#!/bin/bash

datadir=/var/sonic

if [ ! -f "$datadir/initialized" ]; then
    echo "Initializing Sonic..."

    url="${GENESIS:-https://download.fantom.network/opera/mainnet/mainnet-5577-archive.g}"
    filename=$(basename "$url")
    
    wget -P "$datadir" "$url"

    GOMEMLIMIT="${CACHE_GB}GiB" sonictool --datadir "$datadir" --cache "${CACHE_GB}000" genesis "$datadir/$filename"
    rm "$datadir/$filename"
    
    touch "$datadir/initialized"

    echo "Initialization complete."
else
    echo "Sonic is already initialized."
fi

echo "Generating new Geth node key..."
openssl rand 32 | xxd -p -c 32 | tr -d '\n' > "$datadir/nodekey"

exec sonicd --nodekey "$datadir/nodekey" --cache "${CACHE_GB}000" --datadir "$datadir" "$@"
