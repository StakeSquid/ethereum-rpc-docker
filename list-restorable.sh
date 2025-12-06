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
registry_file="${dir}/../compose_registry.json"
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
    
    while IFS= read -r volume; do
        volume_name="rpc_${volume}"
        # Look for backup files matching pattern: rpc_${volume}-[0-9]*G.tar.zst
        backup_file=$(ls -1 "$backup_dir"/"${volume_name}"-[0-9]*G.tar.zst 2>/dev/null | sort | tail -n 1)
        
        if [ -z "$backup_file" ]; then
            all_backups_exist=false
            missing_volumes+=("$volume_name")
        fi
    done <<< "$volumes"
    
    if [ "$all_backups_exist" = true ]; then
        echo "✓ $compose_file"
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

