#!/bin/bash

date
df -h / | awk 'NR==2 {print "Total: " $2, "Free: " $4}'

find /var/lib/docker/volumes -maxdepth 1 -type d -name 'rpc_*' -exec du -shL {} \; | sort -rh | awk '{cmd="basename "$2; cmd | getline dir; close(cmd); sub(/^rpc_/, "", dir); print $1, dir}'
