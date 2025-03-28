#!/bin/bash

# Threshold for disk usage percentage
threshold=90

# Get the list of mounted filesystems and their usage, excluding pseudo, duplicate, inaccessible file systems, and tmpfs
filesystems=$(df -h -x tmpfs --output=target,pcent | tail -n +2)

# Iterate over each line of the output
while IFS= read -r line; do
    # Extract filesystem and usage percentage
    filesystem=$(echo "$line" | awk '{print $1}')
    usage=$(echo "$line" | awk '{print $NF}' | tr -d '%')

    # Exclude Docker container overlay filesystems
    if [[ "$filesystem" == *overlay* ]]; then
        continue
    fi
    
    # Check if usage is a number
    if [[ $usage =~ ^[0-9]+$ ]]; then
        # Check if usage is above the threshold
        if [ "$usage" -ge "$threshold" ]; then
            echo "WARNING: $filesystem is $usage% full!"
        fi
    else
        # Skip the line if usage information cannot be parsed
        continue
    fi
done <<< "$filesystems"
