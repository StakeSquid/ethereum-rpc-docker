#!/bin/bash

docker run --rm --network rpc_chains busybox ping -c 4 $1
