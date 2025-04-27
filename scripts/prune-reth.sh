#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error when substituting.

DATA_DIR="${DATA_DIR:-/data}"
STATIC_FILES_DIR="${STATIC_FILES_DIR:-/data/static_files}"
DELETE_DIR="${DELETE_DIR:-/data/static_files/delete_me}"

echo "Starting Reth pruning process for static files in $STATIC_FILES_DIR..."

mkdir -p "$DELETE_DIR"

# Step 1: List base filenames (without .conf/.off) and sort by starting block number
# Find files, remove extensions, sort uniquely, extract block number for numeric sort, then get original base name
echo "Finding and sorting static files..."
base_files=$(find "$STATIC_FILES_DIR" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.off' -o -name '*[0-9]' \) | \
             sed -E "s/\.(conf|off)$//" | \
             sort -u | \
             awk -F_ '{print $NF+0, $0}' | \
             sort -n | \
             cut -d" " -f2-)

if [ -z "$base_files" ]; then
    echo "No static files found to process."
    exit 0
fi

# Convert base_files to an array for easier manipulation
readarray -t base_files_array <<< "$base_files"
echo "Found ${#base_files_array[@]} unique base file ranges."

# Step 3: Group files by prefix and block range, keeping only the last two block ranges
declare -A file_groups

# Group files by prefix
echo "Grouping files by prefix..."
for base in "${base_files_array[@]}"; do
  prefix=$(echo "$base" | sed -E "s/_([0-9]+)$//")  # Get everything before the block range
  block_range=$(echo "$base" | sed -E "s/.*_([0-9]+)$//")  # Get the block range
  file_groups["$prefix"]+="$block_range:$base "
done

# Step 4: Process each group
echo "Processing file groups to identify files for removal..."
moved_count=0
for prefix in "${!file_groups[@]}"; do
  # Read ranges into an array, sorting numerically by block range (the part before ':')
  readarray -t block_ranges < <(echo "${file_groups[$prefix]}" | tr ' ' '\n' | sort -t: -k1,1n)

  num_files=${#block_ranges[@]}
  echo "Processing group '$prefix' with $num_files ranges."

  # Keep the last 2 block ranges (or fewer if less than 2 exist)
  keep_count=2
  if [ "$num_files" -le "$keep_count" ]; then
      echo "Keeping all files for group '$prefix' as there are $num_files ranges (<= $keep_count)."
      continue
  fi

  num_to_move=$((num_files - keep_count))
  echo "Identified $num_to_move ranges to move for group '$prefix'."

  # Get the ranges to move (all except the last 'keep_count')
  files_to_move=("${block_ranges[@]:0:$num_to_move}")

  # Move files for the current group
  for file_range in "${files_to_move[@]}"; do
    base="${file_range#*:}"  # Remove block range part, keeping the full filename path

    # Handle files with extensions .conf and .off first
    for ext in .conf .off; do
      file="${base}${ext}"
      if [[ -f "$file" ]]; then
        echo "Moving $file to $DELETE_DIR"
        mv "$file" "$DELETE_DIR/"
        moved_count=$((moved_count + 1))
      fi
    done

    # Handle base file (no extension) - check if it exists and is a file
    if [[ -f "$base" && ! "$base" =~ \.(conf|off)$ ]]; then
       echo "Moving $base to $DELETE_DIR"
       mv "$base" "$DELETE_DIR/"
       moved_count=$((moved_count + 1))
    fi
  done
done

if [ "$moved_count" -eq 0 ]; then
    echo "No files needed moving based on the retention policy."
else
    echo "Moved $moved_count files to $DELETE_DIR."
    freed_bytes=$(du -cb "$DELETE_DIR"/* | tail -1 | awk '{print $1}')
    echo "Total space potentially freed (before deletion): $freed_bytes bytes."
fi

# Optional: Add command to actually delete files in DELETE_DIR if desired
# echo "Deleting files in $DELETE_DIR..."
# rm -rf "$DELETE_DIR"/*

echo "Pruning script finished." 