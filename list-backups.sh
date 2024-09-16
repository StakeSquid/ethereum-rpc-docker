#!/bin/bash

curl -s $1 | grep -oP 'rpc_[^"]*\.tar\.zst' | sort -u
