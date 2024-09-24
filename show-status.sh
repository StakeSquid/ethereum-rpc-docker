#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

IFS=':' read -ra parts <<< $COMPOSE_FILE

blacklist=("drpc.yml" "drpc-free.yml" "base.yml" "rpc.yml" "monitoring.yml" "ftp.yml" "backup-http.yml")

for part in "${parts[@]}"; do
    include=true
    for word in "${blacklist[@]}"; do
	if echo "$part" | grep -qE "$word"; then
	    #echo "The path $path contains a blacklisted word: $word"
	    include=false
	fi
    done

    # Check if any parameters were passed
    if [ $# -gt 0 ]; then
	# Put parameters into an array (list)
	params=("$@")

	# Check if a string is part of the list
	if [[ " ${params[@]} " =~ " $1 " ]]; then
	    include=$include # don't change anything 
	else
	    include=false
	fi
    fi	
    
    if $include; then
	result=$($BASEPATH/sync-status.sh "${part%.yml}")
	if [ "$1" = "${part%.yml}" ]; then
	    echo "${result}"
	    exit 0
	else
	    echo "${part%.yml}: $result"
	fi
    fi
done

	
	
	
