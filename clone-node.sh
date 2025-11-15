#!/bin/bash

# Fixed version that handles missing netstat

if [[ -n $2 ]]; then
    DEST_HOST="$2.stakesquid.eu"
    echo "Setting up optimized transfer to $DEST_HOST"
else
    echo "Error: No destination provided"
    exit 1
fi

# Configuration
BASE_PORT=9000
PORT_RANGE_START=9000
PORT_RANGE_END=9100

# Global array to track used ports
declare -a USED_PORTS=()

# Setup SSH multiplexing
setup_ssh_multiplex() {
    echo "Setting up SSH control connection..."
    ssh -nNf -o ControlMaster=yes \
            -o StrictHostKeyChecking=no \
            -o ControlPath=/tmp/ssh-mux-%h-%p-%r \
            -o ControlPersist=600 \
            -o Compression=no \
            "$DEST_HOST" 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo "SSH control connection established"
        export SSH_CMD="ssh -o StrictHostKeyChecking=no -o ControlPath=/tmp/ssh-mux-%h-%p-%r"
    else
        echo "Failed to setup SSH multiplexing, using direct SSH"
        export SSH_CMD="ssh -o StrictHostKeyChecking=no"
    fi
}

# Check if port is listening using various methods
check_port_listening() {
    local port=$1
    
    # Try different methods to check if port is listening
    $SSH_CMD "$DEST_HOST" "
        if command -v ss >/dev/null 2>&1; then
            ss -tln | grep -q ':$port '
        elif command -v netstat >/dev/null 2>&1; then
            netstat -tln | grep -q ':$port '
        elif command -v lsof >/dev/null 2>&1; then
            lsof -i :$port >/dev/null 2>&1
        else
            # If no tools available, just try to connect to the port
            timeout 1 bash -c 'cat < /dev/null > /dev/tcp/localhost/$port' 2>/dev/null
        fi
    "
    return $?
}

# Find an available port in the range
find_available_port() {
    local port=$PORT_RANGE_START
    
    while [[ $port -le $PORT_RANGE_END ]]; do
        # Check if port is already used by this script
        local already_used=false
        for used_port in "${USED_PORTS[@]}"; do
            if [[ $port -eq $used_port ]]; then
                already_used=true
                break
            fi
        done
        
        # Check if port is listening on remote host
        if [[ "$already_used" == "false" ]] && ! check_port_listening $port; then
            # Add to used ports array
            USED_PORTS+=($port)
            echo $port
            return 0
        fi
        port=$((port + 1))
    done
    
    echo "Error: No available ports in range $PORT_RANGE_START-$PORT_RANGE_END" >&2
    return 1
}

# Remove port from used ports array
release_port() {
    local port=$1
    local new_array=()
    
    for used_port in "${USED_PORTS[@]}"; do
        if [[ $used_port -ne $port ]]; then
            new_array+=($used_port)
        fi
    done
    
    USED_PORTS=("${new_array[@]}")
}

# Cleanup all used ports on exit
cleanup_all_ports() {
    echo "Cleaning up all used ports..."
    for port in "${USED_PORTS[@]}"; do
        echo "Releasing port $port"
        $SSH_CMD "$DEST_HOST" "
            # Kill any processes on this port
            lsof -i :$port 2>/dev/null | grep LISTEN | awk '{print \$2}' | xargs -r kill 2>/dev/null
        " 2>/dev/null
    done
    USED_PORTS=()
}

# Transfer using screen method with better error handling
transfer_volume() {
    local key=$1
    local source_folder="/var/lib/docker/volumes/rpc_${key}/_data"
    
    if [[ ! -d "$source_folder" ]]; then
        echo "Warning: $source_folder does not exist, skipping"
        return 1
    fi
    
    local folder_size=$(du -sb "$source_folder" 2>/dev/null | awk '{print $1}')
    
    # Find an available port
    local port=$(find_available_port)
    if [[ $? -ne 0 ]]; then
        echo "Error: Could not find available port for $key"
        return 1
    fi
    
    echo "Transferring volume $key (size: $((folder_size / 1048576))MB) on port $port"
    
    # Clean up any existing transfer for this specific key only
    $SSH_CMD "$DEST_HOST" "
        # Kill any existing screen session for this specific transfer
        screen -S transfer_${key} -X quit 2>/dev/null
        # Clean up old files for this specific transfer
        rm -f /tmp/transfer_${key}.* 2>/dev/null
    "
    
    # Check if screen is available
    if $SSH_CMD "$DEST_HOST" "which screen" >/dev/null 2>&1; then
        echo "Starting screen listener on port $port..."
        
        # Start listener in screen session with proper escaping
        $SSH_CMD "$DEST_HOST" "
            screen -dmS transfer_${key} bash -c '
                nc -l -p $port | zstd -d | tar -xf - -C / 2>/tmp/transfer_${key}.err
                echo \$? > /tmp/transfer_${key}.done
            '
        "
        
        # Give it time to start
        sleep 2
        
        # Check if screen session is running
        if ! $SSH_CMD "$DEST_HOST" "screen -list | grep -q transfer_${key}"; then
            echo "Error: Screen session failed to start"
            return 1
        fi
        
    else
        echo "Screen not available, using nohup method..."
        
        # Use nohup with proper backgrounding
        $SSH_CMD "$DEST_HOST" "
            nohup bash -c '
                nc -l -p $port | zstd -d | tar -xf - -C / 2>/tmp/transfer_${key}.err
                echo \$? > /tmp/transfer_${key}.done
            ' > /tmp/transfer_${key}.log 2>&1 < /dev/null &
            echo \$! > /tmp/transfer_${key}.pid
        "
        
        sleep 2
        
        # Verify process is running
        if ! $SSH_CMD "$DEST_HOST" "[[ -f /tmp/transfer_${key}.pid ]] && kill -0 \$(cat /tmp/transfer_${key}.pid) 2>/dev/null"; then
            echo "Error: Listener process failed to start"
            return 1
        fi
    fi
    
    # Optional: Check if port is listening (may fail if tools aren't available)
    echo "Checking if port $port is ready..."
    if check_port_listening $port; then
        echo "Port $port is listening, starting transfer..."
    else
        echo "Cannot verify port status, proceeding with transfer anyway..."
    fi
    
    # Send the data
    echo "Sending data to ${DEST_HOST}:${port}..."
    tar -cf - --dereference "$source_folder" 2>/dev/null | \
        pv -pterb -s "$folder_size" -N "$key" | \
        zstd -3 -T0 | \
        nc -w 60 "$DEST_HOST" "$port"
    
    local transfer_status=$?
    
    if [[ $transfer_status -eq 0 ]]; then
        echo "Transfer complete, waiting for extraction to finish..."
        
        # Wait for done flag with timeout
        local attempts=0
        local max_attempts=60  # Wait up to 2 minutes
        
        while [[ $attempts -lt $max_attempts ]]; do
            if $SSH_CMD "$DEST_HOST" "[[ -f /tmp/transfer_${key}.done ]]" 2>/dev/null; then
                local remote_status=$($SSH_CMD "$DEST_HOST" "cat /tmp/transfer_${key}.done 2>/dev/null || echo 1")
                
                if [[ "$remote_status" == "0" ]]; then
                    echo "✓ Volume $key transferred and extracted successfully"
                    
                    # Cleanup - only for this specific transfer
                    $SSH_CMD "$DEST_HOST" "
                        rm -f /tmp/transfer_${key}.* 2>/dev/null
                        screen -S transfer_${key} -X quit 2>/dev/null
                        [[ -f /tmp/transfer_${key}.pid ]] && kill \$(cat /tmp/transfer_${key}.pid) 2>/dev/null
                    "
                    
                    # Release the port for reuse
                    release_port $port
                    return 0
                else
                    echo "✗ Extraction failed with status $remote_status"
                    echo "Error log:"
                    $SSH_CMD "$DEST_HOST" "cat /tmp/transfer_${key}.err 2>/dev/null || echo 'No error log'"
                    # Release the port even on failure
                    release_port $port
                    return 1
                fi
            fi
            
            # Show progress
            if [[ $((attempts % 5)) -eq 0 ]]; then
                echo "Still waiting for extraction to complete... ($attempts/$max_attempts)"
            fi
            
            sleep 2
            attempts=$((attempts + 1))
        done
        
        echo "⚠ Timeout waiting for extraction to complete"
        # Release the port on timeout
        release_port $port
        return 1
    else
        echo "✗ Transfer failed with status $transfer_status"
        # Release the port on transfer failure
        release_port $port
        return 1
    fi
}

# Fallback: Direct SSH pipe
transfer_volume_ssh() {
    local key=$1
    local source_folder="/var/lib/docker/volumes/rpc_${key}/_data"
    
    if [[ ! -d "$source_folder" ]]; then
        echo "Warning: $source_folder does not exist, skipping"
        return 1
    fi
    
    local folder_size=$(du -sb "$source_folder" 2>/dev/null | awk '{print $1}')
    
    echo "Using direct SSH transfer for $key (size: $((folder_size / 1048576))MB)"
    
    tar -cf - --dereference "$source_folder" 2>/dev/null | \
        pv -pterb -s "$folder_size" -N "$key" | \
        zstd -3 -T0 | \
        $SSH_CMD -c chacha20-poly1305@openssh.com "$DEST_HOST" \
        "zstd -d | tar -xf - -C /"
    
    if [[ $? -eq 0 ]]; then
        echo "✓ Volume $key transferred successfully"
        return 0
    else
        echo "✗ Transfer failed"
        return 1
    fi
}

# Main execution
main() {
    # Set up cleanup trap
    trap cleanup_all_ports EXIT INT TERM
    
    setup_ssh_multiplex
    
    # the following sysctls are critical for high-latency networks
    # they are not persistent and should not influence low latency connections.
    # but what do I know its what the bot told me...
    # the issue was that on high bandwidth connections with high latency the buffers 
    # where so small that a roundtrip to confirm the packet was necessary every few ms.
    # so that the theoretical bandwidth was limited to 200 MBit/s 
    # also it seems to be important to match the remote buffers to the local buffers.
    # feel free to remove the whole section. maybe it does nothing really.
    
    ssh "$DEST_HOST" "
        sudo sysctl -w net.core.rmem_max=67108864
        sudo sysctl -w net.core.wmem_max=67108864
        sudo sysctl -w net.ipv4.tcp_rmem='4096 87380 67108864'
        sudo sysctl -w net.ipv4.tcp_wmem='4096 87380 67108864'
        sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
        sudo sysctl -w net.core.default_qdisc=fq
    "
    sudo sysctl -w net.ipv4.tcp_slow_start_after_idle=0
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
    sudo sysctl -w net.core.default_qdisc=fq
    sudo sysctl -w net.ipv4.tcp_window_scaling=1
    sudo sysctl -w net.ipv4.tcp_syncookies=1

    # CRITICAL CHANGES - Increase buffers for 154ms RTT
    # Need at least 20MB for 1Gbps at 154ms, using 64MB for headroom
    sudo sysctl -w net.core.rmem_max=67108864          # Was 8MB, now 64MB
    sudo sysctl -w net.core.wmem_max=67108864          # Was 8MB, now 64MB
    sudo sysctl -w net.ipv4.tcp_rmem='4096 87380 67108864'    # Was 8MB max, now 64MB
    sudo sysctl -w net.ipv4.tcp_wmem='4096 87380 67108864'    # Was 8MB max, now 64MB

    # Optional but helpful for high-latency
    sudo sysctl -w net.ipv4.tcp_mtu_probing=1
    sudo sysctl -w net.ipv4.tcp_no_metrics_save=1

    echo "Reading volume configuration from $1.yml..."
    keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')
    
    if [[ -z "$keys" ]]; then
        echo "Error: No volumes found in configuration"
        exit 1
    fi
    
    volume_count=$(echo "$keys" | wc -l)
    echo "Found $volume_count volumes to transfer"
    echo "----------------------------------------"
    
    success_count=0
    failed_volumes=""
    
    for key in $keys; do
        # Try nc method first
        transfer_volume "$key"
        
        if [[ $? -ne 0 ]]; then
            echo "NC transfer failed, trying direct SSH..."
            transfer_volume_ssh "$key"
            
            if [[ $? -eq 0 ]]; then
                success_count=$((success_count + 1))
            else
                failed_volumes="$failed_volumes $key"
            fi
        else
            success_count=$((success_count + 1))
        fi
        
        echo "----------------------------------------"
    done
    
    echo ""
    echo "Transfer Summary:"
    echo "  Successful: $success_count/$volume_count"
    [[ -n "$failed_volumes" ]] && echo "  Failed:$failed_volumes"
    
    # Restore Network buffer and congestion control settings.
    # These are better for your 0.2-1.4ms environment

    ssh "$DEST_HOST" "
        # These are better for your 0.2-1.4ms environment
        sudo sysctl -w net.core.rmem_max=2097152  # 2MB
        sudo sysctl -w net.core.wmem_max=2097152
        sudo sysctl -w net.ipv4.tcp_rmem='4096 87380 2097152'
        sudo sysctl -w net.ipv4.tcp_wmem='4096 87380 2097152'
        sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
        sudo sysctl -w net.core.default_qdisc=fq_codel
        sudo sysctl -w net.ipv4.tcp_slow_start_after_idle=0
        sudo sysctl -w net.ipv4.tcp_tw_reuse=1
    "
    
    sudo sysctl -w net.core.rmem_max=2097152  # 2MB
    sudo sysctl -w net.core.wmem_max=2097152
    sudo sysctl -w net.ipv4.tcp_rmem='4096 87380 2097152'
    sudo sysctl -w net.ipv4.tcp_wmem='4096 87380 2097152'
    sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
    sudo sysctl -w net.core.default_qdisc=fq_codel
    sudo sysctl -w net.ipv4.tcp_slow_start_after_idle=0
    sudo sysctl -w net.ipv4.tcp_tw_reuse=1

    $SSH_CMD -O exit "$DEST_HOST" 2>/dev/null
    
    # Exit with appropriate status (cleanup will be handled by trap)
    [[ $success_count -eq $volume_count ]] && exit 0 || exit 1
}

main "$@"