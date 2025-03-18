
#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

IFS=':' read -ra parts <<< $COMPOSE_FILE

blacklist=("drpc.yml" "drpc-free.yml" "base.yml" "rpc.yml" "monitoring.yml" "ftp.yml" "backup-http.yml")

# Flag to track if any invocation failed
any_failure=false

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
        result=$($BASEPATH/sync-status.sh "${part%.yml}")

	if [[ "$result" == *"syncing"* && $? -eq 1 ]]; then
	    # Allow exit status 1 if result contains "syncing"
	    true
	elif [[ "$result" == *"lagging"* && $? -eq 1 ]]; then
	    # Allow exit status 1 if result contains "syncing"
	    true
	elif [ $? -ne 0 ]; then
	    any_failure=true
	fi

        
        echo "${part%.yml}: $result"
    fi
done

# If any invocation failed, return a failure exit code
if $any_failure; then
    exit 1
fi
