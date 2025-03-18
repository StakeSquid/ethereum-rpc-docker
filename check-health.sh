#!/bin/bash

RPC_URL="$1"
ref="$2"

timeout=5 # seconds

response_file=$(mktemp)

http_status_code=$(curl --ipv4 -m $timeout -s -X POST -w "%{http_code}" -o "$response_file" -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}' $RPC_URL)

if [ $? -eq 0 ]; then
    if [[ $http_status_code -eq 200 ]]; then
        response=$(cat "$response_file")
        latest_block_timestamp=$(echo "$response" | jq -r '.result.timestamp')
        latest_block_timestamp_decimal=$((16#${latest_block_timestamp#0x}))
        current_time=$(date +%s)
        time_difference=$((current_time - latest_block_timestamp_decimal))

        rm "$response_file"
        
        if [ -n "$ref" ]; then
            latest_block_number=$(echo "$response" | jq -r '.result.number')
            latest_block_hash=$(echo "$response" | jq -r '.result.hash')            
            response_file2=$(mktemp)

	    sleep 1 # to give the reference node more time to import the block if it is very current
	    
            http_status_code2=$(curl --ipv4 -m $timeout -s -X POST -w "%{http_code}" -o "$response_file2" -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$latest_block_number\", false],\"id\":1}" $ref)

	    curl_code=$?
	    
            if [ $curl_code -eq 0 ]; then	    
                if [[ $http_status_code2 -eq 200 ]]; then
                    response2=$(cat "$response_file2")
                    latest_block_hash2=$(echo "$response2" | jq -r '.result.hash')

                    rm "$response_file2"
                    
                    if [ "$latest_block_hash" == "$latest_block_hash2" ]; then
                        response_file3=$(mktemp)

                        http_status_code=$(curl --ipv4 -m $timeout -s -X POST -w "%{http_code}" -o "$response_file3" -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\", false],\"id\":1}" $ref)

                        curl_code=$?

			if [ $curl_code -eq 0 ]; then
                            if [[ $http_status_code -eq 200 ]]; then
                                response3=$(cat "$response_file3")
                                latest_block_timestamp3=$(echo "$response3" | jq -r '.result.timestamp')
                                latest_block_timestamp_decimal3=$((16#${latest_block_timestamp3#0x}))
                                time_difference3=$(( latest_block_timestamp_decimal3 - latest_block_timestamp_decimal ))

                                rm "$response_file3"
                                
                                if [ $time_difference3 -lt 2 ]; then
                                    echo "online"
                                    exit 0
                                elif [ $time_difference3 -lt 5 ]; then
                                    echo "lagging"
                                    exit 0
                                else
                                    echo "syncing"
                                    exit 1
                                fi
                            fi
                        fi
                    else
                        echo "forked"
                        exit 1
                    fi
		else 
		    echo "unverified ($http_status_code2)"
		    exit 0
                fi 
            fi
            
            echo "unverified ($curl_code)"
            exit 0
        elif [ $time_difference -lt 60 ]; then
            echo "online"
            exit 0
        else
            echo "behind"
            exit 1
        fi        
    elif [[ $http_status_code -eq 404 ]]; then
        echo "offline"
        exit 1
    elif [[ $http_status_code -eq 401 ]]; then
        echo "unauthorized"
        exit 1
    elif [[ $http_status_code -eq 500 ]]; then
        echo "error"
        exit 1    
    else
        echo "Unexpected HTTP status code: $http_status_code"
        exit 1
    fi
else
    echo "timeout"
    exit 1        
fi
