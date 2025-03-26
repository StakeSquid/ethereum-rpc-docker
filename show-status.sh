#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

IFS=':' read -ra parts <<< $COMPOSE_FILE

blacklist=(
    "drpc.yml" "drpc-free.yml" "drpc-home.yml" # dshackles
    "arbitrum-one-mainnet-arbnode-archive-trace.yml" # always behind and no reference rpc
    "ethereum-beacon-mainnet-lighthouse-pruned-blobs" # can't handle beacon rest api yet
    "rpc.yml" "monitoring.yml" "ftp.yml" "backup-http.yml" "base.yml" # no rpcs
)

# Flag to track if any invocation failed for the alert scripts

any_failure=false

# Function to run the command and handle the result
check_sync_status() {
    local part=$1
    result=$("$BASEPATH/sync-status.sh" "${part%.yml}")

    code=0
    
    if [ $? -ne 0 ]; then
        if [[ "$result" == *"syncing"* ]]; then
            # Allow exit status 1 if result contains "syncing"
            code=0
        elif [[ "$result" == *"lagging"* ]]; then
            # Allow exit status 1 if result contains "lagging"
            code=0
        else
            any_failure=true
            code=1
        fi
    else
	code=1
	any_failure=true
    fi

    echo "${part%.yml}: $result"
    return "$code"
}



for part in "${parts[@]}"; do
    include=true
    for word in "${blacklist[@]}"; do
        if echo "$part" | grep -qE "$word"; then
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
	check_sync_status "$part" &
        pids+=($!)  # Save the process ID for waiting later
    fi
done

# Wait for all background processes to finish
for pid in "${pids[@]}"; do
    wait "$pid"
done

# If any invocation failed, return a failure exit code
if $any_failure; then
    exit 1
fi
