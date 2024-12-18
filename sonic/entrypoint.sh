#!/bin/bash

if [ ! -f /var/sonic/initialized ]; then
    echo "Initializing Sonic..."

    # Add your initialization commands here
    # Example:
    # mkdir -p /var/sonic/data
    # touch /var/sonic/config.json

    wget https://genesis.soniclabs.com/sonic-mainnet/genesis/sonic.g
    GOMEMLIMIT=50GiB sonictool --datadir /var/sonic --cache 12000 genesis sonic.g
    rm sonic.g
    
    # Create the file to mark initialization
    touch /var/sonic/initialized

    echo "Initialization complete."
else
    echo "Sonic is already initialized."
fi

touch /var/sonic/initialized

exec sonicd --datadir /var/sonic "$@"
