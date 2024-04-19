#!/bin/bash

ip="$(curl -s ipinfo.io/ip)"
interface="$(ip addr | awk -v ip="$ip" '$1 == "inet" && $2 ~ "^" ip "/" {print $NF}')"

pktstat -n -i $interface port ${1:-3042}
