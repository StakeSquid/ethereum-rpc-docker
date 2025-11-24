#!/bin/bash

datadir=${SONIC_HOME:-/var/sonic}

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
    # just in case because after every shutdown this shit is corrupted by default
    # GOMEMLIMIT=28GiB exec sonictool --datadir "$datadir" --cache 12000 heal
fi

# after every restart I needed to do this manually so lets just do it automatically each time

GOMEMLIMIT="${CACHE_GB}GiB" sonictool --datadir "$datadir" --cache "${CACHE_GB}000" heal

#echo "Generating new Geth node key..."
#openssl rand 32 | xxd -p -c 32 | tr -d '\n' > "$datadir/nodekey"

#exec sonicd --nodekey "$datadir/nodekey" --cache "${CACHE_GB}000" --datadir "$datadir" "$@"
exec sonicd --cache "${CACHE_GB}000" --datadir "$datadir" "$@"
