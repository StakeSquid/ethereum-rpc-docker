#!/bin/bash

datadir=${SONIC_HOME:-/var/sonic}
crash_loop_file="$datadir/.crash_loop_timestamps"
crash_loop_threshold=3  # Number of restarts to consider it a crash loop
crash_loop_window=60    # Time window in seconds

# Function to detect crash loop
detect_crash_loop() {
    local current_time=$(date +%s)
    
    # Read existing timestamps and filter out old ones (outside the window)
    if [ -f "$crash_loop_file" ]; then
        local recent_restarts=0
        while IFS= read -r timestamp; do
            local age=$((current_time - timestamp))
            if [ $age -lt $crash_loop_window ]; then
                recent_restarts=$((recent_restarts + 1))
            fi
        done < "$crash_loop_file"
        
        # If we have enough recent restarts, it's a crash loop
        if [ $recent_restarts -ge $((crash_loop_threshold - 1)) ]; then
            return 0  # Crash loop detected
        fi
    fi
    
    return 1  # No crash loop
}

# Function to record restart timestamp
record_restart() {
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - crash_loop_window))
    
    # Filter out old timestamps and check if any recent ones exist
    local temp_file=$(mktemp)
    local has_recent=false
    
    if [ -f "$crash_loop_file" ]; then
        while IFS= read -r timestamp; do
            if [ "$timestamp" -gt "$cutoff_time" ]; then
                echo "$timestamp" >> "$temp_file"
                has_recent=true
            fi
        done < "$crash_loop_file" 2>/dev/null || true
    fi
    
    # If no recent timestamps, previous run was successful - start fresh
    # Otherwise, keep the recent timestamps and add the new one
    if [ "$has_recent" = false ]; then
        echo "$current_time" > "$temp_file"
    else
        echo "$current_time" >> "$temp_file"
    fi
    
    mv "$temp_file" "$crash_loop_file" 2>/dev/null || true
}

# Function to clear crash loop tracking (called on successful startup)
clear_crash_loop_tracking() {
    rm -f "$crash_loop_file"
}

if [ ! -f "$datadir/initialized" ]; then
    echo "Initializing Sonic..."

    url="${GENESIS:-https://genesis.soniclabs.com/sonic-mainnet/genesis/sonic.g}"
    filename=$(basename "$url")
    
    wget -P "$datadir" "$url"

    GOMEMLIMIT="${CACHE_GB}GiB" sonictool --datadir "$datadir" --cache "${CACHE_GB}000" genesis "$datadir/$filename"
    rm "$datadir/$filename"
    
    touch "$datadir/initialized"
    clear_crash_loop_tracking

    echo "Initialization complete."
else
    echo "Sonic is already initialized."
    
    # Record this restart attempt
    record_restart
    
    # Check if we're in a crash loop
    if detect_crash_loop; then
        echo "Crash loop detected. Running database heal..."
        # Use exec so it runs as PID 0 and can be interrupted by docker
        # After heal completes, we'll continue to start sonicd
        GOMEMLIMIT="${CACHE_GB}GiB" sonictool --datadir "$datadir" --cache "${CACHE_GB}000" heal
        echo "Heal completed. Starting sonicd..."
    else
        echo "No crash loop detected. Skipping heal."
    fi
fi

#echo "Generating new Geth node key..."
#openssl rand 32 | xxd -p -c 32 | tr -d '\n' > "$datadir/nodekey"

#exec sonicd --nodekey "$datadir/nodekey" --cache "${CACHE_GB}000" --datadir "$datadir" "$@"
exec sonicd --cache "${CACHE_GB}000" --datadir "$datadir" "$@"
