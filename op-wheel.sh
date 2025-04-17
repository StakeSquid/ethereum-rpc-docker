#!/bin/bash

# USAGE:
#  docker stop rpc-celo-alfajores-node-1 && ./op-wheel.sh engine set-forkchoice --unsafe=43897488 --safe=43897488 --finalized=43897488 --engine=http://celo-alfajores:8551 --engine.jwt-secret-path=/jwtsecret --engine.open=http://celo-alfajores:8545

docker run -it --rm --network rpc_chains -v /root/rpc/.jwtsecret:/jwtsecret golang:latest bash -c 'git clone https://github.com/ethereum-optimism/optimism.git && cd optimism && go run ./op-wheel/cmd "$@"' -- "$@"

