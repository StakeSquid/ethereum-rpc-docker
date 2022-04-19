#!/bin/bash

# $1 = Virtual Service IP (VIP)
# $2 = Virtual Service Port (VPT)
# $3 = Real Server IP (RIP)
# $4 = Real Server Port (RPT)
# $5 = Check Source IP

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VIP=$1
VPT=$2
RIP=$3
RPT=$4
# RPT=8545

# Run curl with appropriate options
our_blockheight=$(curl -s -X POST -H "Content-Type: application/json" -m 2 -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params": [],"id":1}' https://$HAPROXY_SERVER_NAME:$RPT/$HAPROXY_PROXY_NAME 2>/dev/null | printf "%d" $(jq '.result' -r))
pokt_blockheight=$(curl -s -X POST -H "Content-Type: application/json" -m 2 -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params": [],"id":1}' https://poly-rpc.gateway.pokt.network 2>/dev/null | printf "%d" $(jq '.result' -r))

peers=$(curl -s -X POST -H "Content-Type: application/json" -m 2 -d '{"jsonrpc":"2.0","method":"net_peerCount","params": [],"id":1}' https://$HAPROXY_SERVER_NAME:$RPT/$HAPROXY_PROXY_NAME 2>/dev/null | jq '.result' -r)

# If any of the above tests failed, then exit 1.
if [[ "$our_blockheight" -lt "$pokt_blockheight - 10" ]]; then exit 1; fi
if [[ `printf "%d" $peers` == "0" || `printf "%d" $peers` == "1" ]]; then exit 1; fi
exit 0