#!/bin/bash

# Run checkpoint sync script if provided
[[ -n $CHECKPOINT_SYNC_URL ]] &&
    /home/user/nimbus_beacon_node trustedNodeSync \
        --network=gnosis \
        --trusted-node-url=${CHECKPOINT_SYNC_URL} \
        --backfill=false \
        --data-dir=/data


exec -c /home/user/nimbus_beacon_node $@
