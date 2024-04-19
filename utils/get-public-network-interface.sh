#!/bin/bash


ip addr | awk -v ip="$(curl -s ipinfo.io/ip)" '$1 == "inet" && $2 ~ "^" ip "/" {print $NF}'
