#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error when substituting.

DATA_DIR="${DATA_DIR:-/data}"
STATIC_FILES_DIR="${STATIC_FILES_DIR:-$DATA_DIR/static_files}"
DELETE_DIR="${DELETE_DIR:-$DATA_DIR/static_files/delete_me}"

echo "Starting Reth pruning process for static files in $STATIC_FILES_DIR..."

mkdir -p "$DELETE_DIR"

# Step 1: Find all unique base filenames (static_file_{group}_{start}_{end})
echo "Finding unique static file base names..."
# Use find to get all relevant files, strip extensions, sort uniquely
# Ensure the base name includes the full path for mv later
unique_base_files=$(find "$STATIC_FILES_DIR" -maxdepth 1 -type f -name 'static_file_*_*_*' | \
                    sed -E 's/\.(conf|off)$//' | \
                    sort -u)

if [ -z "$unique_base_files" ]; then
    echo "No static files found matching the pattern 'static_file_*_*_*'."
    exit 0
fi

# Convert to array
readarray -t unique_base_files_array <<< "$unique_base_files"
echo "Found ${#unique_base_files_array[@]} unique base file ranges across all groups."

# Step 2: Group files by group_name (headers, receipts, transactions)
declare -A groups
echo "Grouping files by type (headers, receipts, transactions)..."
for base in "${unique_base_files_array[@]}"; do
    filename=$(basename "$base") # Get just the filename part
    # Extract group name assuming format static_file_{group_name}_{startblock}_{endblock}
    group_name=$(echo "$filename" | cut -d_ -f3)

    # Store the full path base name, grouped by the extracted group name
    if [[ "$group_name" == "headers" || "$group_name" == "receipts" || "$group_name" == "transactions" ]]; then
        groups["$group_name"]+="$base " # Append base path with a space separator
    else
        echo "Warning: Skipping file with unexpected group name: $base"
    fi
done

# Step 3: Process each group according to retention rules
moved_count=0
# Define the expected groups
declare -a group_names=("headers" "receipts" "transactions")

echo "Processing file groups..."
for group_name in "${group_names[@]}"; do
    # Get the space-separated list of base paths for the current group, default to empty string if group doesn't exist
    group_bases_str="${groups[$group_name]:-}"

    if [ -z "$group_bases_str" ]; then
        echo "No files found for group '$group_name'."
        echo "--- Finished processing group '$group_name' ---"
        continue
    fi

    # Sort base names within the group numerically by start block
    # Use process substitution, awk for extraction/sorting, and readarray
    readarray -t sorted_bases < <( \
        echo "$group_bases_str" | tr ' ' '\n' | \
        awk -F_ '{
            # Extract filename from full path if necessary
            split($0, path_parts, "/");
            filename = path_parts[length(path_parts)];
            # Split filename by underscore and get the start block (4th field)
            split(filename, name_parts, "_");
            start_block = name_parts[4];
            # Print start block (as number) and the original full base path
            print start_block+0, $0
        }' | \
        sort -n | \
        cut -d' ' -f2- \
    )

    num_files=${#sorted_bases[@]}
    echo "Processing group '$group_name' with $num_files ranges."

    # Use an associative array to track which base paths to keep (for efficient lookup)
    declare -A files_to_keep
    # Use a standard array to store base paths to move
    files_to_move=()

    # --- Apply Retention Rules ---
    # Rule 1: Always keep the _0_499999 range if it exists
    first_range_kept=false
    for base in "${sorted_bases[@]}"; do
        filename=$(basename "$base")
        if [[ "$filename" == *"_0_499999" ]]; then
            # Check if the key for this base path is already set in files_to_keep
            # Use parameter expansion ${key+x} for safe check with set -u (Bash 4.0+)
            if [[ -z "${files_to_keep[$base]+x}" ]]; then
                 echo "Marking first range '$filename' to keep for group '$group_name'."
                 files_to_keep["$base"]=1 # Mark this base path for keeping
                 first_range_kept=true
            fi
             # Don't break here; let it potentially be kept by Rule 2 as well if it's one of the last two
        fi
    done
    # Add a warning if the expected first range wasn't found (and there were files)
    if ! $first_range_kept && [[ $num_files -gt 0 ]]; then
         echo "Warning: Did not find the expected first range (_0_499999) for group '$group_name'."
    fi

    # Rule 2: Keep the last two ranges (sorted by start block)
    keep_last_count=2
    # Determine how many to actually keep (can't keep 2 if only 0 or 1 exist)
    num_to_keep_last=$((num_files < keep_last_count ? num_files : keep_last_count))

    if [[ $num_to_keep_last -gt 0 ]]; then
        echo "Marking last $num_to_keep_last range(s) to keep for group '$group_name':"
        # Calculate the starting index for the last 'num_to_keep_last' elements
        start_index=$((num_files - num_to_keep_last))
        # Loop through the indices of the ranges to keep
        for (( i=start_index; i<num_files; i++ )); do
            base="${sorted_bases[$i]}" # Get the base path from the sorted array
            filename=$(basename "$base")
            # Mark for keeping only if it hasn't been marked already (e.g., by Rule 1)
            # Use parameter expansion ${key+x} for safe check with set -u (Bash 4.0+)
            if [[ -z "${files_to_keep[$base]+x}" ]]; then
                echo " - $filename"
                files_to_keep["$base"]=1 # Mark this base path for keeping
            else
                # Already marked (likely the first range was also one of the last two)
                echo " - $filename (already marked to keep)"
            fi
        done
    fi

    echo "Total unique ranges marked to keep for group '$group_name': ${#files_to_keep[@]}"

    # --- Identify and Move Files ---
    # Iterate through all sorted base paths for the group
    for base in "${sorted_bases[@]}"; do
        # If a base path is NOT marked to be kept (key doesn't exist in files_to_keep), move it
        # Use parameter expansion ${key+x} for safe check with set -u (Bash 4.0+)
        if [[ -z "${files_to_keep[$base]+x}" ]]; then
            files_to_move+=("$base") # Add base path to the list of files to move
        fi
    done

    num_to_move=${#files_to_move[@]}
    if [[ $num_to_move -gt 0 ]]; then
        echo "Identified $num_to_move ranges to move for group '$group_name'."

        # Move the files corresponding to the ranges marked for moving
        for base in "${files_to_move[@]}"; do
            filename=$(basename "$base") # For logging purposes

            # Attempt to move the base file (no extension) if it exists
            if [[ -f "$base" ]]; then
                echo "Moving $filename to $DELETE_DIR"
                mv "$base" "$DELETE_DIR/"
                moved_count=$((moved_count + 1))
            fi
            # Attempt to move the .conf and .off files if they exist
            for ext in .conf .off; do
                file="${base}${ext}"
                if [[ -f "$file" ]]; then
                    file_bn=$(basename "$file") # For logging
                    echo "Moving $file_bn to $DELETE_DIR"
                    mv "$file" "$DELETE_DIR/"
                    moved_count=$((moved_count + 1))
                fi
            done
        done
    else
        echo "No ranges need moving for group '$group_name'."
    fi
    echo "--- Finished processing group '$group_name' ---"

done # End of group processing loop

# Step 4: Final Summary
if [ "$moved_count" -eq 0 ]; then
    echo "No files needed moving based on the retention policy."
else
    echo "Moved $moved_count files to $DELETE_DIR."
    # Calculate space freed - use -s for summary, handle potential "total 0" output
    freed_bytes=$(du -sc "$DELETE_DIR"/* | grep total | awk '{print $1}')
    # Convert K/M/G from du output to bytes if necessary, or use -b for bytes directly if available and preferred
    # Using du -cb as in the original script is often more reliable for bytes:
    if [[ -d "$DELETE_DIR" && $(ls -A "$DELETE_DIR") ]]; then # Check if dir exists and is not empty
        freed_bytes=$(du -cb "$DELETE_DIR"/* | tail -1 | awk '{print $1}')
        echo "Total space potentially freed (before deletion): $freed_bytes bytes."
    else
        echo "Delete directory is empty, no space calculation needed."
    fi
fi

# Optional: Add command to actually delete files in DELETE_DIR if desired
# echo "Deleting files in $DELETE_DIR..."
# rm -rf "$DELETE_DIR"/*

echo "Pruning script finished." 