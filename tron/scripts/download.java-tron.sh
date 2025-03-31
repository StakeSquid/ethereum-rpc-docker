#!/bin/sh


https://snapshots.publicnode.com/tron-pruned-70904745.tar.lz4

#!/bin/bash

# Exit on error and show commands
set -ex

# Default snapshot URL
SNAPSHOT_URL=${SNAPSHOT_URL:-"https://snapshots.publicnode.com/tron-pruned-70904745.tar.lz4"}
OUTPUT_DIR=${OUTPUT_DIR:-"/java-tron/output-directory"}

# Verify required tools are available
if ! command -v wget &> /dev/null || ! command -v lz4 &> /dev/null || ! command -v tar &> /dev/null; then
  echo "Installing required tools..."
  apk add --no-cache wget tar lz4
fi

# Create and prepare output directory
echo "Preparing output directory: ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}"/*

# Download and extract the snapshot
echo "Downloading Tron snapshot from ${SNAPSHOT_URL}"
wget -q --show-progress -c "${SNAPSHOT_URL}" -O - | \
  lz4 -d | \
  tar -xvf - -C "${OUTPUT_DIR}"

# Verify extraction
if [ -n "$(ls -A ${OUTPUT_DIR})" ]; then
  echo "Snapshot successfully downloaded and extracted to ${OUTPUT_DIR}"
else
  echo "Error: Extraction failed - output directory is empty"
  exit 1
fi
