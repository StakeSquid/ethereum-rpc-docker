#!/bin/bash

curl -sI $1 | awk '/[Cc]ontent-[Ll]ength/ {gsub(/\r/,""); size=$2; if (size >= 1073741824) printf "%.2f GB\n", size/1073741824; else if (size >= 1048576) printf "%.2f MB\n", size/1048576; else if (size >= 1024) printf "%.2f KB\n", size/1024; else printf "%d B\n", size}'
