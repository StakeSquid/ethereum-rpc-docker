#!/bin/sh
set -eou

if [ "$NETWORK_NAME" == "testnet" ]; then
  export NETWORK=opBNBTestnet
fi

if [ "$NETWORK_NAME" == "mainnet" ]; then
  export NETWORK=opBNBMainnet
fi

# Start op-geth.
exec geth \
  --datadir="$BEDROCK_DATADIR" \
  --$NETWORK \
  --verbosity=3 \
  --http \
  --http.corsdomain="*" \
  --http.vhosts="*" \
  --http.addr=0.0.0.0 \
  --http.port=8545 \
  --http.api=net,eth,engine \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=8545 \
  --ws.origins="*" \
  --ws.api=eth,engine \
  --port=${P2P_PORT:-21546} \
  --nat=extip:${IP} \
  --maxpeers=10 \
  --syncmode=${OP_GETH_SYNCMODE:-full} \
  --gcmode=${OP_GETH_GCMODE:-archive} \
  --db.engine=${OP_GETH_DB_ENGINE:-leveldb} \
  --state.scheme=${OP_GETH_STATE_SCHEME:-hash} \
  --miner.gaslimit=150000000 \
  --txpool.globalslots=10000 \
  --txpool.globalqueue=5000 \
  --cache 6000 \
  --cache.preimages \
  --allow-insecure-unlock \
  --authrpc.addr="0.0.0.0" \
  --authrpc.port="8551" \
  --authrpc.vhosts="*" \
  --authrpc.jwtsecret=/jwtsecret \
  --metrics \
  --metrics.port 6060 \
  --metrics.addr 0.0.0.0

