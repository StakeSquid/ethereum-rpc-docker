#!/bin/bash
        
if [ ! -d "/data/config" ]; then
    exchaind init fullnode --chain-id exchain-66
    wget https://raw.githubusercontent.com/okex/mainnet/main/genesis.json -O /data/config/genesis.json
fi      
        
exchaind start \
	 --chain-id exchain-66 \
	 --db_dir /data \
	 --rest.laddr tcp://0.0.0.0:8545 \
	 --db_backend rocksdb

