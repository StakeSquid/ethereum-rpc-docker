FROM ghcr.io/gnosischain/gnosis-nimbus-eth2:latest                                                                                                                                                         

COPY entrypoint.sh /usr/bin/entrypoint.sh                                                                                                                                                                  

ENTRYPOINT ["/usr/bin/entrypoint.sh"]root@rpc-fi-1 ~/rpc # cat gnosis/nimbus/entrypoint.sh
#!/bin/bash

# Run checkpoint sync script if provided
[[ -n $CHECKPOINT_SYNC_URL ]] &&
    /home/user/nimbus_beacon_node trustedNodeSync \
        --network=gnosis \
        --trusted-node-url=${CHECKPOINT_SYNC_URL} \
        --backfill=false \
        --data-dir=/data


exec -c /home/user/nimbus_beacon_node $@
