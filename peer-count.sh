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
        
        # First, get the running client's own version using admin_nodeInfo
        node_info_response=$(curl --ipv4 -L -s -X POST "$RPC_URL" \
            -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' 2>/dev/null)
        
        running_client_version=""
        if echo "$node_info_response" | jq -e '.result.name' > /dev/null 2>&1; then
            running_client_full_name=$(echo "$node_info_response" | jq -r '.result.name // empty' 2>/dev/null)
            if [ -n "$running_client_full_name" ]; then
                # Extract client/version from name (e.g., "Geth/v1.13.0-stable/..." -> "Geth/v1.13.0-stable")
                running_client_version=$(echo "$running_client_full_name" | sed -E 's|^([^/]+)/([^/]+).*|\1/\2|')
            fi
        fi
        
        # Try admin_peers first (returns detailed peer info)
        response=$(curl --ipv4 -L -s -X POST "$RPC_URL" \
            -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' 2>/dev/null)
        
        # Check if we got a valid response
        if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
            peer_count=$(echo "$response" | jq -r '.result | length')
            echo "$path: $peer_count peer(s)"
            
            # Show running client version if available
            if [ -n "$running_client_version" ]; then
                echo "  Running client: $running_client_version"
            fi
            
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
                    echo "  Peer client versions:"
                    # Sort by count (descending), then by client name
                    for client_version in "${!client_versions[@]}"; do
                        count=${client_versions[$client_version]}
                        printf "%3d %s\n" "$count" "$client_version"
                    done | sort -rn | while read count client_version; do
                        # Check if this matches the running client version
                        marker=""
                        if [ -n "$running_client_version" ] && [ "$client_version" = "$running_client_version" ]; then
                            marker=" (current)"
                        fi
                        printf "    %-40s %3d peer(s)%s\n" "$client_version" "$count" "$marker"
                    done
                    
                    # Check for newer versions and suggest updates
                    if [ -n "$running_client_version" ]; then
                        running_client=$(echo "$running_client_version" | cut -d'/' -f1)
                        running_version=$(echo "$running_client_version" | cut -d'/' -f2)
                        
                        # Find different versions of the same client
                        different_versions=()
                        for client_version in "${!client_versions[@]}"; do
                            peer_client=$(echo "$client_version" | cut -d'/' -f1)
                            peer_version=$(echo "$client_version" | cut -d'/' -f2)
                            
                            # Only compare if it's the same client with a different version
                            if [ "$peer_client" = "$running_client" ] && [ "$peer_version" != "$running_version" ]; then
                                different_versions+=("$client_version")
                            fi
                        done
                        
                        if [ ${#different_versions[@]} -gt 0 ]; then
                            echo "  ℹ️  Different versions detected: Peers are running different versions of $running_client"
                            for diff_version in "${different_versions[@]}"; do
                                count=${client_versions[$diff_version]}
                                echo "      $diff_version ($count peer(s))"
                            done
                            echo "      Your version: $running_client_version"
                        fi
                    fi
                fi
            fi
            echo ""
        else
            # Check if this is a method not found error (consensus client or admin API disabled)
            error_code=$(echo "$response" | jq -r '.error.code // empty' 2>/dev/null)
            error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
            
            # Skip silently if it's a method not found error (likely consensus client)
            if [ -n "$error_code" ] && [ "$error_code" != "null" ]; then
                # This is likely a consensus client endpoint, skip it silently
                continue
            fi
            
            # Fallback to net_peerCount if admin_peers is not available
            response=$(curl --ipv4 -L -s -X POST "$RPC_URL" \
                -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' 2>/dev/null)
            
            if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
                peer_count=$(echo "$response" | jq -r '.result' | xargs printf "%d")
                echo "$path: $peer_count peer(s)"
                if [ -n "$running_client_version" ]; then
                    echo "  Running client: $running_client_version"
                fi
                echo ""
            else
                # Only show error if it's not a method not found (skip consensus clients silently)
                error_code=$(echo "$response" | jq -r '.error.code // empty' 2>/dev/null)
                if [ -z "$error_code" ] || [ "$error_code" = "null" ]; then
                    # Connection error or other non-method error, skip silently
                    continue
                fi
            fi
        fi
    fi
done

