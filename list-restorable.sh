#!/bin/bash
# List which compose files can be restored from local backups
# This script checks the compose_registry.json and verifies that all required
# backup files exist in /backup/
#
# Usage:
#   ./list-restorable.sh          # Show only compose files with all backups available
#   ./list-restorable.sh --all    # Show all compose files, including those with missing backups
#   ./list-restorable.sh -a       # Same as --all

dir="$(dirname "$0")"
registry_file="${dir}/compose_registry.json"
backup_dir="/backup"

if [ ! -f "$registry_file" ]; then
    echo "Error: compose_registry.json not found at $registry_file"
    exit 1
fi

if [ ! -d "$backup_dir" ]; then
    echo "Error: /backup directory does not exist"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed"
    exit 1
fi

# Count total entries
total_entries=$(jq 'length' "$registry_file")
echo "Checking $total_entries compose files for restorable backups..."
echo ""

# Use temporary files to collect results (since variables in subshells don't persist)
restorable_list=$(mktemp)
missing_list=$(mktemp)
trap "rm -f $restorable_list $missing_list" EXIT

# Process each entry in the registry
# Use process substitution to avoid subshell issues
while IFS= read -r entry; do
    compose_file=$(echo "$entry" | jq -r '.compose_file')
    volumes=$(echo "$entry" | jq -r '.volumes[]')
    
    # Check if compose file exists
    compose_path="${dir}/${compose_file}.yml"
    if [ ! -f "$compose_path" ]; then
        continue
    fi
    
    # Check each volume for backup file
    all_backups_exist=true
    missing_volumes=()
    backup_info=()
    
    while IFS= read -r volume; do
        volume_name="rpc_${volume}"
        # Look for backup files matching pattern: rpc_${volume}-[0-9]*G.tar.zst
        backup_file=$(ls -1 "$backup_dir"/"${volume_name}"-[0-9]*G.tar.zst 2>/dev/null | sort | tail -n 1)
        
        if [ -z "$backup_file" ]; then
            all_backups_exist=false
            missing_volumes+=("$volume_name")
        else
            # Extract size and date from filename (format: rpc_<volume>-<date>-<size>G.tar.zst)
            backup_basename=$(basename "$backup_file" .tar.zst)
            # Extract size (the part ending with G before .tar.zst)
            size=$(echo "$backup_basename" | grep -oE '[0-9]+G$' || echo "")
            
            # Try to extract date from filename (format: YYYY-MM-DD-HH-MM-SS)
            # Remove the volume name prefix, then remove the size suffix, what remains should be the date
            if [ -n "$size" ]; then
                # Remove volume prefix and size suffix
                date_candidate=$(echo "$backup_basename" | sed "s/^${volume_name}-//" | sed "s/-${size}$//")
                # Verify it matches the date pattern
                date_str=$(echo "$date_candidate" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}$' || echo "")
            else
                date_str=""
            fi
            
            # Calculate age from filename date or file modification time
            if [ -n "$date_str" ]; then
                # Convert date string to timestamp
                # Format: YYYY-MM-DD-HH-MM-SS -> YYYY-MM-DD HH:MM:SS
                date_formatted=$(echo "$date_str" | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1 \2:\3:\4/')
                # Try macOS date format first, then Linux
                backup_timestamp=$(date -j -f "%Y-%m-%d %H:%M:%S" "$date_formatted" +%s 2>/dev/null || \
                                   date -d "$date_formatted" +%s 2>/dev/null || echo "")
            fi
            
            # Fallback to file modification time if date parsing failed
            if [ -z "$backup_timestamp" ] || [ -z "$date_str" ]; then
                # Use file modification time (works on both macOS and Linux)
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    backup_timestamp=$(stat -f %m "$backup_file" 2>/dev/null || echo "")
                else
                    backup_timestamp=$(stat -c %Y "$backup_file" 2>/dev/null || echo "")
                fi
            fi
            
            # Calculate and format age
            if [ -n "$backup_timestamp" ]; then
                current_timestamp=$(date +%s)
                age_seconds=$((current_timestamp - backup_timestamp))
                
                # Format age
                if [ $age_seconds -lt 3600 ]; then
                    age_mins=$((age_seconds / 60))
                    age="${age_mins}m"
                elif [ $age_seconds -lt 86400 ]; then
                    age_hours=$((age_seconds / 3600))
                    age="${age_hours}h"
                elif [ $age_seconds -lt 604800 ]; then
                    age_days=$((age_seconds / 86400))
                    age="${age_days}d"
                else
                    age_weeks=$((age_seconds / 604800))
                    age="${age_weeks}w"
                fi
            else
                age="unknown"
            fi
            
            backup_info+=("${size:-unknown} (${age})")
        fi
    done <<< "$volumes"
    
    if [ "$all_backups_exist" = true ]; then
        # Format backup info for display
        info_str=$(IFS=", "; echo "${backup_info[*]}")
        echo "✓ $compose_file [${info_str}]"
        echo "$compose_file" >> "$restorable_list"
    else
        if [ "${1}" = "--all" ] || [ "${1}" = "-a" ]; then
            echo "✗ $compose_file (missing: ${missing_volumes[*]})"
            echo "$compose_file" >> "$missing_list"
        fi
    fi
done < <(jq -c '.[]' "$registry_file")

# Count results
restorable_count=$(wc -l < "$restorable_list" 2>/dev/null | tr -d ' ' || echo "0")
missing_count=$(wc -l < "$missing_list" 2>/dev/null | tr -d ' ' || echo "0")

echo ""
echo "Summary:"
echo "  Restorable: $restorable_count"
if [ "${1}" = "--all" ] || [ "${1}" = "-a" ]; then
    echo "  Missing backups: $missing_count"
fi
echo ""
echo "Use --all or -a flag to show compose files with missing backups"

