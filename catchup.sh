#!/bin/bash

s_to_human_readable() {
    local ms=$1
    local days=$((ms / 86400))
    ms=$((ms % 86400))
    local hours=$((ms / 3600))
    ms=$((ms % 3600))
    local minutes=$((ms / 60))
    ms=$((ms % 60))
    local seconds=$((ms % 60))
    
    printf "%d days, %02d hours, %02d minutes, %02d seconds\n" $days $hours $minutes $seconds
}

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

seconds_to_measure=10

latest_block_timestamp_decimal=$(./timestamp.sh $1)
current_time=$(date +%s)
time_difference=$((current_time - latest_block_timestamp_decimal))	       

#echo "$latest_block_timestamp_decimal $current_time $time_difference"

#s_to_human_readable $time_difference
sleep 10

latest_block_timestamp_decimal=$(./timestamp.sh $1)
current_time=$(date +%s)
time_difference2=$((current_time - latest_block_timestamp_decimal))	       

#echo "$latest_block_timestamp_decimal $current_time $time_difference2"

#s_to_human_readable $time_difference2
progress=$((time_difference - time_difference2))
progress_per_second=$((progress / seconds_to_measure))
#echo "$progress_per_second"
#s_to_human_readable $progress_per_second

result=$(echo "scale=0; $time_difference2 / $progress_per_second" | bc)
#echo "$result"
s_to_human_readable $result
