#!/bin/bash
        
if [ ! -d "/data/config" ]; then
    exchaind init fullnode --chain-id exchain-66
    wget https://raw.githubusercontent.com/okex/mainnet/main/genesis.json -O /data/config/genesis.json
fi      
        
exchaind start \
	 --chain-id exchain-66 \
	 --home /datadir \
	 --rest.laddr tcp://0.0.0.0:8545 \
	 --p2p.laddr=tcp://0.0.0.0:35885 \
	 --db_backend rocksdb

