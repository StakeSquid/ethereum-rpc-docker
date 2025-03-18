#!/bin/bash

MODEL=${2:-gemma3:4b}

# Check if the container is already running
if ! docker ps --filter "name=ollama" --filter "status=running" | grep -q ollama; then
    echo "Starting ollama container..."
    docker run -d -v ollama:/root/.ollama --name ollama ollama/ollama
    docker exec -it ollama apt update
    docker exec -it ollama apt install curl
else
    echo "ollama container is already running."
fi

model_pulled=$(docker exec -it ollama ollama pull $MODEL)

# Assuming the log content is obtained from your Docker containers
logs=$(docker compose logs --tail 10000 $(cat /root/rpc/$1.yml | yaml2json - | jq '.services' | jq -r 'keys[]' | tr '\n' ' ') | grep -iE "info" | tail -n 100)

# Create the messages array with the system prompt first, then log lines as user messages
messages=(
  "{\"role\": \"system\", \"content\": \"You are an assistant trained to analyze blockchain RPC logs. The user gives you log entries line by line from different containers of the stack. you only respond with 0 if the client seems to be progressing or 1 if you think it's stuck.\"}"
)

while IFS='|' read -r container log; do
    # For each log line, add it as a user message
    escaped_content=$(echo $log | jq -sRr @json | sed 's/^"\(.*\)"$/\1/')
    message="{\"role\": \"user\", \"content\": \"$container | $escaped_content\"}"
    messages+=("$message")
done <<< "$logs"


#echo "${messages[@]}"

# Join the messages array into a single string for the API request
messages_json=$(printf ",%s" "${messages[@]}")
messages_json="[${messages_json:1}]"

request="{\"model\": \"$MODEL\", \"stream\": false,\"messages\": $messages_json}"

#echo "$request" | jq

# Send the request with the system prompt followed by the log lines
response=$(docker exec -it ollama curl -s -X POST http://localhost:11434/api/chat -d "$request")

#echo $response

# Extract the response and clean up
answer=$(echo "$response" | jq -r '.message.content' | xargs)

# Output the answer
echo "$answer"

exit $answer
