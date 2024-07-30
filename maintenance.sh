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
	file="$BASEPATH/${part%.yml}.maintenance"
	if [ -f "$file" ]; then
	    echo "File $file exists. Executing it as a Bash script."
	    # Execute the file as a Bash script
	    bash "$file"
	else
	    echo "File $file does not exist or is not a regular file."
	fi
    fi
done

	
	
	
