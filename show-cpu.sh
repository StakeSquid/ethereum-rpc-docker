#!/bin/bash

# awk '/MHz/ {sum+=$4; count++} END {print sum/count " MHz"}' /proc/cpuinfo
awk '/MHz/ {freq[NR]=$4; sum+=$4; count++} END {asort(freq); print "Min:", freq[1], "MHz\nMax:", freq[count], "MHz\nAvg:", sum/count, "MHz"}' /proc/cpuinfo