#!/bin/bash

# echo "$@"

urls=()
options=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            urls+=("$2")
            shift 2
            ;;
        *)
            options+=("$1")
            shift 1
            ;;
    esac
done

if [[ ${#urls[@]} -eq 0 ]]; then
    echo "No URLs provided"
    exit 1
fi

original_output=""
temp_file=""

for i in "${!options[@]}"; do
    if [[ "${options[i]}" == "-o" ]]; then
        output_file="${options[i+1]}"
        temp_file=$(mktemp)

        options[i+1]="$temp_file"
        original_output="$output_file"
        break
    fi
done

output=""
for url in "${urls[@]}"; do
    #echo "curl -s ${options[@]} $url"
    output=$(eval "curl -s ${options[@]@Q} '$url' --fail-with-body")
    if [[ $? -eq 0 ]]; then

        if cat "$temp_file" | jq -e 'has("error")' > /dev/null 2>&1; then
            continue  # Try the next URL
        fi

	if [ -n "$original_output" ]; then
	    #echo "$(cat $temp_file)"
	    cat "$temp_file" > "$original_output"
	fi
	
        echo "$output"
        exit 0
    else
        continue
    fi
done

# Write the final output to the original output file if specified
if [ -n "$original_output" ]; then
    cat "$temp_file" > "$original_output"
fi

# Print the output to stdout
echo "$output"
exit 1
