#!/bin/bash

# Threshold for disk usage percentage
threshold=90

# Get the list of mounted filesystems and their usage
filesystems=$(df -h --output=target,pcent | tail -n +2)

# Iterate over each line of the output
while IFS= read -r line; do
    # Extract filesystem and usage percentage
    filesystem=$(echo "$line" | awk '{print $1}')
    usage=$(echo "$line" | awk -F'%' '{print $1}')

    # Check if usage is a number
    if [[ $usage =~ ^[0-9]+$ ]]; then
        # Check if usage is above the threshold
        if [ "$usage" -ge "$threshold" ]; then
            echo "WARNING: Filesystem $filesystem is $usage% full!"
        fi
    else
        echo "WARNING: Unable to parse usage for filesystem $filesystem."
    fi
done <<< "$filesystems"
