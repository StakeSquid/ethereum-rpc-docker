#!/bin/sh

set -eou pipefail

exec taiko-client driver \
     --l1.ws "${L1_ENDPOINT_WS}" \
     --l2.ws ws://taiko:8545 \
     --l1.beacon "${L1_BEACON_HTTP}" \
     --l2.auth http://taiko:8551 \
     --taikoL1 "${TAIKO_L1_ADDRESS}" \
     --taikoL2 "${TAIKO_L2_ADDRESS}" \
     --jwtSecret /data/taiko-geth/geth/jwtsecret \
     --p2p.sync \
     --p2p.checkPointSyncUrl "${L2_CHECKPOINT_SYNC_RPC:-https://rpc.mainnet.taiko.xyz}"


