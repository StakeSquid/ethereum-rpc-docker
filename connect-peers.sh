#!/bin/bash

# Connect two blockchain nodes bidirectionally
# Adds each node as a static peer to the other
#
# Usage: connect-peers.sh <compose-file> <target-host> [target-compose-file] [options]
#   compose-file: Path to compose file (without .yml) for source node
#   target-host: Target host identifier (e.g., "2" for 2.stakesquid.eu)
#   target-compose-file: Optional. If provided, use this compose file for target node
#                        If not provided, use the same compose file for both source and target
#
# Exit codes:
#   0 - At least one node connected successfully (bidirectional or one-way)
#   1 - Failed to connect to both nodes (see output for details)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <compose-file> <target-host> [target-compose-file] [options]"
    echo ""
    echo "Connects two nodes by adding each other as static peers."
    echo ""
    echo "Arguments:"
    echo "  compose-file: Path to compose file (without .yml) for source node"
    echo "  target-host: Target host identifier (e.g., '2' for 2.stakesquid.eu)"
    echo "  target-compose-file: Optional. If provided, use this compose file for target node"
    echo ""
    echo "Examples:"
    echo "  $0 ethereum/geth/mainnet 2"
    echo "  $0 ethereum/geth/mainnet 2 polygon/bor/mainnet"
    echo "  $0 ethereum/geth/mainnet 2 --timeout 5"
    echo ""
    echo "Options:"
    echo "  --timeout, -t    RPC timeout in seconds (default: 5)"
    echo "  --dry-run, -n    Show what would be done without making changes"
    exit 1
}

if [[ $# -lt 2 ]]; then
    usage
fi

BASEPATH="$(dirname "$0")"
source "$BASEPATH/.env" 2>/dev/null || {
    echo -e "${RED}Error: Could not source $BASEPATH/.env${NC}" >&2
    exit 1
}

COMPOSE_FILE="$1"
TARGET_HOST="$2"
TARGET_COMPOSE_FILE="${3:-$COMPOSE_FILE}"  # Use source compose file if not provided

# Shift arguments - if 3rd arg exists and is not an option, it's the target compose file
if [[ $# -ge 3 ]] && [[ "$3" != --* ]]; then
    shift 3
else
    shift 2
fi

TIMEOUT=5
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout|-t)
            TIMEOUT="$2"
            shift 2
            ;;
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if DOMAIN is set
if [ -z "${DOMAIN:-}" ]; then
    echo -e "${RED}Error: DOMAIN variable not found in $BASEPATH/.env${NC}" >&2
    exit 1
fi

# Function to extract RPC path from compose file
extract_rpc_path() {
    local compose_path="$1"
    local full_path="$BASEPATH/${compose_path}.yml"
    
    if [ ! -f "$full_path" ]; then
        echo "Error: Compose file not found: $full_path" >&2
        return 1
    fi
    
    # Get all services from compose file
    services=$(cat "$full_path" | yaml2json - 2>/dev/null | jq -r '.services | keys | .[]' 2>/dev/null)
    
    if [ -z "$services" ]; then
        echo "Error: No services found in compose file: $full_path" >&2
        return 1
    fi
    
    # Find the first service with a stripprefix.prefixes label
    for service in $services; do
        labels=($(cat "$full_path" | yaml2json - 2>/dev/null | jq -r ".services[\"$service\"].labels[]?" 2>/dev/null))
        
        for label in "${labels[@]}"; do
            if [[ "$label" == *"stripprefix.prefixes"* ]]; then
                # Extract path from label
                # Format examples:
                #   prefixes=/plume-mainnet-archive
                #   prefixes=`/plume-mainnet-archive`
                #   prefixes="/plume-mainnet-archive"
                path=$(echo "$label" | sed -n 's/.*prefixes=\([^ `"]*\).*/\1/p')
                # Remove backticks and quotes if present
                path=$(echo "$path" | sed 's|`||g' | sed 's|"||g' | sed "s|'||g")
                # Ensure path starts with /
                if [[ ! "$path" =~ ^/ ]]; then
                    path="/$path"
                fi
                # Remove trailing slash if present
                path=$(echo "$path" | sed 's|/$||')
                if [ -n "$path" ] && [ "$path" != "/" ]; then
                    echo "$path"
                    return 0
                fi
            fi
        done
    done
    
    echo "Error: Could not extract RPC path from compose file: $full_path" >&2
    return 1
}

# Extract RPC paths
SOURCE_RPC_PATH=$(extract_rpc_path "$COMPOSE_FILE")
if [ $? -ne 0 ]; then
    exit 1
fi

TARGET_RPC_PATH=$(extract_rpc_path "$TARGET_COMPOSE_FILE")
if [ $? -ne 0 ]; then
    exit 1
fi

# Construct URLs
SOURCE_URL="https://${DOMAIN}${SOURCE_RPC_PATH}"
TARGET_URL="https://${TARGET_HOST}.stakesquid.eu${TARGET_RPC_PATH}"

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN}Node Peer Connector${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""
echo -e "Source compose:  ${YELLOW}${COMPOSE_FILE}${NC}"
echo -e "Target compose:  ${YELLOW}${TARGET_COMPOSE_FILE}${NC}"
echo -e "Target host:     ${YELLOW}${TARGET_HOST}.stakesquid.eu${NC}"
echo ""
echo -e "Source URL:      ${YELLOW}${SOURCE_URL}${NC}"
echo -e "Target URL:      ${YELLOW}${TARGET_URL}${NC}"
echo -e "Timeout:         ${YELLOW}${TIMEOUT}s${NC}"
if [[ "$DRY_RUN" == true ]]; then
    echo -e "Mode:            ${YELLOW}DRY RUN${NC}"
fi
echo ""

# Function to get node info
get_node_info() {
    local url="$1"
    local response
    
    response=$(curl --ipv4 -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' \
        --connect-timeout "$TIMEOUT" 2>/dev/null) || {
        echo ""
        return 1
    }
    
    echo "$response"
}

# Function to extract enode from nodeInfo response
extract_enode() {
    local response="$1"
    echo "$response" | grep -oP '"enode"\s*:\s*"\K[^"]+' | head -1
}

# Function to extract node name
extract_name() {
    local response="$1"
    echo "$response" | grep -oP '"name"\s*:\s*"\K[^"]+' | head -1
}

# Function to check if JSON-RPC response indicates success
check_rpc_success() {
    local response="$1"
    
    # Check if response contains "true" (successful result)
    if [[ "$response" =~ "true" ]]; then
        return 0
    fi
    
    # Check if response contains an error
    if [[ "$response" =~ "\"error\"" ]]; then
        return 1
    fi
    
    # Empty or unexpected response
    return 1
}

# Function to extract error message from JSON-RPC response
extract_error_message() {
    local response="$1"
    
    # Try to extract error message using grep
    local error_msg=$(echo "$response" | grep -oP '"message"\s*:\s*"\K[^"]+' | head -1)
    
    if [[ -n "$error_msg" ]]; then
        echo "$error_msg"
    else
        echo "Unknown error"
    fi
}

# Function to add static peer
add_static_peer() {
    local url="$1"
    local enode="$2"
    local response
    
    response=$(curl --ipv4 -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addStaticPeer\",\"params\":[\"$enode\"],\"id\":1}" \
        --connect-timeout "$TIMEOUT" 2>/dev/null) || {
        echo ""
        return 1
    }
    
    echo "$response"
}

# Function to check if already peers
check_already_peers() {
    local url="$1"
    local pubkey="$2"
    local response
    
    response=$(curl --ipv4 -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' \
        --connect-timeout "$TIMEOUT" 2>/dev/null) || {
        echo "error"
        return 1
    }
    
    if echo "$response" | grep -qi "$pubkey"; then
        echo "connected"
    else
        echo "not_connected"
    fi
}

# Get source node info
echo -e "${CYAN}--- Fetching Node Info ---${NC}"
echo ""
echo -n "Source node info... "

SOURCE_INFO=$(get_node_info "$SOURCE_URL")
if [[ -z "$SOURCE_INFO" ]] || [[ "$SOURCE_INFO" =~ "error" && ! "$SOURCE_INFO" =~ "result" ]]; then
    echo -e "${RED}FAILED${NC}"
    echo -e "${RED}Could not get nodeInfo from source. Is admin API enabled?${NC}"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

SOURCE_ENODE=$(extract_enode "$SOURCE_INFO")
SOURCE_NAME=$(extract_name "$SOURCE_INFO")
SOURCE_PUBKEY=$(echo "$SOURCE_ENODE" | sed -E 's|enode://([^@]+)@.*|\1|')

if [[ -z "$SOURCE_ENODE" ]]; then
    echo -e "${RED}Could not extract enode from source${NC}"
    exit 1
fi

echo -e "  Name:  ${GREEN}${SOURCE_NAME}${NC}"
echo -e "  Enode: ${GREEN}${SOURCE_ENODE:0:60}...${NC}"
echo ""

# Get target node info
echo -n "Target node info... "

TARGET_INFO=$(get_node_info "$TARGET_URL")
if [[ -z "$TARGET_INFO" ]] || [[ "$TARGET_INFO" =~ "error" && ! "$TARGET_INFO" =~ "result" ]]; then
    echo -e "${RED}FAILED${NC}"
    echo -e "${RED}Could not get nodeInfo from target. Is admin API enabled?${NC}"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

TARGET_ENODE=$(extract_enode "$TARGET_INFO")
TARGET_NAME=$(extract_name "$TARGET_INFO")
TARGET_PUBKEY=$(echo "$TARGET_ENODE" | sed -E 's|enode://([^@]+)@.*|\1|')

if [[ -z "$TARGET_ENODE" ]]; then
    echo -e "${RED}Could not extract enode from target${NC}"
    exit 1
fi

echo -e "  Name:  ${GREEN}${TARGET_NAME}${NC}"
echo -e "  Enode: ${GREEN}${TARGET_ENODE:0:60}...${NC}"
echo ""

# Check if same node
if [[ "$SOURCE_PUBKEY" == "$TARGET_PUBKEY" ]]; then
    echo -e "${RED}Error: Source and target are the same node!${NC}"
    exit 1
fi

# Check existing connections
echo -e "${CYAN}--- Checking Existing Connections ---${NC}"
echo ""

echo -n "Source -> Target: "
SOURCE_HAS_TARGET=$(check_already_peers "$SOURCE_URL" "$TARGET_PUBKEY")
if [[ "$SOURCE_HAS_TARGET" == "connected" ]]; then
    echo -e "${GREEN}already connected${NC}"
else
    echo -e "${YELLOW}not connected${NC}"
fi

echo -n "Target -> Source: "
TARGET_HAS_SOURCE=$(check_already_peers "$TARGET_URL" "$SOURCE_PUBKEY")
if [[ "$TARGET_HAS_SOURCE" == "connected" ]]; then
    echo -e "${GREEN}already connected${NC}"
else
    echo -e "${YELLOW}not connected${NC}"
fi
echo ""

# Add peers
echo -e "${CYAN}--- Adding Static Peers ---${NC}"
echo ""

SOURCE_SUCCESS=false
TARGET_SUCCESS=false
ERRORS=0

# Add target's enode to source
echo -n "Adding target to source... "
if [[ "$SOURCE_HAS_TARGET" == "connected" ]]; then
    echo -e "${YELLOW}skipped (already connected)${NC}"
    SOURCE_SUCCESS=true
elif [[ "$DRY_RUN" == true ]]; then
    echo -e "${CYAN}dry run${NC}"
    echo -e "  Would run: admin_addStaticPeer(\"${TARGET_ENODE:0:50}...\")"
    SOURCE_SUCCESS=true
else
    RESULT=$(add_static_peer "$SOURCE_URL" "$TARGET_ENODE")
    if check_rpc_success "$RESULT"; then
        echo -e "${GREEN}OK${NC}"
        SOURCE_SUCCESS=true
    else
        echo -e "${RED}FAILED${NC}"
        ERROR_MSG=$(extract_error_message "$RESULT")
        if [[ -n "$ERROR_MSG" ]]; then
            echo -e "  Error: ${ERROR_MSG}"
        fi
        if [[ -n "$RESULT" ]]; then
            echo -e "  Response: $RESULT"
        else
            echo -e "  No response from node (connection timeout or unreachable)"
        fi
        ((ERRORS++))
    fi
fi

# Add source's enode to target
echo -n "Adding source to target... "
if [[ "$TARGET_HAS_SOURCE" == "connected" ]]; then
    echo -e "${YELLOW}skipped (already connected)${NC}"
    TARGET_SUCCESS=true
elif [[ "$DRY_RUN" == true ]]; then
    echo -e "${CYAN}dry run${NC}"
    echo -e "  Would run: admin_addStaticPeer(\"${SOURCE_ENODE:0:50}...\")"
    TARGET_SUCCESS=true
else
    RESULT=$(add_static_peer "$TARGET_URL" "$SOURCE_ENODE")
    if check_rpc_success "$RESULT"; then
        echo -e "${GREEN}OK${NC}"
        TARGET_SUCCESS=true
    else
        echo -e "${RED}FAILED${NC}"
        ERROR_MSG=$(extract_error_message "$RESULT")
        if [[ -n "$ERROR_MSG" ]]; then
            echo -e "  Error: ${ERROR_MSG}"
        fi
        if [[ -n "$RESULT" ]]; then
            echo -e "  Response: $RESULT"
        else
            echo -e "  No response from node (connection timeout or unreachable)"
        fi
        ((ERRORS++))
    fi
fi

echo ""

# Verify connection (wait a moment for handshake)
if [[ "$DRY_RUN" == false ]] && [[ "$SOURCE_HAS_TARGET" != "connected" || "$TARGET_HAS_SOURCE" != "connected" ]]; then
    echo -e "${CYAN}--- Verifying Connection ---${NC}"
    echo ""
    echo -n "Waiting for handshake"
    for i in {1..5}; do
        echo -n "."
        sleep 1
    done
    echo ""
    echo ""
    
    echo -n "Source -> Target: "
    SOURCE_HAS_TARGET=$(check_already_peers "$SOURCE_URL" "$TARGET_PUBKEY")
    if [[ "$SOURCE_HAS_TARGET" == "connected" ]]; then
        echo -e "${GREEN}connected${NC}"
    else
        echo -e "${YELLOW}pending${NC}"
    fi
    
    echo -n "Target -> Source: "
    TARGET_HAS_SOURCE=$(check_already_peers "$TARGET_URL" "$SOURCE_PUBKEY")
    if [[ "$TARGET_HAS_SOURCE" == "connected" ]]; then
        echo -e "${GREEN}connected${NC}"
    else
        echo -e "${YELLOW}pending${NC}"
    fi
    echo ""
fi

# Summary
echo -e "${CYAN}--- Summary ---${NC}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${GREEN}Dry run completed - no changes made${NC}"
    echo ""
    exit 0
elif [[ "$SOURCE_SUCCESS" == true && "$TARGET_SUCCESS" == true ]]; then
    echo -e "${GREEN}Nodes connected successfully (bidirectional)${NC}"
    echo ""
    echo "Both nodes should now discover each other's peers via the"
    echo "devp2p discovery protocol. Give it a few minutes to propagate."
    echo ""
    exit 0
elif [[ "$SOURCE_SUCCESS" == true || "$TARGET_SUCCESS" == true ]]; then
    echo -e "${YELLOW}Partial success - peer added to one node${NC}"
    if [[ "$SOURCE_SUCCESS" == true ]]; then
        echo -e "  ${GREEN}✓${NC} Target peer added to source node"
    else
        echo -e "  ${RED}✗${NC} Failed to add target peer to source node"
    fi
    if [[ "$TARGET_SUCCESS" == true ]]; then
        echo -e "  ${GREEN}✓${NC} Source peer added to target node"
    else
        echo -e "  ${RED}✗${NC} Failed to add source peer to target node"
    fi
    echo ""
    echo "One-way connection established. The node that successfully added"
    echo "the peer should be able to connect. Retry later to establish"
    echo "bidirectional connection."
    echo ""
    exit 0
else
    echo -e "${RED}Connection failed - could not add peer to either node${NC}"
    echo ""
    exit 1
fi