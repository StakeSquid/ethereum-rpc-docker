#!/bin/bash

# Enode connectivity checker
# Tests TCP and UDP connectivity for blockchain peer nodes
#
# Exit codes:
#   0 - Peer is reachable and not already connected (safe to add)
#   1 - Peer is not reachable (TCP failed)
#   2 - Peer is already connected to target node

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <enode-url> [options]"
    echo ""
    echo "Examples:"
    echo "  $0 'enode://pubkey@192.168.1.1:30303'"
    echo "  $0 'enode://pubkey@192.168.1.1:30303' --timeout 5"
    echo "  $0 'enode://pubkey@192.168.1.1:30303' --target http://localhost:18545"
    echo "  $0 'enode://pubkey@192.168.1.1:30303' --target http://localhost:18545 --timeout 5"
    echo ""
    echo "Options:"
    echo "  --timeout, -t    Connection timeout in seconds (default: 3)"
    echo "  --target, -T     Target node RPC URL to check if peer is already connected"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

ENODE="$1"
shift

TIMEOUT=3
TARGET_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout|-t)
            TIMEOUT="$2"
            shift 2
            ;;
        --target|-T)
            TARGET_URL="$2"
            shift 2
            ;;
        *)
            # Legacy: if it's just a number, treat as timeout
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                TIMEOUT="$1"
                shift
            else
                echo "Unknown option: $1"
                usage
            fi
            ;;
    esac
done

# Validate enode format
if [[ ! "$ENODE" =~ ^enode:// ]]; then
    echo -e "${RED}Error: Invalid enode format. Must start with 'enode://'${NC}"
    exit 1
fi

# Extract components
# Format: enode://pubkey@ip:port or enode://pubkey@ip:port?discport=udpport
PUBKEY=$(echo "$ENODE" | sed -E 's|enode://([^@]+)@.*|\1|')
HOST_PART=$(echo "$ENODE" | sed -E 's|enode://[^@]+@([^?]+).*|\1|')
IP=$(echo "$HOST_PART" | sed -E 's|(.+):([0-9]+)$|\1|')
TCP_PORT=$(echo "$HOST_PART" | sed -E 's|.+:([0-9]+)$|\1|')

# Check for separate discovery port
if [[ "$ENODE" =~ discport=([0-9]+) ]]; then
    UDP_PORT="${BASH_REMATCH[1]}"
else
    UDP_PORT="$TCP_PORT"
fi

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN}Enode Connectivity Checker${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""
echo -e "Enode:     ${YELLOW}${ENODE:0:80}...${NC}"
echo -e "Pubkey:    ${YELLOW}${PUBKEY:0:16}...${PUBKEY: -8}${NC}"
echo -e "IP:        ${YELLOW}${IP}${NC}"
echo -e "TCP Port:  ${YELLOW}${TCP_PORT}${NC}"
echo -e "UDP Port:  ${YELLOW}${UDP_PORT}${NC}"
echo -e "Timeout:   ${YELLOW}${TIMEOUT}s${NC}"
if [[ -n "$TARGET_URL" ]]; then
    echo -e "Target:    ${YELLOW}${TARGET_URL}${NC}"
fi
echo ""

# Check if peer is already connected to target node
if [[ -n "$TARGET_URL" ]]; then
    echo -e "${CYAN}--- Target Node Check ---${NC}"
    echo ""
    
    echo -n "Querying target node peers... "
    
    PEERS_RESPONSE=$(curl -s -X POST "$TARGET_URL" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' \
        --connect-timeout "$TIMEOUT" 2>/dev/null || echo "")
    
    if [[ -z "$PEERS_RESPONSE" ]]; then
        echo -e "${RED}FAILED${NC}"
        echo -e "${YELLOW}Warning: Could not query target node (connection failed or admin API disabled)${NC}"
        echo ""
    elif [[ "$PEERS_RESPONSE" =~ "error" ]] && [[ ! "$PEERS_RESPONSE" =~ "result" ]]; then
        echo -e "${RED}ERROR${NC}"
        ERROR_MSG=$(echo "$PEERS_RESPONSE" | grep -oP '"message"\s*:\s*"\K[^"]+' || echo "unknown error")
        echo -e "${YELLOW}Warning: admin_peers failed: ${ERROR_MSG}${NC}"
        echo ""
    else
        echo -e "${GREEN}OK${NC}"
        
        # Check if pubkey is already in peers list
        # The enode pubkey appears in the peer's enode field
        if echo "$PEERS_RESPONSE" | grep -qi "$PUBKEY"; then
            echo -e "${YELLOW}⚠ ALREADY CONNECTED: Peer pubkey found in target's peer list${NC}"
            echo ""
            echo -e "${RED}Skip adding this peer - it will cause 'already connected' error${NC}"
            echo ""
            exit 2
        fi
        
        # Also check by IP in case pubkey changed but same host
        if echo "$PEERS_RESPONSE" | grep -qi "\"$IP\""; then
            echo -e "${YELLOW}⚠ WARNING: Target already has a peer from IP ${IP}${NC}"
            echo -e "  This might be the same node with a different pubkey"
            echo ""
        else
            echo -e "${GREEN}✓ Peer not currently connected to target${NC}"
        fi
        
        # Show current peer count
        PEER_COUNT=$(echo "$PEERS_RESPONSE" | grep -oP '"enode"' | wc -l || echo "0")
        echo -e "  Target has ${CYAN}${PEER_COUNT}${NC} current peers"
        echo ""
    fi
fi

# Check if IP is valid
if [[ ! "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$IP" =~ : ]]; then
    # Might be a hostname, try to resolve
    echo -e "${YELLOW}Resolving hostname...${NC}"
    RESOLVED_IP=$(dig +short "$IP" | head -1 || echo "")
    if [[ -n "$RESOLVED_IP" ]]; then
        echo -e "Resolved:  ${GREEN}${RESOLVED_IP}${NC}"
        IP="$RESOLVED_IP"
    else
        echo -e "${RED}Warning: Could not resolve hostname${NC}"
    fi
fi

echo -e "${CYAN}--- Connectivity Tests ---${NC}"
echo ""

# TCP test
echo -n "TCP ${IP}:${TCP_PORT} ... "
if timeout "$TIMEOUT" bash -c "echo >/dev/tcp/${IP}/${TCP_PORT}" 2>/dev/null; then
    echo -e "${GREEN}OPEN${NC}"
    TCP_OK=true
else
    echo -e "${RED}CLOSED/FILTERED${NC}"
    TCP_OK=false
fi

# UDP test using nc if available
echo -n "UDP ${IP}:${UDP_PORT} ... "
if command -v nc &>/dev/null; then
    # Send empty UDP packet and check for response or ICMP unreachable
    if timeout "$TIMEOUT" nc -zu "$IP" "$UDP_PORT" 2>/dev/null; then
        echo -e "${GREEN}OPEN/FILTERED${NC} (no ICMP unreachable)"
        UDP_OK=true
    else
        echo -e "${YELLOW}FILTERED/CLOSED${NC}"
        UDP_OK=false
    fi
elif command -v nmap &>/dev/null; then
    UDP_RESULT=$(nmap -sU -p "$UDP_PORT" "$IP" 2>/dev/null | grep -E "^${UDP_PORT}" || echo "")
    if [[ "$UDP_RESULT" =~ open ]]; then
        echo -e "${GREEN}OPEN${NC}"
        UDP_OK=true
    else
        echo -e "${YELLOW}${UDP_RESULT:-UNKNOWN}${NC}"
        UDP_OK=false
    fi
else
    echo -e "${YELLOW}SKIPPED${NC} (nc/nmap not found)"
    UDP_OK="unknown"
fi

# Ping test
echo -n "ICMP ping ... "
if ping -c 1 -W "$TIMEOUT" "$IP" &>/dev/null; then
    PING_MS=$(ping -c 1 -W "$TIMEOUT" "$IP" 2>/dev/null | grep -oP 'time=\K[0-9.]+' || echo "?")
    echo -e "${GREEN}OK${NC} (${PING_MS}ms)"
    PING_OK=true
else
    echo -e "${YELLOW}BLOCKED/TIMEOUT${NC}"
    PING_OK=false
fi

# Reverse DNS
echo -n "Reverse DNS ... "
RDNS=$(dig +short -x "$IP" 2>/dev/null | head -1 || echo "")
if [[ -n "$RDNS" ]]; then
    echo -e "${GREEN}${RDNS}${NC}"
else
    echo -e "${YELLOW}none${NC}"
fi

echo ""
echo -e "${CYAN}--- Summary ---${NC}"
echo ""

if [[ "$TCP_OK" == true ]]; then
    echo -e "${GREEN}✓ TCP port is reachable - RLPx transport should work${NC}"
else
    echo -e "${RED}✗ TCP port blocked - peer connection will fail${NC}"
fi

if [[ "$UDP_OK" == true ]]; then
    echo -e "${GREEN}✓ UDP port appears open - discovery protocol should work${NC}"
elif [[ "$UDP_OK" == "unknown" ]]; then
    echo -e "${YELLOW}? UDP port status unknown${NC}"
else
    echo -e "${YELLOW}! UDP port may be filtered - discovery might not work${NC}"
    echo -e "  (Note: UDP is harder to test, connection may still work)"
fi

echo ""

# Final recommendation
if [[ "$TCP_OK" == true ]]; then
    echo -e "${GREEN}Peer looks viable for static-nodes or admin.addPeer()${NC}"
    echo ""
    echo "Add via console:"
    echo -e "  ${CYAN}admin.addPeer(\"${ENODE}\")${NC}"
    echo ""
    echo "Or add to static-nodes.json:"
    echo -e "  ${CYAN}\"${ENODE}\"${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}Peer is not reachable - do not add${NC}"
    echo ""
    echo "Possible reasons:"
    echo "  - Peer node is down"
    echo "  - Firewall blocking the port"
    echo "  - IP address changed (stale enode)"
    echo "  - Your outbound traffic is filtered"
    echo ""
    exit 1
fi