#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

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

seconds_to_measure=${2:-10}
# Assume 1 block per 12 seconds as default chain block time
chain_block_time=${3:-12}

# First measurement
latest_block_timestamp_decimal=$(./timestamp.sh $1)
current_time=$(date +%s)
time_difference=$((current_time - latest_block_timestamp_decimal))	       

echo "Current chain head is $time_difference seconds behind real time"
# s_to_human_readable $time_difference

# Wait to measure progress
sleep $seconds_to_measure

# Second measurement
latest_block_timestamp_decimal=$(./timestamp.sh $1)
current_time=$(date +%s)
time_difference2=$((current_time - latest_block_timestamp_decimal))	       

# Calculate catchup rate
progress=$((time_difference - time_difference2))
progress_per_second=$(echo "scale=4; $progress / $seconds_to_measure" | bc)

# Calculate time to catch up
if (( $(echo "$progress_per_second <= 0" | bc -l) )); then
    echo -e "${RED}ERROR: Node is not catching up! It's falling behind by $(echo "scale=2; -1 * $progress_per_second" | bc) seconds per second.${NC}"
    exit 1
fi

# Time until caught up
time_to_catchup=$(echo "scale=0; $time_difference2 / $progress_per_second" | bc)

# Calculate if catchup rate is faster than chain growth rate
# Chain growth is typically 1 second of block time per second of real time
chain_growth_rate=1.0  # 1 second per second as baseline
catchup_needed=$(echo "scale=4; $chain_growth_rate + 0.01" | bc)  # Slight buffer for safety

if (( $(echo "$progress_per_second < $catchup_needed" | bc -l) )); then
    echo -e "${YELLOW}WARNING: Node catchup rate ($progress_per_second seconds/second) is slower than chain growth rate ($chain_growth_rate seconds/second).${NC}"
    echo -e "${YELLOW}The node will likely never catch up to the chain head!${NC}"
else
    echo -e "${GREEN}Node catchup rate is good: $progress_per_second seconds/second${NC}"
    echo -e "${GREEN}Estimated time to sync:${NC}"
    s_to_human_readable $time_to_catchup
fi
