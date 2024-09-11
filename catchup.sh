#!/bin/bash

ms_to_human_readable() {
    local ms=$1
    local days=$((ms / 86400000))
    ms=$((ms % 86400000))
    local hours=$((ms / 3600000))
    ms=$((ms % 3600000))
    local minutes=$((ms / 60000))
    ms=$((ms % 60000))
    local seconds=$((ms / 1000))
    local milliseconds=$((ms % 1000))
    
    printf "%d days, %02d hours, %02d minutes, %02d seconds, %03d milliseconds\n" $days $hours $minutes $seconds $milliseconds
}

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

latest_block_timestamp_decimal=$(./timestamp.sh $1)
current_time=$(date +%s)
time_difference=$((current_time - latest_block_timestamp_decimal))	       

ms_to_human_readable $time_difference
sleep 10

latest_block_timestamp_decimal=$(./timestamp.sh $1)
current_time=$(date +%s)
time_difference2=$((current_time - latest_block_timestamp_decimal))	       

progress=$(((time_difference2 - time_difference)/10))

echo "$progess ms/s"
