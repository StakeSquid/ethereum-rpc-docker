#!/bin/bash

curl --ipv4 -s $1 | grep -oP 'rpc_[^"]*\.tar\.zst' | sort -u
