#!/bin/bash

BASEPATH="$(dirname "$0")"
static_file_list="$BASEPATH/static-file-path-list.txt"

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

static_size=0
total_size=0

# Iterate over the list of keys
for key in $keys; do
    #echo "checking: /var/lib/docker/volumes/rpc_$key"

    prefix="/var/lib/docker/volumes/rpc_$key"

    volume_size=$(du -sL $prefix 2>/dev/null | awk '{print $1}')

    total_size=$((total_size + volume_size))

    # Only check static files if the list exists
    if [[ -f "$static_file_list" ]]; then
        while IFS= read -r path; do
            # Skip empty lines
            [[ -z "$path" ]] && continue
            
            # Check if the path exists
            if [[ -e "$prefix/_data/$path" ]]; then
                # Print the size of the file or directory
                size=$(du -sL "$prefix/_data/$path" 2>/dev/null | awk '{print $1}')
                static_size=$((static_size + size))
                # Format size in human-readable format
                size_formatted=$(echo "$(( size * 1024 ))" | numfmt --to=iec --suffix=B --format="%.2f")
                # Print the detected path with size to stderr (one per line)
                echo "$size_formatted  $prefix/_data/$path" >&2
            fi
        done < "$static_file_list"
    fi
done

# Calculate ratio, handling division by zero
if [[ $total_size -eq 0 ]]; then
    ratio="0.00"
else
    ratio=$(bc -l <<< "scale=2; $static_size/$total_size")
fi

echo "$ratio"
