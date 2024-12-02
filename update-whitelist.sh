#!/bin/bash                                                                                                                                                                                                           

IPS=$(/usr/bin/docker exec -t wireguard curl 10.13.13.1:5000/storage |  jq -r '[.[].ip]|join(",")' | sed 's/\n//g')

cleaned_ips=$(echo "$IPS" | sed -E 's/[^0-9.,]//g' | sed 's/,,*/,/g' | sed 's/,$//')

if [ -z "$cleaned_ips" ]; then
  echo "whitelist empty"
else
  sed -i.bak "s/WHITELIST=.*/WHITELIST=${cleaned_ips},192\.168\.0\.0\/16/g" /root/rpc/.env
  cd /root/rpc && docker compose up -d traefik
fi
