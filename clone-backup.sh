#!/bin/bash
dir="$(dirname "$0")"

# FTP server details
LOCAL_DIR="/backup"

mkdir -p "$LOCAL_DIR"

keys=$(cat $dir/$2.yml | yaml2json - | jq '.volumes' | jq -r 'keys[]')

files=()

for key in $keys; do
    volume_name="rpc_$key"

    need_to_copy_file=$($dir/list-backups.sh $1 | grep "${volume_name}" | sort | tail -n 1)

    #echo "Download: $need_to_copy_file"
    files+=("$need_to_copy_file")
done

if [ "$3" = "--print-timestamp-only" ]; then
    echo "${files[@]}"
    exit 0
fi

base_url="$1"
aria2c -c -Z -x8 -j8 -s8 -d "$LOCAL_DIR" "${files[@]/#/$base_url}"

