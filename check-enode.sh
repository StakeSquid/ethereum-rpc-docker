#!/bin/bash

# Enode connectivity checker
# Tests TCP and UDP connectivity for blockchain peer nodes

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <enode-url> [timeout]"
    echo ""
    echo "Examples:"
    echo "  $0 'enode://pubkey@192.168.1.1:30303'"
    echo "  $0 'enode://pubkey@192.168.1.1:30303?discport=30304'"
    echo "  $0 'enode://pubkey@192.168.1.1:30303' 5"
    echo ""
    echo "Options:"
    echo "  timeout    Connection timeout in seconds (default: 3)"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

ENODE="$1"
TIMEOUT="${2:-3}"

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
echo ""

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