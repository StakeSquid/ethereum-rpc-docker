#!/bin/bash

ip="$(curl -s ipinfo.io/ip)"
interface="$(ip addr | awk -v ip="$ip" '$1 == "inet" && $2 ~ "^" ip "/" {print $NF}')"

TMPFILE=$(mktemp)

timeout 10 tcpdump -i $interface "port ${1:-3042}" -n -q 2> /dev/null | awk '{print $3}' | cut -d '.' -f1-4 | grep -v "$ip" > $TMPFILE
RESULT=$(cat $TMPFILE | sort -u | grep -v '^$')

rm "$TMPFILE"

echo "$RESULT"
