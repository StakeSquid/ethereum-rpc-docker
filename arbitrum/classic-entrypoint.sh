#!/bin/bash

#if [ -f /root/.arbitrum/mainnet/INITIALIZED ]; then
#    echo "datadir is already initialized"
#else
#    echo "lemme download the database quickly"
#    rm -rf /root/.arbitrum/mainnet/db
#    curl https://snapshot.arbitrum.io/arb1/classic-archive.tar | tar -xv -C /root/.arbitrum/mainnet/ && touch /root/.arbitrum/mainnet/INITIALIZED    
#fi

#echo "LFG!!!"

exec /home/user/go/bin/arb-node $@
