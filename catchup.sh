#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Enable debugging if needed
# set -x

# Check if timestamp.sh exists and is executable
if [ ! -x "$(dirname "$0")/timestamp.sh" ]; then
    echo -e "${RED}Error: timestamp.sh script not found or not executable${NC}"
    echo "Looking in: $(dirname "$0")"
    ls -la "$(dirname "$0")" | grep timestamp.sh
    exit 1
fi

s_to_human_readable() {
    local seconds=$1
    local days=$((seconds / 86400))
    seconds=$((seconds % 86400))
    local hours=$((seconds / 3600))
    seconds=$((seconds % 3600))
    local minutes=$((seconds / 60))
    seconds=$((seconds % 60))
    
    printf "%d days, %02d hours, %02d minutes, %02d seconds\n" $days $hours $minutes $seconds
}

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env 2>/dev/null || true

seconds_to_measure=${2:-10}

# First measurement
echo "Checking sync status for $1..."
echo "Debug: Running ./timestamp.sh $1"
timestamp_output=$(./timestamp.sh $1 2>&1)
timestamp_exit_code=$?

echo "Debug: timestamp.sh output: '$timestamp_output'"
echo "Debug: timestamp.sh exit code: $timestamp_exit_code"

# Try to extract a number, ignoring any errors or other text
latest_block_timestamp_decimal=$(echo "$timestamp_output" | grep -o '[0-9]\+' | head -1)

if [[ $timestamp_exit_code -ne 0 || -z "$latest_block_timestamp_decimal" ]]; then
    echo -e "${RED}Error: Failed to get valid block timestamp. Is the node running?${NC}"
    echo -e "${RED}timestamp.sh returned: $timestamp_output${NC}"
    exit 1
fi

current_time=$(date +%s)
time_difference=$((current_time - latest_block_timestamp_decimal))

# Check for reasonable time difference 
echo "Current chain head is $time_difference seconds behind real time"
s_to_human_readable $time_difference

# Wait to measure progress
echo "Measuring progress over $seconds_to_measure seconds..."
sleep $seconds_to_measure

# Second measurement
echo "Debug: Running ./timestamp.sh $1 (second measurement)"
timestamp_output=$(./timestamp.sh $1 2>&1)
timestamp_exit_code=$?

echo "Debug: timestamp.sh output (second): '$timestamp_output'"
echo "Debug: timestamp.sh exit code (second): $timestamp_exit_code"

# Try to extract a number, ignoring any errors or other text
latest_block_timestamp2=$(echo "$timestamp_output" | grep -o '[0-9]\+' | head -1)

if [[ $timestamp_exit_code -ne 0 || -z "$latest_block_timestamp2" ]]; then
    echo -e "${RED}Error: Failed to get valid block timestamp on second measurement${NC}"
    echo -e "${RED}timestamp.sh returned: $timestamp_output${NC}"
    exit 1
fi

current_time2=$(date +%s)
time_difference2=$((current_time2 - latest_block_timestamp2))

# Calculate the gap change
# Positive = gap increased (falling behind)
# Negative = gap decreased (catching up)
gap_change=$((time_difference2 - time_difference))

# Calculate catch-up rate (how many seconds of blockchain time processed in 1 second real time)
effective_catchup_seconds=$((seconds_to_measure - gap_change))
catchup_rate=$(echo "scale=3; $effective_catchup_seconds / $seconds_to_measure" | bc)

# Display debug info
echo "First measurement: Time behind = $time_difference seconds"
echo "Second measurement: Time behind = $time_difference2 seconds"
echo "Gap change in $seconds_to_measure seconds: $gap_change seconds"
echo "Calculated catchup rate: $catchup_rate× realtime"

# Interpret results
if (( $(echo "$catchup_rate < 0" | bc -l) )); then
    # Node is falling behind
    falling_behind_rate=$(echo "scale=2; -1 * $catchup_rate" | bc)
    echo -e "${RED}Node is FALLING BEHIND by $falling_behind_rate× realtime${NC}"
    echo -e "${RED}The gap increased by $gap_change seconds over $seconds_to_measure seconds${NC}"
    exit 1
elif (( $(echo "$catchup_rate < 1" | bc -l) )); then
    # Node is processing slower than realtime
    echo -e "${YELLOW}WARNING: Node is processing at $catchup_rate× realtime${NC}"
    echo -e "${YELLOW}This is too slow - node will never catch up to chain head${NC}"
    exit 2
else
    # Node is catching up
    echo -e "${GREEN}Node is processing at $catchup_rate× realtime${NC}"
    # Calculate time until caught up
    time_to_catchup=$(echo "scale=0; $time_difference2 / ($catchup_rate - 1)" | bc)
    echo -e "${GREEN}Estimated time until synced:${NC}"
    s_to_human_readable $time_to_catchup
    exit 0
fi
