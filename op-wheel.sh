#!/bin/bash

# USAGE:
# ./op-wheel.sh engine set-forkchoice --unsafe=0x111AC7F --safe=0x111AC7F --finalized=0x111AC7F --engine=http://op-lisk-sepolia:8551/ --engine.open=http://op-lisk-sepolia:8545 --engine.jwt-secret-path=/jwtsecret

docker run -it --rm --network rpc_chains -v /root/rpc/.jwtsecret:/jwtsecret golang:latest bash -c 'git clone https://github.com/ethereum-optimism/optimism.git && cd optimism && go run ./op-wheel/cmd "$@"' -- "$@"

