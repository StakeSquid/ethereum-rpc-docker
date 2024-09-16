#!/bin/bash


curl -s https://$1.stakesquid.eu/backup/ | grep -oP 'rpc_[^"]*\.tar\.zst' | sort -u
