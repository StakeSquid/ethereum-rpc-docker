#!/bin/bash

BASEPATH="$(dirname "$0")"

$BASEPATH/show-db-size.sh
echo ""

$BASEPATH/show-status.sh
echo ""

$BASEPATH/show-errors.sh
