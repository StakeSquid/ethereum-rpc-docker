#!/bin/bash

./check-disk-space.sh
./show-status.sh | grep -v "online"
