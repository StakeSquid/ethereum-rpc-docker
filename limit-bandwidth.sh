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
# IP-based limiting: When using --limit-by-ip, a cronjob is automatically created
# to update iptables rules if the container IP changes (e.g., after restart)
#
# Usage: 
#   ./limit-bandwidth.sh <compose-file> [start|stop|status] [OPTIONS]
#   ./limit-bandwidth.sh rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start
#   ./limit-bandwidth.sh rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start --limit 20mbit
#   ./limit-bandwidth.sh rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start --limit 5mbit --total-limit
#   ./limit-bandwidth.sh rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start --limit 5mbit --per-port-limit
#
# Options:
#   --limit BANDWIDTH       Set bandwidth limit (e.g., 20mbit, 100mbit)
#   --total-limit           All ports share the limit (default)
#   --per-port-limit        Each port gets its own limit
#
# Environment variables:
#   BANDWIDTH_LIMIT=20mbit ./limit-bandwidth.sh <compose-file> start
#   TOTAL_LIMIT=false BANDWIDTH_LIMIT=5mbit ./limit-bandwidth.sh <compose-file> start
#     (TOTAL_LIMIT=false for per-port limits, true is default)
#
# For cronjob:
#   */5 * * * * /path/to/rpc/limit-bandwidth.sh /path/to/compose.yml start
#   */5 * * * * BANDWIDTH_LIMIT=20mbit /path/to/rpc/limit-bandwidth.sh /path/to/compose.yml start

set -uo pipefail

BASEPATH="$(cd "$(dirname "$0")" && pwd)"

# Bandwidth limit (can be overridden via BANDWIDTH_LIMIT env var or --limit parameter)
# Default: 100mbit
BANDWIDTH_LIMIT="${BANDWIDTH_LIMIT:-100mbit}"
# TOTAL_LIMIT: If "true", limit is shared across all ports (total bandwidth)
# If "false", each port gets its own limit (per-port bandwidth)
# Default: true (total limit is now the default behavior)
TOTAL_LIMIT="${TOTAL_LIMIT:-true}"
# LIMIT_BY_IP: If "true", limit all traffic from container IP (not just specific ports)
# This catches ephemeral ports but requires detecting container IP dynamically
# Default: false (use port-based limiting)
LIMIT_BY_IP="${LIMIT_BY_IP:-false}"
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
    echo "Usage: $0 <compose-file> [start|stop|status] [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --limit BANDWIDTH       Set bandwidth limit (e.g., 20mbit, 100mbit)"
    echo "                          Can also use BANDWIDTH_LIMIT environment variable"
    echo "  --total-limit           Use total limit mode: all ports share the limit (default)"
    echo "  --per-port-limit        Use per-port limit mode: each port gets its own limit"
    echo "  --limit-by-ip           Limit by container IP (catches all ports including ephemeral)"
    echo "                          Traffic between containers on same network is NOT limited"
    echo "  --limit-by-port         Limit by source port only (default, misses ephemeral ports)"
    echo "                          Can also use LIMIT_BY_IP=true/false environment variable"
    echo ""
    echo "Examples:"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace.yml start"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start --limit 20mbit"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start --limit 5mbit --total-limit"
    echo "  $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start --limit 5mbit --per-port-limit"
    echo "  BANDWIDTH_LIMIT=20mbit $0 rpc/gnosis/reth/gnosis-mainnet-reth-pruned-trace start"
    echo "  $0 rpc/ethereum/geth/ethereum-mainnet-geth-pruned-pebble-path status"
    exit 1
fi

COMPOSE_FILE="$1"
ACTION=${2:-start}

# Parse optional parameters
# Special handling for update-ip command (it has its own parameters)
if [ "$ACTION" = "update-ip" ]; then
    # For update-ip, skip normal argument parsing and let the case statement handle it
    shift 2  # Remove compose file and action
else
    # Normal argument parsing for start/stop/status
    shift  # Remove compose file
    shift  # Remove action (or use default)
    while [ $# -gt 0 ]; do
        case "$1" in
            --limit)
                if [ -z "$2" ]; then
                    echo -e "${RED}Error: --limit requires a bandwidth value${NC}"
                    echo "Example: $0 $COMPOSE_FILE start --limit 20mbit"
                    exit 1
                fi
                BANDWIDTH_LIMIT="$2"
                shift 2
                ;;
            --total-limit)
                TOTAL_LIMIT="true"
                shift
                ;;
            --per-port-limit)
                TOTAL_LIMIT="false"
                shift
                ;;
            --limit-by-ip)
                LIMIT_BY_IP="true"
                shift
                ;;
            --limit-by-port)
                LIMIT_BY_IP="false"
                shift
                ;;
            *)
                # Unknown option, might be old-style --limit usage
                if [ "$1" = "--limit" ] && [ -n "$2" ]; then
                    BANDWIDTH_LIMIT="$2"
                    shift 2
                else
                    echo -e "${YELLOW}Warning: Unknown option '$1', ignoring${NC}"
                    shift
                fi
                ;;
        esac
    done
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

# Function to find the physical egress interface (where traffic actually leaves the system)
find_egress_interface() {
    # Method 1: Find interface from default route (most reliable)
    local default_route=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$default_route" ]; then
        local egress=$(echo "$default_route" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        if [ -n "$egress" ] && ip link show "$egress" >/dev/null 2>&1; then
            # Verify it's not a virtual interface
            if ! echo "$egress" | grep -qE "^(lo|docker|br-|veth)"; then
                echo "$egress"
                return 0
            fi
        fi
    fi
    
    # Method 2: Find interface used for a test route (works even without default route)
    # Try multiple common IPs to find egress interface
    for test_ip in 8.8.8.8 1.1.1.1 208.67.222.222; do
        local route_output=$(ip route get "$test_ip" 2>/dev/null | head -1)
        if [ -n "$route_output" ]; then
            local egress=$(echo "$route_output" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
            if [ -n "$egress" ] && ip link show "$egress" >/dev/null 2>&1; then
                # Verify it's not a virtual interface
                if ! echo "$egress" | grep -qE "^(lo|docker|br-|veth)"; then
                    echo "$egress"
                    return 0
                fi
            fi
        fi
    done
    
    # Method 3: Find first physical interface (non-virtual, non-loopback)
    # Look for interfaces that are UP and not virtual
    local iface=$(ip link show | grep -E "^[0-9]+:" | grep -vE "lo:|docker|br-|veth" | \
        while read -r line; do
            ifname=$(echo "$line" | cut -d: -f2 | tr -d ' ')
            # Check if interface is UP and not a virtual type
            if ip link show "$ifname" 2>/dev/null | grep -q "state UP" && \
               ! ip link show "$ifname" 2>/dev/null | grep -qE "link/loopback|link/none"; then
                echo "$ifname"
                break
            fi
        done | head -1)
    
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi
    
    # Method 4: Simple fallback - find first non-virtual interface name
    local iface=$(ip link show | grep -E "^[0-9]+:" | grep -vE "lo:|docker|br-|veth" | \
        head -1 | cut -d: -f2 | tr -d ' ')
    
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi
    
    # Final fallback: common interface names (in order of likelihood)
    for fallback in eth0 enp0s3 enp0s8 ens33 ens3; do
        if ip link show "$fallback" >/dev/null 2>&1; then
            echo "$fallback"
            return 0
        fi
    done
    
    # Last resort
    echo "eth0"
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

# Find the bridge interface (for iptables marking)
BRIDGE=$(find_bridge "$COMPOSE_DIR")
echo -e "${BLUE}Using bridge interface: ${BRIDGE}${NC}"

# Find the physical egress interface (where traffic actually leaves)
EGRESS_IFACE=$(find_egress_interface)
echo -e "${BLUE}Using egress interface: ${EGRESS_IFACE}${NC}"

# Function to get network subnet from .env file or environment
get_network_subnet() {
    # Try to get from .env file in the same directory as compose file first
    local compose_dir=$(dirname "$COMPOSE_FILE")
    local env_file="$compose_dir/.env"
    
    # Also check root .env file (where CHAINS_SUBNET is typically defined)
    if [ ! -f "$env_file" ] || ! grep -q "^[[:space:]]*CHAINS_SUBNET[[:space:]]*=" "$env_file" 2>/dev/null; then
        env_file="$BASEPATH/.env"
    fi
    
    # Try to read CHAINS_SUBNET from .env file
    if [ -f "$env_file" ]; then
        # Handle various .env formats: CHAINS_SUBNET=value, CHAINS_SUBNET="value", CHAINS_SUBNET='value', CHAINS_SUBNET = value
        local subnet=$(grep -E "^[[:space:]]*CHAINS_SUBNET[[:space:]]*=" "$env_file" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' | sed 's/^["'\'']//' | sed 's/["'\'']$//' | tr -d ' ')
        if [ -n "$subnet" ]; then
            echo "$subnet"
            return 0
        fi
    fi
    
    # Fallback: try environment variable (allows override)
    if [ -n "$CHAINS_SUBNET" ]; then
        echo "$CHAINS_SUBNET"
        return 0
    fi
    
    # Last resort: try to detect from Docker network (dynamic detection)
    local network="rpc_chains"
    local subnet=$(docker network inspect "$network" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | head -1)
    if [ -n "$subnet" ]; then
        echo "$subnet"
        return 0
    fi
    
    # Final fallback: default from base.yml (matches base.yml default)
    echo "192.168.0.0/26"
}

# Function to get container IP and network subnet (for IP-based limiting)
get_container_network_info() {
    # Try docker compose first
    local container_name=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null | \
        jq -r '.[0].Name' 2>/dev/null | head -1)
    
    # Fallback: try to find container by compose file path
    if [ -z "$container_name" ] || [ "$container_name" = "null" ]; then
        # Extract service name from compose file path (e.g., gnosis-mainnet-erigon3 from path)
        local service_name=$(basename "$COMPOSE_FILE" .yml | sed 's/-pruned-trace$//' | sed 's/-archive-trace$//' | sed 's/-minimal-trace$//')
        container_name=$(docker ps --filter "name=$service_name" --format "{{.Names}}" 2>/dev/null | head -1)
    fi
    
    if [ -z "$container_name" ] || [ "$container_name" = "null" ]; then
        echo ""
        return 1
    fi
    
    # Get container IP
    local container_ip=$(docker inspect "$container_name" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$conf.IPAddress}}{{end}}' 2>/dev/null | head -1)
    
    if [ -z "$container_ip" ]; then
        echo ""
        return 1
    fi
    
    # Get network subnet from .env or environment (not hardcoded)
    local subnet=$(get_network_subnet)
    
    echo "$container_ip|$subnet"
    return 0
}

# Get container IP and network info if IP-based limiting is enabled
CONTAINER_IP=""
NETWORK_SUBNET=""
if [ "$LIMIT_BY_IP" = "true" ] || [ "$LIMIT_BY_IP" = "1" ] || [ "$LIMIT_BY_IP" = "yes" ]; then
    NETWORK_INFO=$(get_container_network_info)
    if [ -n "$NETWORK_INFO" ]; then
        CONTAINER_IP=$(echo "$NETWORK_INFO" | cut -d'|' -f1)
        NETWORK_SUBNET=$(echo "$NETWORK_INFO" | cut -d'|' -f2)
        if [ -n "$CONTAINER_IP" ]; then
            echo -e "${BLUE}Container IP: ${CONTAINER_IP}${NC}"
            if [ -n "$NETWORK_SUBNET" ]; then
                echo -e "${BLUE}Network subnet: ${NETWORK_SUBNET} (inter-container traffic will NOT be limited)${NC}"
            fi
        else
            echo -e "${YELLOW}Warning: Could not detect container IP, falling back to port-based limiting${NC}"
            LIMIT_BY_IP="false"
        fi
    else
        echo -e "${YELLOW}Warning: Could not detect container IP, falling back to port-based limiting${NC}"
        LIMIT_BY_IP="false"
    fi
fi

# Verify interfaces exist
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo -e "${RED}Error: Network interface '$BRIDGE' not found${NC}"
    exit 1
fi

if ! ip link show "$EGRESS_IFACE" >/dev/null 2>&1; then
    echo -e "${RED}Error: Egress interface '$EGRESS_IFACE' not found${NC}"
    exit 1
fi

case "$ACTION" in
    start)
        echo -e "${YELLOW}Setting up bandwidth limiting...${NC}"
        
        # Clean up existing iptables rules first (to avoid duplicates/conflicts)
        echo -e "${BLUE}Cleaning up existing iptables rules...${NC}"
        PORT_ID=10
        for port in "${PORTS[@]}"; do
            # Remove OUTPUT rules (outgoing from host)
            iptables -t mangle -D OUTPUT -p tcp --sport ${port} -j MARK 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p udp --sport ${port} -j MARK 2>/dev/null || true
            
            # Remove FORWARD rules (outgoing from containers)
            iptables -t mangle -D FORWARD -p tcp --sport ${port} -j MARK 2>/dev/null || true
            iptables -t mangle -D FORWARD -p udp --sport ${port} -j MARK 2>/dev/null || true
            
            # Remove POSTROUTING rules
            iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK 2>/dev/null || true
            iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK 2>/dev/null || true
            
            PORT_ID=$((PORT_ID + 1))
        done
        
        # Also clean up shared class mark (20) if it exists
        SHARED_MARK=20
        for port in "${PORTS[@]}"; do
            iptables -t mangle -D OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            iptables -t mangle -D FORWARD -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            iptables -t mangle -D FORWARD -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
        done
        
        # Remove existing qdisc if any (on both bridge and egress interface)
        tc qdisc del dev "$BRIDGE" root 2>/dev/null || true
        tc qdisc del dev "$EGRESS_IFACE" root 2>/dev/null || true
        
        # Create HTB (Hierarchical Token Bucket) qdisc for egress (outgoing traffic only)
        # Apply to the physical egress interface where traffic actually leaves the system
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
        tc qdisc add dev "$EGRESS_IFACE" root handle 1: htb r2q ${R2Q_VALUE} default 30
        
        # Create root class with high bandwidth
        # Set explicit quantum to avoid warnings
        # Quantum should be between 1500-60000 bytes for optimal performance
        # For 1000mbit (125MB/s), use quantum of 50000 bytes (within recommended range)
        tc class add dev "$EGRESS_IFACE" parent 1: classid 1:1 htb rate 1000mbit quantum 50000
        
        # Create unlimited class for non-limited traffic
        tc class add dev "$EGRESS_IFACE" parent 1:1 classid 1:30 htb rate 1000mbit quantum 50000
        
        # Check if we should use total limit (shared across all ports) or per-port limit
        if [ "$TOTAL_LIMIT" = "true" ] || [ "$TOTAL_LIMIT" = "1" ] || [ "$TOTAL_LIMIT" = "yes" ]; then
            # TOTAL LIMIT MODE: All ports share a single class with the specified limit
            echo -e "${BLUE}Using TOTAL limit mode: All ${#PORTS[@]} ports share ${BANDWIDTH_LIMIT} total${NC}"
            
            # Calculate quantum for the shared class
            if [[ "$BANDWIDTH_LIMIT" =~ ^([0-9]+)mbit$ ]]; then
                RATE_NUM="${BASH_REMATCH[1]}"
                RATE_BYTES=$((RATE_NUM * 125000))
                QUANTUM=$((RATE_BYTES / 2000))
                if [ "$QUANTUM" -lt 1500 ]; then
                    QUANTUM=1500
                fi
                if [ "$QUANTUM" -gt 60000 ]; then
                    QUANTUM=60000
                fi
            else
                QUANTUM=1500
            fi
            
            # Create a single shared class for all ports (class ID 20)
            SHARED_CLASS_ID=20
            MARK_VALUE=${SHARED_CLASS_ID}
            tc class add dev "$EGRESS_IFACE" parent 1:1 classid 1:${SHARED_CLASS_ID} htb rate ${BANDWIDTH_LIMIT} burst ${BURST} ceil ${BANDWIDTH_LIMIT} quantum ${QUANTUM}
            
            # Add filter to route marked packets to shared class (only once, not per port)
            tc filter add dev "$EGRESS_IFACE" parent 1: protocol ip prio ${MARK_VALUE} handle ${MARK_VALUE} fw flowid 1:${SHARED_CLASS_ID} 2>/dev/null || true
            
            # IP-based limiting: Mark all traffic from container IP (excluding inter-container traffic)
            if [ "$LIMIT_BY_IP" = "true" ] && [ -n "$CONTAINER_IP" ]; then
                echo -e "${BLUE}  Adding IP-based limiting for ${CONTAINER_IP}...${NC}"
                
                # Mark outgoing traffic in FORWARD chain (traffic from container going to internet)
                # Exclude traffic going to other containers in the same network
                if [ -n "$NETWORK_SUBNET" ]; then
                    echo -e "${BLUE}    Excluding traffic to ${NETWORK_SUBNET} (inter-container traffic)${NC}"
                    iptables -t mangle -C FORWARD -s "$CONTAINER_IP" ! -d "$NETWORK_SUBNET" -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A FORWARD -s "$CONTAINER_IP" ! -d "$NETWORK_SUBNET" -j MARK --set-mark ${MARK_VALUE}
                else
                    iptables -t mangle -C FORWARD -s "$CONTAINER_IP" -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A FORWARD -s "$CONTAINER_IP" -j MARK --set-mark ${MARK_VALUE}
                fi
                
                # Mark outgoing traffic in POSTROUTING chain (critical for Docker NAT)
                if [ -n "$NETWORK_SUBNET" ]; then
                    iptables -t mangle -C POSTROUTING -o "$EGRESS_IFACE" -s "$CONTAINER_IP" ! -d "$NETWORK_SUBNET" -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A POSTROUTING -o "$EGRESS_IFACE" -s "$CONTAINER_IP" ! -d "$NETWORK_SUBNET" -j MARK --set-mark ${MARK_VALUE}
                else
                    iptables -t mangle -C POSTROUTING -o "$EGRESS_IFACE" -s "$CONTAINER_IP" -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A POSTROUTING -o "$EGRESS_IFACE" -s "$CONTAINER_IP" -j MARK --set-mark ${MARK_VALUE}
                fi
            fi
            
            # Port-based limiting: Mark traffic from specific ports (if not using IP-only mode)
            if [ "$LIMIT_BY_IP" != "true" ] || [ -z "$CONTAINER_IP" ]; then
                # Process each port - all route to the same shared class
                for port in "${PORTS[@]}"; do
                    echo -e "${BLUE}  Adding port ${port} to shared limit of ${BANDWIDTH_LIMIT}...${NC}"
                    
                    # Mark outgoing traffic in OUTPUT chain (traffic from host)
                    iptables -t mangle -C OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${MARK_VALUE}
                    iptables -t mangle -C OUTPUT -p udp --sport ${port} -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A OUTPUT -p udp --sport ${port} -j MARK --set-mark ${MARK_VALUE}
                    
                    # Mark outgoing traffic in FORWARD chain (traffic from containers)
                    iptables -t mangle -C FORWARD -p tcp --sport ${port} -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A FORWARD -p tcp --sport ${port} -j MARK --set-mark ${MARK_VALUE}
                    iptables -t mangle -C FORWARD -p udp --sport ${port} -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A FORWARD -p udp --sport ${port} -j MARK --set-mark ${MARK_VALUE}
                    
                    # Mark outgoing traffic in POSTROUTING chain (critical for Docker NAT)
                    iptables -t mangle -C POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK --set-mark ${MARK_VALUE}
                    iptables -t mangle -C POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK --set-mark ${MARK_VALUE} 2>/dev/null || \
                        iptables -t mangle -A POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK --set-mark ${MARK_VALUE}
                done
            fi
            
            echo -e "${GREEN}✓ Outgoing bandwidth limiting configured!${NC}"
            echo -e "${GREEN}All ${#PORTS[@]} ports share a TOTAL limit of ${BANDWIDTH_LIMIT} outgoing traffic${NC}"
        else
            # PER-PORT LIMIT MODE: Each port gets its own class (original behavior)
            echo -e "${BLUE}Using PER-PORT limit mode: Each port limited to ${BANDWIDTH_LIMIT}${NC}"
            
            PORT_ID=10
            for port in "${PORTS[@]}"; do
                echo -e "${BLUE}  Limiting port ${port} to ${BANDWIDTH_LIMIT}...${NC}"
                
                # Create limited class for this port (outgoing traffic only)
                # Calculate quantum based on rate to avoid warnings
                # Quantum should be between 1500-60000 bytes for optimal performance
                # Formula: quantum should be roughly rate_in_bytes / 2000 to stay in range
                if [[ "$BANDWIDTH_LIMIT" =~ ^([0-9]+)mbit$ ]]; then
                    RATE_NUM="${BASH_REMATCH[1]}"
                    RATE_BYTES=$((RATE_NUM * 125000))  # Convert mbit to bytes/sec (1mbit = 125KB/s)
                    QUANTUM=$((RATE_BYTES / 2000))     # Divide by 2000 to get reasonable quantum
                    # Ensure minimum quantum of 1500 (MTU size)
                    if [ "$QUANTUM" -lt 1500 ]; then
                        QUANTUM=1500
                    fi
                    # Cap maximum quantum at 60000 (HTB recommended max)
                    if [ "$QUANTUM" -gt 60000 ]; then
                        QUANTUM=60000
                    fi
                    tc class add dev "$EGRESS_IFACE" parent 1:1 classid 1:${PORT_ID} htb rate ${BANDWIDTH_LIMIT} burst ${BURST} ceil ${BANDWIDTH_LIMIT} quantum ${QUANTUM}
                else
                    # Fallback: use safe default quantum
                    tc class add dev "$EGRESS_IFACE" parent 1:1 classid 1:${PORT_ID} htb rate ${BANDWIDTH_LIMIT} burst ${BURST} ceil ${BANDWIDTH_LIMIT} quantum 1500
                fi
                
                # Add filter to route marked packets to this class (outgoing only)
                tc filter add dev "$EGRESS_IFACE" parent 1: protocol ip prio ${PORT_ID} handle ${PORT_ID} fw flowid 1:${PORT_ID}
                
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
                
                # Mark outgoing traffic in POSTROUTING chain (critical for Docker NAT)
                # This ensures marks are preserved through NAT and applied on the egress interface
                iptables -t mangle -C POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || \
                    iptables -t mangle -A POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID}
                iptables -t mangle -C POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || \
                    iptables -t mangle -A POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK --set-mark ${PORT_ID}
                
                PORT_ID=$((PORT_ID + 1))
            done
            
            echo -e "${GREEN}✓ Outgoing bandwidth limiting configured!${NC}"
            echo -e "${GREEN}All ports are now limited to ${BANDWIDTH_LIMIT} outgoing traffic each${NC}"
        fi
        
        echo -e "${YELLOW}Note: Only OUTGOING traffic is limited. Incoming traffic is not limited.${NC}"
        
        # If using IP-based limiting, set up cronjob to update IP if container restarts
        if [ "$LIMIT_BY_IP" = "true" ] && [ -n "$CONTAINER_IP" ]; then
            echo -e "${BLUE}Setting up cronjob to update IP-based rules if container IP changes...${NC}"
            
            # Create a unique identifier for this cronjob based on compose file
            CRON_ID=$(echo "$COMPOSE_FILE" | md5sum | cut -d' ' -f1 | head -c 8)
            CRON_TAG="limit-bandwidth-${CRON_ID}"
            
            # Remove existing cronjob if any
            (crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true) | crontab -
            
            # Add new cronjob (every 5 minutes)
            CRON_CMD="*/5 * * * * $BASEPATH/limit-bandwidth.sh \"$COMPOSE_FILE\" update-ip --cron-id $CRON_ID >> /var/log/limit-bandwidth-${CRON_ID}.log 2>&1"
            (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON_CMD # $CRON_TAG") | crontab -
            
            echo -e "${GREEN}✓ Cronjob registered (runs every 5 minutes to update IP if changed)${NC}"
            echo -e "${BLUE}  To view logs: tail -f /var/log/limit-bandwidth-${CRON_ID}.log${NC}"
        fi
        ;;
    update-ip)
        # Internal command to update IP-based rules (called by cronjob)
        # Parse --cron-id parameter from remaining arguments
        CRON_ID=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --cron-id)
                    if [ -n "$2" ]; then
                        CRON_ID="$2"
                        shift 2
                    else
                        echo "$(date): Error: --cron-id requires a value"
                        exit 1
                    fi
                    ;;
                --cron-id=*)
                    CRON_ID="${1#*=}"
                    shift
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        
        if [ -z "$CRON_ID" ]; then
            echo "$(date): Error: update-ip requires --cron-id parameter"
            exit 1
        fi
        
        # Need to re-initialize variables for update-ip command
        EGRESS_IFACE=$(find_egress_interface)
        
        # Get expected service name from compose file to verify container matches
        EXPECTED_SERVICE=$(grep -E "^[[:space:]]*[a-zA-Z0-9_-]+:" "$COMPOSE_FILE" | grep -v "^[[:space:]]*x-" | head -1 | cut -d: -f1 | tr -d ' ')
        
        # Get ports from compose file (needed for cleanup)
        PORTS_RAW=$(extract_ports "$COMPOSE_FILE")
        PORTS=()
        while IFS= read -r line; do
            [ -n "$line" ] && PORTS+=("$line")
        done <<< "$PORTS_RAW"
        
        # Get current container IP and verify container exists
        NETWORK_INFO=$(get_container_network_info)
        if [ -z "$NETWORK_INFO" ]; then
            echo "$(date): WARNING: Container not found for compose file $COMPOSE_FILE"
            echo "$(date): Container may have been removed. Removing all bandwidth limiting rules (IP and port-based)."
            
            # Find and remove any existing IP-based rules
            EXISTING_IP=$(iptables -t mangle -L FORWARD -n 2>/dev/null | grep "MARK set 0x14" | grep -oE "192\.168\.[0-9]+\.[0-9]+" | head -1)
            if [ -z "$EXISTING_IP" ]; then
                EXISTING_IP=$(iptables -t mangle -L POSTROUTING -n 2>/dev/null | grep "MARK set 0x14" | grep -oE "192\.168\.[0-9]+\.[0-9]+" | head -1)
            fi
            
            if [ -n "$EXISTING_IP" ]; then
                SHARED_MARK=20
                CURRENT_SUBNET=$(get_network_subnet)
                if [ -n "$CURRENT_SUBNET" ]; then
                    iptables -t mangle -D FORWARD -s "$EXISTING_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                    iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$EXISTING_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                else
                    iptables -t mangle -D FORWARD -s "$EXISTING_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                    iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$EXISTING_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                fi
                echo "$(date): Removed IP-based rules for $EXISTING_IP"
            fi
            
            # Remove port-based rules (they add overhead to iptables if left orphaned)
            if [ ${#PORTS[@]} -gt 0 ]; then
                echo "$(date): Removing port-based rules for ports: ${PORTS[*]}"
                SHARED_MARK=20
                PORT_ID=10
                for port in "${PORTS[@]}"; do
                    # Remove OUTPUT rules
                    iptables -t mangle -D OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                    iptables -t mangle -D OUTPUT -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                    # Remove FORWARD rules
                    iptables -t mangle -D FORWARD -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                    iptables -t mangle -D FORWARD -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                    # Remove POSTROUTING rules
                    iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                    iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                    PORT_ID=$((PORT_ID + 1))
                done
                echo "$(date): Removed port-based rules for ${#PORTS[@]} ports"
            fi
            
            # Optionally remove cronjob if container is permanently gone
            # (User can manually restart if container comes back)
            echo "$(date): NOTE: If container is permanently removed, run 'stop' command to remove cronjob"
            exit 0
        fi
        
        CURRENT_IP=$(echo "$NETWORK_INFO" | cut -d'|' -f1)
        CURRENT_SUBNET=$(echo "$NETWORK_INFO" | cut -d'|' -f2)
        
        # Verify the container matches expected service (safety check)
        # The IP we got came from get_container_network_info, which already verified the container exists
        # But we should double-check that the container is still running and matches
        
        # Get container name that was used to find the IP (re-use the same logic)
        CONTAINER_NAME=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null | \
            jq -r '.[0].Name' 2>/dev/null | head -1)
        
        if [ -z "$CONTAINER_NAME" ] || [ "$CONTAINER_NAME" = "null" ]; then
            # Fallback: try to find container by service name pattern
            if [ -n "$EXPECTED_SERVICE" ]; then
                CONTAINER_NAME=$(docker ps --filter "name=$EXPECTED_SERVICE" --format "{{.Names}}" 2>/dev/null | head -1)
            fi
        fi
        
        # If we can't find the container name, but we got an IP, verify by checking which container has that IP
        if [ -z "$CONTAINER_NAME" ]; then
            # Find container by IP address
            CONTAINER_NAME=$(docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
                container_ip=$(docker inspect "$name" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$conf.IPAddress}}{{end}}' 2>/dev/null | head -1)
                if [ "$container_ip" = "$CURRENT_IP" ]; then
                    echo "$name"
                    break
                fi
            done | head -1)
        fi
        
        # Verify container exists and is running
        if [ -z "$CONTAINER_NAME" ]; then
            echo "$(date): WARNING: Could not find container with IP $CURRENT_IP"
            echo "$(date): Container may have been removed. Removing IP-based rules to prevent affecting other containers."
            
            # Remove rules for this IP to prevent affecting wrong container
            SHARED_MARK=20
            if [ -n "$CURRENT_SUBNET" ]; then
                iptables -t mangle -D FORWARD -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            else
                iptables -t mangle -D FORWARD -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            fi
            echo "$(date): Removed rules for $CURRENT_IP. Run 'start' command again when correct container is running."
            exit 0
        fi
        
        # Verify IP actually belongs to this container
        CONTAINER_IP_CHECK=$(docker inspect "$CONTAINER_NAME" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$conf.IPAddress}}{{end}}' 2>/dev/null | head -1)
        if [ "$CONTAINER_IP_CHECK" != "$CURRENT_IP" ]; then
            echo "$(date): WARNING: IP mismatch! Container $CONTAINER_NAME has IP $CONTAINER_IP_CHECK but found $CURRENT_IP"
            echo "$(date): This IP may have been reassigned to a different container. Removing rules to prevent affecting wrong container."
            
            # Remove old rules for the IP we found
            SHARED_MARK=20
            if [ -n "$CURRENT_SUBNET" ]; then
                iptables -t mangle -D FORWARD -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            else
                iptables -t mangle -D FORWARD -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            fi
            echo "$(date): Removed rules for $CURRENT_IP. Run 'start' command again when correct container is running."
            exit 0
        fi
        
        # Additional verification: check if container is actually running
        CONTAINER_STATE=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null)
        if [ "$CONTAINER_STATE" != "running" ]; then
            echo "$(date): WARNING: Container $CONTAINER_NAME is not running (state: $CONTAINER_STATE)"
            echo "$(date): Removing IP-based rules to prevent affecting other containers if IP is reassigned."
            
            SHARED_MARK=20
            if [ -n "$CURRENT_SUBNET" ]; then
                iptables -t mangle -D FORWARD -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            else
                iptables -t mangle -D FORWARD -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            fi
            echo "$(date): Removed rules for $CURRENT_IP. Rules will be re-added when container is running again."
            exit 0
        fi
        
        # Verify container name matches expected service (additional safety check)
        if [ -n "$EXPECTED_SERVICE" ] && ! echo "$CONTAINER_NAME" | grep -qi "$EXPECTED_SERVICE"; then
            echo "$(date): WARNING: Container name '$CONTAINER_NAME' doesn't match expected service '$EXPECTED_SERVICE'"
            echo "$(date): However, IP $CURRENT_IP belongs to this container. Proceeding with update."
        fi
        
        # Check if IP-based rules exist and get the IP they're using
        # Look for rules with MARK set 0x14 (20 in decimal) that have source IP
        EXISTING_IP=$(iptables -t mangle -L FORWARD -n 2>/dev/null | grep "MARK set 0x14" | grep -oE "192\.168\.[0-9]+\.[0-9]+" | head -1)
        
        # If no existing IP found, try POSTROUTING chain
        if [ -z "$EXISTING_IP" ]; then
            EXISTING_IP=$(iptables -t mangle -L POSTROUTING -n 2>/dev/null | grep "MARK set 0x14" | grep -oE "192\.168\.[0-9]+\.[0-9]+" | head -1)
        fi
        
        # If IP hasn't changed, no update needed
        if [ -n "$EXISTING_IP" ] && [ "$CURRENT_IP" = "$EXISTING_IP" ]; then
            echo "$(date): IP unchanged ($CURRENT_IP), no update needed"
            exit 0
        fi
        
        if [ -n "$EXISTING_IP" ]; then
            echo "$(date): IP changed from $EXISTING_IP to $CURRENT_IP, updating rules..."
        else
            echo "$(date): No existing IP rules found, adding rules for $CURRENT_IP..."
        fi
        
        # Remove old rules
        if [ -n "$EXISTING_IP" ]; then
            SHARED_MARK=20
            # Try to find subnet from existing rules
            EXISTING_SUBNET=$(iptables -t mangle -L FORWARD -n 2>/dev/null | grep "$EXISTING_IP" | grep -oE "192\.168\.[0-9]+\.[0-9]+/[0-9]+" | head -1)
            if [ -z "$EXISTING_SUBNET" ]; then
                EXISTING_SUBNET="$CURRENT_SUBNET"
            fi
            
            if [ -n "$EXISTING_SUBNET" ]; then
                iptables -t mangle -D FORWARD -s "$EXISTING_IP" ! -d "$EXISTING_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$EXISTING_IP" ! -d "$EXISTING_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            else
                iptables -t mangle -D FORWARD -s "$EXISTING_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$EXISTING_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            fi
        fi
        
        # Add new rules with current IP
        SHARED_MARK=20
        if [ -n "$CURRENT_SUBNET" ]; then
            iptables -t mangle -C FORWARD -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || \
                iptables -t mangle -A FORWARD -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK}
            iptables -t mangle -C POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || \
                iptables -t mangle -A POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" ! -d "$CURRENT_SUBNET" -j MARK --set-mark ${SHARED_MARK}
        else
            iptables -t mangle -C FORWARD -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || \
                iptables -t mangle -A FORWARD -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK}
            iptables -t mangle -C POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || \
                iptables -t mangle -A POSTROUTING -o "$EGRESS_IFACE" -s "$CURRENT_IP" -j MARK --set-mark ${SHARED_MARK}
        fi
        
        echo "$(date): Successfully updated IP-based rules to $CURRENT_IP"
        ;;
    stop)
        echo -e "${YELLOW}Removing bandwidth limiting...${NC}"
        
        # Remove cronjob if it exists
        CRON_ID=$(echo "$COMPOSE_FILE" | md5sum | cut -d' ' -f1 | head -c 8)
        CRON_TAG="limit-bandwidth-${CRON_ID}"
        if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
            echo -e "${BLUE}  Removing cronjob...${NC}"
            (crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true) | crontab -
            echo -e "${GREEN}✓ Cronjob removed${NC}"
        fi
        
        # Get container IP for cleanup (if IP-based limiting was used)
        # Try to find IP from existing iptables rules first
        EXISTING_IP=$(iptables -t mangle -L FORWARD -n 2>/dev/null | grep "MARK set 0x14" | grep -oE "192\.168\.[0-9]+\.[0-9]+" | head -1)
        
        CONTAINER_IP_CLEANUP=""
        NETWORK_SUBNET_CLEANUP=""
        if [ -z "$EXISTING_IP" ]; then
            # Fallback: try to get from container
            NETWORK_INFO=$(get_container_network_info 2>/dev/null)
            if [ -n "$NETWORK_INFO" ]; then
                CONTAINER_IP_CLEANUP=$(echo "$NETWORK_INFO" | cut -d'|' -f1)
                NETWORK_SUBNET_CLEANUP=$(echo "$NETWORK_INFO" | cut -d'|' -f2)
            fi
        else
            CONTAINER_IP_CLEANUP="$EXISTING_IP"
            # Try to get subnet from existing rules
            EXISTING_SUBNET=$(iptables -t mangle -L FORWARD -n 2>/dev/null | grep "MARK set 0x14" | grep -oE "192\.168\.[0-9]+\.[0-9]+/[0-9]+" | head -1)
            if [ -n "$EXISTING_SUBNET" ]; then
                NETWORK_SUBNET_CLEANUP="$EXISTING_SUBNET"
            fi
        fi
        
        # Remove IP-based iptables rules if they exist
        if [ -n "$CONTAINER_IP_CLEANUP" ]; then
            echo -e "${BLUE}  Removing IP-based limits for ${CONTAINER_IP_CLEANUP}...${NC}"
            SHARED_MARK=20
            if [ -n "$NETWORK_SUBNET_CLEANUP" ]; then
                iptables -t mangle -D FORWARD -s "$CONTAINER_IP_CLEANUP" ! -d "$NETWORK_SUBNET_CLEANUP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$CONTAINER_IP_CLEANUP" ! -d "$NETWORK_SUBNET_CLEANUP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            else
                iptables -t mangle -D FORWARD -s "$CONTAINER_IP_CLEANUP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -s "$CONTAINER_IP_CLEANUP" -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            fi
        fi
        
        # Remove iptables rules for each port
        # Check if we need to remove shared class (20) or individual classes (10+)
        if tc class show dev "$EGRESS_IFACE" 2>/dev/null | grep -q "classid 1:20"; then
            # Shared class mode - all ports use mark 20
            SHARED_MARK=20
            for port in "${PORTS[@]}"; do
                echo -e "${BLUE}  Removing limits for port ${port}...${NC}"
                iptables -t mangle -D OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D OUTPUT -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D FORWARD -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D FORWARD -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK --set-mark ${SHARED_MARK} 2>/dev/null || true
            done
        else
            # Per-port mode - each port has its own mark
            PORT_ID=10
            for port in "${PORTS[@]}"; do
                echo -e "${BLUE}  Removing limits for port ${port}...${NC}"
                
                # Remove OUTPUT rules (outgoing from host)
                iptables -t mangle -D OUTPUT -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
                iptables -t mangle -D OUTPUT -p udp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
                
                # Remove FORWARD rules (outgoing from containers)
                iptables -t mangle -D FORWARD -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
                iptables -t mangle -D FORWARD -p udp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
                
                # Remove POSTROUTING rules
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p tcp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
                iptables -t mangle -D POSTROUTING -o "$EGRESS_IFACE" -p udp --sport ${port} -j MARK --set-mark ${PORT_ID} 2>/dev/null || true
                
                PORT_ID=$((PORT_ID + 1))
            done
        fi
        
        # Remove tc qdisc from both interfaces
        tc qdisc del dev "$BRIDGE" root 2>/dev/null || true
        tc qdisc del dev "$EGRESS_IFACE" root 2>/dev/null || true
        
        echo -e "${GREEN}✓ Bandwidth limiting removed${NC}"
        ;;
    status)
        echo -e "${YELLOW}Current bandwidth limiting status:${NC}"
        echo ""
        echo -e "${BLUE}TC Qdisc on ${EGRESS_IFACE} (egress interface):${NC}"
        tc qdisc show dev "$EGRESS_IFACE" 2>/dev/null || echo "  No qdisc configured"
        echo ""
        echo -e "${BLUE}TC Classes on ${EGRESS_IFACE}:${NC}"
        tc class show dev "$EGRESS_IFACE" 2>/dev/null || echo "  No classes configured"
        echo ""
        echo -e "${BLUE}TC Statistics on ${EGRESS_IFACE}:${NC}"
        tc -s class show dev "$EGRESS_IFACE" 2>/dev/null | head -20 || echo "  No statistics available"
        echo ""
        echo -e "${BLUE}Iptables rules (OUTPUT - outgoing from host):${NC}"
        iptables -t mangle -L OUTPUT -n --line-numbers | grep -E "MARK|${PORTS[0]}" || echo "  No rules found"
        echo ""
        echo -e "${BLUE}Iptables rules (FORWARD - outgoing from containers):${NC}"
        iptables -t mangle -L FORWARD -n --line-numbers | grep -E "MARK|${PORTS[0]}" || echo "  No rules found"
        echo ""
        echo -e "${BLUE}Iptables rules (POSTROUTING - after NAT):${NC}"
        iptables -t mangle -L POSTROUTING -n --line-numbers | grep -E "MARK|${PORTS[0]}" || echo "  No rules found"
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
