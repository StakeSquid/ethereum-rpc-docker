#!/bin/bash

dir="$(dirname "$0")"

$dir/check-disk-space.sh
$dir/show-status.sh | grep -v "online" || true
