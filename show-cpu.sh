#!/bin/bash

 awk '/MHz/ {sum+=$4; count++} END {print sum/count " MHz"}' /proc/cpuinfo
