#!/bin/bash

date
vols_free=$(df -h /var/lib/docker/volumes | awk 'NR==2 {print $4}')
root_free=$(df -h / | awk 'NR==2 {print $4}')
if [[ "$vols_free" == "$root_free" ]]; then
    echo "Free space in /var/lib/docker/volumes: $vols_free"
else
    echo "Free space in /var/lib/docker/volumes: $vols_free (note: root / free is $root_free)"
fi

find /var/lib/docker/volumes -maxdepth 1 -type d -name 'rpc_*' -exec du -shL {} \; | sort -rh | awk '{cmd="basename "$2; cmd | getline dir; close(cmd); sub(/^rpc_/, "", dir); print $1, dir}'
