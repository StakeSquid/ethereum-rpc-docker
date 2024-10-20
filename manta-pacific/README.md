# Manta Pacific Replica
=============
To use: Set the variable `L1_RPC_URL` to your RPC url for Ethereum. Then run `make manta-up`. Syncing the replica from scratch might take up to several days.

A number of constants have already been set to align with the Manta Pacific mainnet:
- the sequencer http url, which allows for transactions sent to the replica node to be forwarded to the sequencer, effectively meaning you can use the replica node like a full rpc provider
- the p2p endpoint, which means that the replica can the latest blocks produced from a trusted source


Commands:
=========

    make manta-up

    make manta-down

    make manta-clean
