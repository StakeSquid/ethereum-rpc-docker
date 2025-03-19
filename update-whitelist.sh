#!/bin/bash

DIRTY_IPS=$(/usr/bin/docker exec -t wireguard curl 10.13.13.1:5000/storage |  jq -r '[.[].ip]|join(",")' | sed 's/\n//g')

IPS=$(echo "$DIRTY_IPS" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | paste -sd "," -)

if [ -z "$IPS" ]; then
  echo "whitelist empty"
else
  sed -i.bak "s/WHITELIST=.*/WHITELIST=${IPS},192\.168\.0\.0\/16/g" /root/rpc/.env
  cd /root/rpc && docker compose up -d traefik
fi
