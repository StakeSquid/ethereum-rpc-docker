#!/bin/bash

find /var/lib/docker/volumes/ -maxdepth 1 -type d -name 'rpc_*' -exec du -sh {} \; | sort -rh
