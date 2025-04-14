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

# Calculate how much the gap changed
gap_change=$((time_difference2 - time_difference))

# Calculate real catchup rate (accounting for the natural progression of time)
# The node caught up by (gap_change + seconds_to_measure) seconds in seconds_to_measure real time
effective_progress=$((seconds_to_measure - gap_change))
catchup_rate=$(echo "scale=4; $effective_progress / $seconds_to_measure" | bc)

# Display debug info if needed
# echo "Debug: time_difference=$time_difference, time_difference2=$time_difference2, gap_change=$gap_change"
# echo "Debug: effective_progress=$effective_progress, catchup_rate=$catchup_rate"

# Calculate time to catch up (only if actually catching up)
if (( $(echo "$catchup_rate <= 0" | bc -l) )); then
    echo -e "${RED}ERROR: Node is not catching up! It's falling behind by $(echo "scale=2; -1 * $catchup_rate" | bc) seconds per second.${NC}"
    exit 1
fi

# Time until caught up (if the rate continues)
time_to_catchup=$(echo "scale=0; $time_difference2 / $catchup_rate" | bc)

# Check if catchup rate is enough to eventually catch up
# The node needs to catch up faster than 1.0 to make progress
min_required_rate=1.0
required_rate_with_buffer=$(echo "scale=4; $min_required_rate + 0.01" | bc)  # Slight buffer

if (( $(echo "$catchup_rate < $required_rate_with_buffer" | bc -l) )); then
    echo -e "${YELLOW}WARNING: Node catchup rate ($catchup_rate times realtime) is too slow.${NC}"
    echo -e "${YELLOW}The node needs > 1.0 to catch up, but will likely never catch up to the chain head!${NC}"
else
    echo -e "${GREEN}Node catchup rate is good: $catchup_rate times realtime${NC}"
    echo -e "${GREEN}Estimated time to sync:${NC}"
    s_to_human_readable $time_to_catchup
fi
