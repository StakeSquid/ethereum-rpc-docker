#!/bin/bash

datadir=/var/sonic

if [ ! -f "$datadir/initialized" ]; then
    echo "Initializing Sonic..."

    url="${GENESIS:-https://genesis.soniclabs.com/sonic-mainnet/genesis/sonic.g}"
    filename=$(basename "$url")
    
    wget -P "$datadir" "$url"

    GOMEMLIMIT="${CACHE_GB}GiB" sonictool --datadir "$datadir" --cache "${CACHE_GB}000" genesis "$datadir/$filename"
    rm "$datadir/$filename"
    
    touch "$datadir/initialized"

    echo "Initialization complete."
else
    echo "Sonic is already initialized."
fi

exec sonicd --cache "${CACHE_GB}000" --datadir "$datadir" "$@"
