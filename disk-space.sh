#!/bin/bash

# Total disk space in bytes (replace /dev/sda1 with your actual disk)
total_blocks=$(df --output=size /var/lib/docker/volumes | awk 'NR==2')

# Convert total blocks to bytes
total_disk_space=$((total_blocks * 1024))

# Used disk space in bytes
reserved=${1:-50}
used_disk_space=$(( reserved * 1024 * 1024 * 1024 ))

# Calculate 10% of total disk space
ten_percent=$(( total_disk_space / 10 ))

# Calculate total available disk space
total_available_space=$(( total_disk_space - used_disk_space - ten_percent ))

#echo "$total_disk_space"
#echo "$used_disk_space"
#echo "$ten_percent"

# Convert total available space to human-readable format
#total_available_space_human=$(echo "$total_available_space" | awk '{ split( "B KB MB GB" , v ); s=1; while( $1>1024 ){ $1/=1024; s++ } print int($1) v[s] }')
#total_available_space_human=$(numfmt --to=iec-i --suffix=B "$total_available_space")

available_space_gb=$(echo "scale=0; $total_available_space / 1073741824" | bc)

echo "$available_space_gb"
