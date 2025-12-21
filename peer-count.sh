#!/bin/bash

BASEPATH="$(dirname "$0")"
source $BASEPATH/.env

blacklist=()
while IFS= read -r line; do 
    # Add each line to the array
    blacklist+=("$line")
done < "$BASEPATH/path-blacklist.txt"

if [ -n "$NO_SSL" ]; then
    PROTO="http"
    DOMAIN="${DOMAIN:-0.0.0.0}"
fi

pathlist=$(cat $BASEPATH/$1.yml | grep -oP "stripprefix\.prefixes.*?/\K[^\"]+")

for path in $pathlist; do
    include=true
    for word in "${blacklist[@]}"; do
        if echo "$path" | grep -qE "$word"; then
            include=false
        fi
    done

    if $include; then
        RPC_URL="${PROTO:-https}://$DOMAIN/$path"
        
        # Try admin_peers first (returns detailed peer info)
        response=$(curl --ipv4 -L -s -X POST "$RPC_URL" \
            -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}')
        
        # Check if we got a valid response
        if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
            peer_count=$(echo "$response" | jq -r '.result | length')
            echo "$path: $peer_count peer(s)"
            
            # Extract and aggregate client version statistics
            if [ "$peer_count" -gt 0 ]; then
                # Extract client names and versions from peer data
                # The name field typically looks like "Geth/v1.13.0-stable/..." or "Reth/v0.2.0/..."
                declare -A client_versions
                
                # Process each peer's name field
                while IFS= read -r peer_name; do
                    if [ -z "$peer_name" ] || [ "$peer_name" = "null" ]; then
                        continue
                    fi
                    
                    # Parse client name and version from name field
                    # Format is typically "ClientName/Version/..." or "ClientName/Version-stable/..."
                    # Examples: "Geth/v1.13.0-stable/linux-amd64/go1.21.5" -> "Geth/v1.13.0-stable"
                    #           "Reth/v0.2.0-beta.1/..." -> "Reth/v0.2.0-beta.1"
                    client_version=$(echo "$peer_name" | sed -E 's|^([^/]+)/([^/]+).*|\1/\2|')
                    
                    # Only process if we successfully extracted client/version (i.e., it contains a slash)
                    if [ -n "$client_version" ] && [[ "$client_version" == *"/"* ]] && [ "$client_version" != "$peer_name" ]; then
                        # Increment count for this client/version combination
                        if [ -z "${client_versions[$client_version]}" ]; then
                            client_versions[$client_version]=1
                        else
                            client_versions[$client_version]=$((${client_versions[$client_version]} + 1))
                        fi
                    fi
                done < <(echo "$response" | jq -r '.result[].name // empty' 2>/dev/null)
                
                # Display client version statistics
                if [ ${#client_versions[@]} -gt 0 ]; then
                    echo "  Client versions:"
                    # Sort by count (descending), then by client name
                    for client_version in "${!client_versions[@]}"; do
                        count=${client_versions[$client_version]}
                        printf "%3d %s\n" "$count" "$client_version"
                    done | sort -rn | while read count client_version; do
                        printf "    %-40s %3d peer(s)\n" "$client_version" "$count"
                    done
                fi
            fi
            echo ""
        else
            # Fallback to net_peerCount if admin_peers is not available
            response=$(curl --ipv4 -L -s -X POST "$RPC_URL" \
                -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}')
            
            if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
                peer_count=$(echo "$response" | jq -r '.result' | xargs printf "%d")
                echo "$path: $peer_count peer(s)"
                echo ""
            else
                # If both methods fail, show error
                error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "Connection failed")
                echo "$path: ERROR - $error_msg"
                echo ""
            fi
        fi
    fi
done

