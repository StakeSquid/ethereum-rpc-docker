#!/bin/bash

cd /root/rpc
sed -i.bak "s/IP=.*/IP=$(curl --ipv4 ipinfo.io/ip)/g" .env
docker compose up -d
