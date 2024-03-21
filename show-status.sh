#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

IFS=':' read -ra parts <<< $COMPOSE_FILE

blacklist=("drpc.yml" "drpc-free.yml" "base.yml" "rpc.yml" "monitoring.yml")

for part in "${parts[@]}"; do
    include=true
    for word in "${blacklist[@]}"; do
	if echo "$part" | grep -qE "$word"; then
	    #echo "The path $path contains a blacklisted word: $word"
	    include=false
	fi
    done
    
    if $include; then
	result=$($BASEPATH/sync-status.sh "${part%.yml}")
	echo "${part%.yml}: $result"
    fi
done

	
	
	
