#!/bin/sh
set -eoux

echo $OPTIMISM_L1_URL
echo $OP_NODE__RPC_TYPE

# Start op-node.
exec op-node \
  --l1=$OPTIMISM_L1_URL \
  --l2=http://op-erigon:8551 \
  --rollup.config=/scripts/mainnet.json \
  --rpc.addr=0.0.0.0 \
  --rpc.port=9545 \
  --l2.jwt-secret=/jwtsecret \
  --l1.trustrpc \
  --l1.rpckind=$OP_NODE__RPC_TYPE \
  --metrics.enabled \
  --metrics.addr=0.0.0.0 \
  --metrics.port=7300 \
  $@
