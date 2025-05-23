#!/bin/bash

cd /root/rpc
sed -i.bak "s/IP=.*/IP=$(curl ipinfo.io/ip)/g" .env
docker compose up -d
