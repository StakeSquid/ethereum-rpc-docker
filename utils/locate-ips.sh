#!/bin/bash

# Temporary file to store results
temp_file=$(mktemp)

# Loop through each IP from stdin, fetch geolocation, and append data
while read -r ip; do
  # Check if the IP is not empty
  if [[ -n "$ip" ]]; then
    # Fetch geolocation data
    response=$(curl -s "https://ipinfo.io/$ip/json")
    
    # Extract country code, city, and hoster (if available)
    country=$(echo "$response" | jq -r '.country // "Unknown"')                                                                                                                                                      
    city=$(echo "$response" | jq -r '.city // "Unknown"')
    hoster=$(echo "$response" | jq -r '.org // "Unknown"')

    # Write the IP and its details to the temp file
    echo "$ip - $city, $country, $hoster" >> "$temp_file"                                                
  fi
done

# Output the results
cat "$temp_file"                                                                                                                                                                                                     

# Clean up
rm -f "$temp_file"
