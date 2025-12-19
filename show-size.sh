#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

IFS=':' read -ra parts <<< $COMPOSE_FILE

blacklist=("drpc.yml" "drpc-free.yml" "base.yml" "rpc.yml" "monitoring.yml" "ftp.yml" "backup-http.yml")

total_size=0
static_size=0

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
        if [[ " ${params[@]} " =~ " ${part%.yml} " ]]; then
            include=$include # don't change anything
        else
            include=false
        fi
    fi

    if $include; then
        echo "Checking ${part%.yml}..." >&2
        # Capture stdout (ratio) while letting stderr display naturally
	static_ratio="$($BASEPATH/show-static-file-size.sh ${part%.yml})"
        static_ratio="0$static_ratio"
        total_kb=$($BASEPATH/show-file-size.sh ${part%.yml})

	total_size=$((total_size + total_kb))

        #output=$(echo "$((total_kb * 1024))" | numfmt --to=iec --suffix=B --format="%.2f")
        #echo "$output"
        static_part=$(echo "$total_kb * $static_ratio" | bc)

	static_size=$(echo "$static_size + $static_part" | bc)
        #output=$(echo "$static_size" | numfmt --to=iec --suffix=B --format="%.2f")
        #echo "$output"
        echo "" >&2
    fi
done

total=$(echo "$(( total_size * 1024 ))" | numfmt --to=iec --suffix=B --format="%.2f")
static=$(echo $(echo "$static_size * 1024" | bc) | numfmt --to=iec --suffix=B --format="%.2f")
dynamic_kb=$(echo "$total_size - $static_size" | bc)
dynamic=$(echo $(echo "$dynamic_kb * 1024" | bc) | numfmt --to=iec --suffix=B --format="%.2f")

echo "Total static: $static"
echo "Total: $total"
echo "Dynamic: $dynamic"
