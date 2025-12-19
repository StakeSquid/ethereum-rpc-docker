#!/bin/bash

BASEPATH="$(dirname "$0")"
backup_dir="/backup"

if [[ -n $2 ]]; then
    echo "upload backup via webdav to $2"
else
    if [ ! -d "$backup_dir" ]; then
	echo "Error: /backup directory does not exist"
	exit 1
    fi
fi

# Function to generate metadata for a single volume
generate_volume_metadata() {
    local volume_key=$1
    local source_folder=$2
    local metadata_file=$3
    
    prefix="/var/lib/docker/volumes/rpc_$volume_key"
    static_file_list="$BASEPATH/static-file-path-list.txt"
    
    # Initialize metadata file
    echo "Static file paths and sizes for volume: rpc_$volume_key" > "$metadata_file"
    echo "Generated: $(date)" >> "$metadata_file"
    echo "" >> "$metadata_file"
    
    # Check each static file path
    if [[ -f "$static_file_list" ]]; then
        while IFS= read -r path; do
            # Check if the path exists
            if [[ -e "$prefix/_data/$path" ]]; then
                # Get the size
                size=$(du -sL "$prefix/_data/$path" 2>/dev/null | awk '{print $1}')
                # Format size in human-readable format
                size_formatted=$(echo "$(( size * 1024 ))" | numfmt --to=iec --suffix=B --format="%.2f")
                # Write to metadata file
                echo "$size_formatted  $path" >> "$metadata_file"
            fi
        done < "$static_file_list"
    fi
}

# Read the JSON input and extract the list of keys
keys=$(cat /root/rpc/$1.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

# Iterate over the list of keys
for key in $keys; do
    echo "Executing command with key: /var/lib/docker/volumes/rpc_$key/_data"

    source_folder="/var/lib/docker/volumes/rpc_$key/_data"
    folder_size=$(du -shL "$source_folder" | awk '{
     size = $1
     sub(/[Kk]$/, "", size)  # Remove 'K' suffix if present
     sub(/[Mm]$/, "", size)  # Remove 'M' suffix if present
     sub(/[Gg]$/, "", size)  # Remove 'G' suffix if present
     sub(/[Tt]$/, "", size)  # Remove 'T' suffix if present
     if ($1 ~ /[Kk]$/) {
         size *= 0.001   # Convert kilobytes to gigabytes
     } else if ($1 ~ /[Mm]$/) {
         size *= 0.001   # Convert megabytes to gigabytes
     } else if ($1 ~ /[Tt]$/) {
     	 size *= 1000 # convert terabytes to gigabytes
     }
     print size
    }')

    folder_size_gb=$(printf "%.0f" "$folder_size")
    
    timestamp=$(date +'%Y-%m-%d-%H-%M-%S')
    target_file="rpc_$key-${timestamp}-${folder_size_gb}G.tar.zst"
    metadata_file_name="rpc_$key-${timestamp}-${folder_size_gb}G.txt"

    #echo "$target_file"

    if [[ -n $2 ]]; then
	# Upload volume archive
	tar -cf - --dereference "$source_folder" | pv -pterb -s $(du -sb "$source_folder" | awk '{print $1}') | zstd | curl -X PUT --upload-file - "$2/null/uploading-$target_file"
        curl -X MOVE -H "Destination: /null/$target_file" "$2/null/uploading-$target_file"
        
        # Generate and upload metadata file
        echo "Generating metadata for volume: rpc_$key"
        temp_metadata="/tmp/$metadata_file_name"
        generate_volume_metadata "$key" "$source_folder" "$temp_metadata"
        curl -X PUT --upload-file "$temp_metadata" "$2/null/$metadata_file_name"
        rm -f "$temp_metadata"
    else    
        # Create volume archive
        tar -cf - --dereference "$source_folder" | pv -pterb -s $(du -sb "$source_folder" | awk '{print $1}') | zstd -o "/backup/uploading-$target_file"
        mv "/backup/uploading-$target_file" "/backup/$target_file"
        
        # Generate metadata file
        echo "Generating metadata for volume: rpc_$key"
        generate_volume_metadata "$key" "$source_folder" "/backup/$metadata_file_name"
    fi
done

# Run show-size.sh to display overall summary
echo ""
echo "=== Overall Size Summary ==="
if [[ -f "$BASEPATH/show-size.sh" ]]; then
    "$BASEPATH/show-size.sh" "$1" 2>&1
fi
