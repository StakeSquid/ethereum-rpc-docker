#!/bin/bash
# General script to limit OUTGOING bandwidth for all public ports in a Docker Compose file
# Limits each port's outgoing traffic to specified bandwidth (default: 100 MBit/s)
#
# Note: This script limits OUTGOING bandwidth only. Limiting incoming bandwidth is
# impractical for P2P networks because:
# - You can't control what other nodes send you
# - Dropping incoming packets causes retransmissions and wastes bandwidth
# - P2P protocols have backpressure - if you're slow to respond, peers back off
# - Limiting outgoing is usually sufficient to control your bandwidth usage
#
# Usage: 
#   ./limit-bandwidth.sh <compose-file> [start|stop|status] [--limit BANDWIDTH]
#   ./limit-bandwidth.sh rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start
#   ./limit-bandwidth.sh rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start --limit 20mbit
#
# Environment variable:
#   BANDWIDTH_LIMIT=20mbit ./limit-bandwidth.sh <compose-file> start
#
# For cronjob:
#   */5 * * * * /path/to/rpc/limit-bandwidth.sh /path/to/compose.yml start
#   */5 * * * * BANDWIDTH_LIMIT=20mbit /path/to/rpc/limit-bandwidth.sh /path/to/compose.yml start

set -uo pipefail

BASEPATH="$(cd "$(dirname "$0")" && pwd)"

# Bandwidth limit (can be overridden via BANDWIDTH_LIMIT env var or --limit parameter)
# Default: 100mbit
BANDWIDTH_LIMIT="${BANDWIDTH_LIMIT:-100mbit}"
BURST_MULTIPLIER="${BURST_MULTIPLIER:-0.1}"  # Burst is 10% of limit by default
LATENCY="50ms"             # Latency for shaping

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    exit 1
fi

# Check if required tools are installed
if ! command -v tc >/dev/null 2>&1; then
    echo -e "${RED}Error: 'tc' command not found${NC}"
    echo "Please install iproute2:"
    echo "  sudo apt-get update && sudo apt-get install -y iproute2"
    exit 1
fi

if ! command -v iptables >/dev/null 2>&1; then
    echo -e "${RED}Error: 'iptables' command not found${NC}"
    echo "Please install iptables:"
    echo "  sudo apt-get update && sudo apt-get install -y iptables"
    exit 1
fi

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <compose-file> [start|stop|status] [--limit BANDWIDTH]"
    echo ""
    echo "Options:"
    echo "  --limit BANDWIDTH    Set bandwidth limit (e.g., 20mbit, 100mbit)"
    echo "                       Can also use BANDWIDTH_LIMIT environment variable"
    echo ""
    echo "Examples:"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace.yml start"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start --limit 20mbit"
    echo "  BANDWIDTH_LIMIT=20mbit $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start"
    echo "  $0 rpc/ethereum/geth/ethereum-mainnet-geth-pruned-pebble-path status"
    exit 1
fi

COMPOSE_FILE="$1"
ACTION=${2:-start}

# Parse optional --limit parameter
if [ "$ACTION" = "--limit" ] && [ $# -ge 3 ]; then
    BANDWIDTH_LIMIT="$3"
    ACTION=${4:-start}
elif [ $# -ge 3 ] && [ "$2" = "--limit" ]; then
    BANDWIDTH_LIMIT="$3"
    ACTION=${4:-start}
elif [ $# -ge 4 ] && [ "$3" = "--limit" ]; then
    BANDWIDTH_LIMIT="$4"
elif [ "$ACTION" = "--limit" ]; then
    echo -e "${RED}Error: --limit requires a bandwidth value${NC}"
    echo "Example: $0 $COMPOSE_FILE start --limit 20mbit"
    exit 1
fi

# Handle .yml extension (like latest.sh does)
# If filename doesn't end in .yml, append it
if [[ ! "$COMPOSE_FILE" == *.yml ]]; then
    COMPOSE_FILE="${COMPOSE_FILE}.yml"
fi

# Resolve compose file path
if [ ! -f "$COMPOSE_FILE" ]; then
    # Try relative to BASEPATH
    if [ -f "$BASEPATH/$COMPOSE_FILE" ]; then
        COMPOSE_FILE="$BASEPATH/$COMPOSE_FILE"
    else
        echo -e "${RED}Error: Compose file not found: $1${NC}"
        echo "Tried: $COMPOSE_FILE and $BASEPATH/$COMPOSE_FILE"
        exit 1
    fi
fi

COMPOSE_FILE=$(realpath "$COMPOSE_FILE")
COMPOSE_DIR=$(dirname "$COMPOSE_FILE")

# Calculate burst from limit (10% of limit)
# Extract number and unit from BANDWIDTH_LIMIT (e.g., "20mbit" -> "20" and "mbit")
if [[ "$BANDWIDTH_LIMIT" =~ ^([0-9]+)([a-zA-Z]+)$ ]]; then
    LIMIT_NUM="${BASH_REMATCH[1]}"
    LIMIT_UNIT="${BASH_REMATCH[2]}"
    # Calculate 10% of limit (simple integer division for compatibility)
    BURST_NUM=$((LIMIT_NUM / 10))
    # Ensure minimum burst of 1
    if [ "$BURST_NUM" -lt 1 ]; then
        BURST_NUM=1
    fi
    BURST="${BURST_NUM}${LIMIT_UNIT}"
    
    # Calculate appropriate r2q based on bandwidth limit
    # For very low rates (< 10mbit), use higher r2q to avoid quantum warnings
    # r2q controls quantum size: quantum = rate / r2q
    # Higher r2q = smaller quantum = better for low bandwidths
    # We use a high r2q to avoid warnings on both low-rate classes and high-rate root classes
    if [ "$LIMIT_NUM" -lt 10 ]; then
        # Very low bandwidth (< 10mbit): use r2q 200 to minimize quantum warnings
        R2Q_VALUE=200
    elif [ "$LIMIT_NUM" -lt 50 ]; then
        # Low bandwidth (< 50mbit): use r2q 100
        R2Q_VALUE=100
    else
        # Higher bandwidth: use r2q 40 (still higher than default 10 to avoid root class warnings)
        R2Q_VALUE=40
    fi
else
    # Fallback: use 10% of limit as string manipulation
    BURST="${BANDWIDTH_LIMIT}"
    R2Q_VALUE=40  # Safe default
fi

echo -e "${BLUE}Compose file: ${COMPOSE_FILE}${NC}"
echo -e "${BLUE}Bandwidth limit: ${BANDWIDTH_LIMIT} per port${NC}"

# Function to extract ports from YAML
extract_ports() {
    local file="$1"
    # Extract ports in format "HOST:CONTAINER" or "HOST:CONTAINER/PROTO"
    # Look for lines after "ports:" that contain port mappings
    awk '
        /^[[:space:]]*ports:[[:space:]]*$/ { in_ports=1; next }
        /^[[:space:]]*-/ && in_ports { 
            # Match patterns like "13516:13516" or "13516:13516/udp"
            if (match($0, /[0-9]+:[0-9]+/)) {
                port = substr($0, RSTART, RLENGTH)
                # Extract just the host port (first number)
                if (match(port, /^[0-9]+/)) {
                    print substr(port, RSTART, RLENGTH)
                }
            }
        }
        /^[[:space:]]*[a-zA-Z]/ && in_ports { in_ports=0 }
    ' "$file" | sort -u
}

# Function to find Docker bridge for compose project
find_bridge() {
    local compose_dir="$1"
    local project_name=$(basename "$compose_dir" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
    
    # Try to find the network by checking running containers from this compose file
    local container_name=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null | \
        jq -r '.[0].Name' 2>/dev/null | head -1)
    
    if [ -n "$container_name" ] && [ "$container_name" != "null" ]; then
        # Get network from container
        local network=$(docker inspect "$container_name" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -1)
        
        if [ -n "$network" ]; then
            # Find bridge interface for this network
            local bridge=$(docker network inspect "$network" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
            if [ -n "$bridge" ]; then
                # Find interface with this gateway IP
                local iface=$(ip route | grep "$bridge" | awk '{print $3}' | head -1)
                if [ -n "$iface" ]; then
                    echo "$iface"
                    return 0
                fi
            fi
        fi
    fi
    
    # Fallback: find Docker bridge interfaces
    local bridges=$(ip link show | grep -E "^[0-9]+: (br-|docker0)" | cut -d: -f2 | tr -d ' ' | head -1)
    if [ -n "$bridges" ]; then
        echo "$bridges"
        return 0
    fi
    
    # Last resort: use docker0
    if ip link show docker0 >/dev/null 2>&1; then
        echo "docker0"
        return 0
    fi
    
    echo "eth0"  # Final fallback
}

# Extract ports from compose file
PORTS_RAW=$(extract_ports "$COMPOSE_FILE")

if [ -z "$PORTS_RAW" ]; then
    echo -e "${YELLOW}Warning: No public ports found in compose file${NC}"
    exit 0
fi

# Convert to array (simple approach)
PORTS=()
while IFS= read -r line; do
    [ -n "$line" ] && PORTS+=("$line")
done <<< "$PORTS_RAW"

if [ ${#PORTS[@]} -eq 0 ]; then
    echo -e "${YELLOW}Warning: No public ports found in compose file${NC}"
    exit 0
fi

echo -e "${GREEN}Found ${#PORTS[@]} public port(s): ${PORTS[*]}${NC}"

# Find the bridge interface
BRIDGE=$(find_bridge "$COMPOSE_DIR")
echo -e "${BLUE}Using network interface: ${BRIDGE}${NC}"

# Verify interface exists
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo -e "${RED}Error: Network interface '$BRIDGE' not found${NC}"
    exit 1
fi

case "$ACTION" in
    start)
        echo -e "${YELLOW}Setting up bandwidth limiting...${NC}"
        
        # Remove existing qdisc if any
        tc qdisc del dev "$BRIDGE" root 2>/dev/null || true
        
        # Create HTB (Hierarchical Token Bucket) qdisc for egress (outgoing traffic only)
        # We only limit outgoing because:
        # - You control what you send (outgoing)
        # - You can't control what others send (incoming)
        # - Dropping incoming packets causes retransmissions and wastes bandwidth
        # - P2P protocols have backpressure mechanisms
        #
        # Set r2q (rate to quantum ratio) to handle low bandwidths better
        # Higher r2q = smaller quantum = better for low bandwidths
        # Quantum = rate / r2q, so higher r2q means smaller quantums
        # Adaptive r2q based on bandwidth limit to avoid quantum warnings
        tc qdisc add dev "$BRIDGE" root handle 1: htb r2q ${R2Q_VALUE} default 30
        
        # Create root class with high bandwidth
        # Quantum will be calculated from r2q: quantum = rate / r2q
        tc class add dev "$BRIDGE" parent 1: classid 1:1 htb rate 1000mbit
        
        # Create unlimited class for non-limited traffic
        tc class add dev "$BRIDGE" parent 1:1 classid 1:30 htb rate 1000mbit
        
        # Process each port
        PORT_ID=10
        for port in "${PORTS[@]}"; do
            echo -e "${BLUE}  Limiting port ${port} to ${BANDWIDTH_LIMIT}...${NC}"
            
            # Create limited class for this port (outgoing traffic only)
            # Calculate quantum based on rate to avoid warnings
            # Quantum should be roughly rate_in_bytes / 100, but minimum 1500 (MTU size)
            # For 1mbit: 1mbit = 125000 bytes/sec, quantum = 1250, but use at least 1500
            if [[ "$BANDWIDTH_LIMIT" =~ ^([0-9]+)mbit$ ]]; then
                RATE_NUM="${BASH_REMATCH[1]}"
                RATE_BYTES=$((RATE_NUM * 125000))  # Convert mbit to bytes/sec
                QUANTUM=$((RATE_BYTES / 100))
                # Ensure minimum quantum of 1500 (MTU size)
                if [ "$QUANTUM" -lt 1500 ]; then
                    QUANTUM=1500
                fi
                # Cap maximum quantum to avoid issues
                if [ "$QUANTUM" -gt 100000 ]; then
                    QUANTUM=100000
                fi
                tc class add dev "$BRIDGE" parent 1:1 classid 1:${PORT_ID} htb rate ${BANDWIDTH_LIMIT} burst ${BURST} ceil ${BANDWIDTH_LIMIT} quantum ${QUANTUM}
            else
                # Fallback: let HTB calculate automatically
                tc class add dev "$BRIDGE" parent 1:1 classid 1:${PORT_ID} htb rate ${BANDWIDTH_LIMIT} burst ${BURST} ceil ${BANDWIDTH_LIMIT}
            fi
            
            # Add filter to route marked packets to this class (outgoing only)
            tc filter add dev "$BRIDGE" parent 1: protocol ip prio ${PORT_ID} handle ${PORT_ID} fw flowid 1:${PORT_ID}
            
            # Mark outgoing traffic in OUTPUT chain (traffic from host)
            iptables -t mangle -C OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || \
                iptables -t mangle -A OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID}
            iptables -t mangle -C OUTPUT -p udp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || \
                iptables -t mangle -A OUTPUT -p udp --sport ${port} -j MARK --set-mark ${PORT_ID}
            
            # Mark outgoing traffic in FORWARD chain (traffic from containers)
            # This catches traffic from containers going out through the bridge
            iptables -t mangle -C FORWARD -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || \
                iptables -t mangle -A FORWARD -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID}
            iptables -t mangle -C FORWARD -p udp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || \
                iptables -t mangle -A FORWARD -p udp --sport ${port} -j MARK --set-mark ${PORT_ID}
            
            PORT_ID=$((PORT_ID + 1))
        done
        
        echo -e "${GREEN}✓ Outgoing bandwidth limiting configured!${NC}"
        echo -e "${GREEN}All ports are now limited to ${BANDWIDTH_LIMIT} outgoing traffic each${NC}"
        echo -e "${YELLOW}Note: Only OUTGOING traffic is limited. Incoming traffic is not limited.${NC}"
        ;;
    stop)
        echo -e "${YELLOW}Removing bandwidth limiting...${NC}"
        
        # Remove iptables rules for each port
        PORT_ID=10
        for port in "${PORTS[@]}"; do
            echo -e "${BLUE}  Removing limits for port ${port}...${NC}"
            
            # Remove OUTPUT rules (outgoing from host)
            iptables -t mangle -D OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p udp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
            
            # Remove FORWARD rules (outgoing from containers)
            iptables -t mangle -D FORWARD -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
            iptables -t mangle -D FORWARD -p udp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
            
            PORT_ID=$((PORT_ID + 1))
        done
        
        # Remove tc qdisc
        tc qdisc del dev "$BRIDGE" root 2>/dev/null || true
        
        echo -e "${GREEN}✓ Bandwidth limiting removed${NC}"
        ;;
    status)
        echo -e "${YELLOW}Current bandwidth limiting status:${NC}"
        echo ""
        echo -e "${BLUE}TC Qdisc on ${BRIDGE}:${NC}"
        tc qdisc show dev "$BRIDGE" 2>/dev/null || echo "  No qdisc configured"
        echo ""
        echo -e "${BLUE}TC Classes:${NC}"
        tc class show dev "$BRIDGE" 2>/dev/null || echo "  No classes configured"
        echo ""
        echo -e "${BLUE}Iptables rules (OUTPUT - outgoing from host):${NC}"
        iptables -t mangle -L OUTPUT -n --line-numbers | grep -E "MARK|${PORTS[0]}" || echo "  No rules found"
        echo ""
        echo -e "${BLUE}Iptables rules (FORWARD - outgoing from containers):${NC}"
        iptables -t mangle -L FORWARD -n --line-numbers | grep -E "MARK|${PORTS[0]}" || echo "  No rules found"
        echo ""
        echo -e "${YELLOW}Note: Only outgoing traffic is limited. Incoming traffic is not limited${NC}"
        echo -e "${YELLOW}      because you can't control what other nodes send you.${NC}"
        echo ""
        echo -e "${BLUE}Monitored ports: ${PORTS[*]}${NC}"
        ;;
    *)
        echo -e "${RED}Error: Invalid action '$ACTION'${NC}"
        echo "Usage: $0 <compose-file> [start|stop|status]"
        exit 1
        ;;
esac
