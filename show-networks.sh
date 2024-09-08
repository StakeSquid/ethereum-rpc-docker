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
    
    if $include; then
	default=$(jq -r "to_entries[] | select(.value.default[]? == \"${part%.yml}\") | .key" $BASEPATH/reference-rpc-endpoint.json)
	archive=$(jq -r "to_entries[] | select(.value.archive[]? == \"${part%.yml}\") | .key" $BASEPATH/reference-rpc-endpoint.json)
	
	if [ -n "$archive" ]; then
	    echo "${archive}_archive"
	elif [ -n "$default" ]; then
	    echo "${default}_default"
	else
	    exit 1
	fi
    fi
done

	
	
	
