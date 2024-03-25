BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

IFS=':' read -ra parts <<< $COMPOSE_FILE

used_volumes=()

for part in "${parts[@]}"; do

  # Convert YAML to JSON using yaml2json
  json=$(yaml2json "$BASEPATH/$part")

  # Extract volumes using jq
  volumes=$(echo "$json" | jq -r '.volumes | keys[]' 2> /dev/null)

  # Convert volumes to an array
  prefix="rpc_"
  IFS=$'\n' read -r -d '' -a volumes_array <<< "$(printf "%s\n" "${volumes[@]}" | sed "/^$/! s/^/$prefix/")"

  used_volumes=("${used_volumes[@]}" "${volumes_array[@]}")
done

on_disk=($(docker volume ls --format '{{.Name}}' | grep '^rpc_'))

unused_volumes=()

for element in "${on_disk[@]}"; do
    # Check if the element exists in array2
    if [[ ! "${used_volumes[@]}" =~ "$element" ]]; then
        # If not, add it to the difference array
        unused_volumes+=("$element")
    fi
done

if [ "$1" = "--remove-from-disk" ]; then
    # Iterate over volumes in the difference array and remove them from disk
    for volume in "${unused_volumes[@]}"; do
        docker volume rm "$volume"
    done
else
  printf '%s\n' "${unused_volumes[@]}"
fi
