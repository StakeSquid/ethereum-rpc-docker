# ETH JSON-RPC Proxy (Dual Upstream Comparator)

A high-performance Ethereum JSON-RPC proxy that forwards requests to two upstream endpoints, streams responses from the primary, and compares responses for latency and content differences.

## Features

- 🚀 **Streaming Response**: Streams response from primary endpoint with minimal latency
- 🔍 **Dual Comparison**: Compares responses from two endpoints in parallel
- 📊 **Latency Monitoring**: Tracks and logs latency differences between endpoints
- 🔧 **Configurable Roles**: Switch primary/secondary roles via configuration
- 🔄 **Dynamic Role Switching**: Switch primary/secondary roles at runtime without restart
- 📝 **Structured Logging**: JSON-formatted logs for easy parsing and monitoring
- 🐳 **Docker Ready**: Includes Dockerfile for easy deployment

## Quick Start

### Local Development

1. Install dependencies:
```bash
npm install
```

2. Copy the example environment file:
```bash
cp .env.example .env
```

3. Configure your RPC endpoints in `.env`:
```env
PRIMARY_RPC=http://localhost:8545
SECONDARY_RPC=http://localhost:8546
```

4. Start the proxy:
```bash
npm start
```

For development with auto-reload:
```bash
npm run dev
```

### Docker

Build and run with Docker:

```bash
# Build the image
docker build -t eth-rpc-proxy .

# Run the container
docker run -p 8545:8545 \
  -e PRIMARY_RPC=http://your-primary-rpc:8545 \
  -e SECONDARY_RPC=http://your-secondary-rpc:8545 \
  eth-rpc-proxy
```

## Configuration

All configuration is done via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PRIMARY_RPC` | `http://localhost:8545` | Primary RPC endpoint URL |
| `SECONDARY_RPC` | `http://localhost:8546` | Secondary RPC endpoint URL |
| `PRIMARY_ROLE` | `primary` | Which endpoint to stream (`primary` or `secondary`) |
| `LATENCY_THRESHOLD_MS` | `1000` | Log if secondary is slower by this many ms |
| `SIZE_DIFF_THRESHOLD` | `100` | Log full response if size differs by this many bytes |
| `LOG_MISMATCHES` | `true` | Whether to log response mismatches |
| `PORT` | `8545` | Port to listen on |
| `REQUEST_TIMEOUT` | `30000` | Request timeout in milliseconds |
| `LOG_LEVEL` | `info` | Log level (debug, info, warn, error) |
| `DNS_REFRESH_INTERVAL` | `1000` | DNS cache refresh interval in milliseconds |

## Usage Examples

### Basic JSON-RPC Request

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "eth_blockNumber",
    "params": [],
    "id": 1
  }'
```

### Health Check

```bash
curl http://localhost:8545/health
```

Response:
```json
{
  "status": "ok",
  "primaryEndpoint": "http://localhost:8545",
  "secondaryEndpoint": "http://localhost:8546",
  "primaryRole": "primary"
}
```

## How It Works

1. **Request Reception**: Proxy receives JSON-RPC POST request
2. **Parallel Forwarding**: Request is sent to both primary and secondary endpoints simultaneously
3. **Stream Response**: Response from the designated primary is streamed back to client immediately
4. **Background Comparison**: Secondary response is collected and compared in the background
5. **Logging**: Differences in latency, size, or content are logged for monitoring

## Dynamic Role Switching

You can switch between primary and secondary endpoints at runtime without restarting the proxy by sending a `SIGUSR1` signal:

### Local Process
```bash
# Find the process ID
ps aux | grep "node index.js"

# Send SIGUSR1 signal
kill -USR1 <pid>
```

### Docker Container
```bash
# Send SIGUSR1 to the container
docker kill -s USR1 eth-rpc-proxy

# Or if using docker-compose
docker-compose kill -s USR1 eth-rpc-proxy
```

When the signal is received, the proxy will:
- Swap the streaming and comparison endpoints
- Log the role switch with the new configuration
- Continue processing requests with the new roles immediately

The health endpoint will reflect the current active endpoints:
```json
{
  "status": "ok",
  "primaryEndpoint": "http://localhost:8545",
  "secondaryEndpoint": "http://localhost:8546",
  "primaryRole": "secondary",
  "currentStreamEndpoint": "http://localhost:8546",
  "currentCompareEndpoint": "http://localhost:8545"
}
```

## DNS Resolution for Docker Environments

The proxy automatically handles DNS resolution to ensure it always connects to the correct container IPs, even when containers restart and receive new IP addresses. This is especially important in Docker environments.

### How it works:

1. **Fresh DNS Lookups**: The proxy creates new HTTP clients for each request, ensuring fresh DNS resolution
2. **Periodic Cache Clearing**: DNS cache is cleared at the configured interval (default: 1 second)
3. **Connection Pooling**: Despite fresh DNS lookups, connections are pooled for performance
4. **Automatic Recovery**: When a container restarts with a new IP, the proxy automatically discovers it

### Configuration:

Set the `DNS_REFRESH_INTERVAL` environment variable to control how often the DNS cache is refreshed:

```bash
# Refresh DNS every second (default)
DNS_REFRESH_INTERVAL=1000

# Refresh DNS every 5 seconds
DNS_REFRESH_INTERVAL=5000
```

This ensures the proxy remains resilient in dynamic container environments where services may be redeployed or scaled.

## Monitoring

The proxy logs structured JSON output that includes:

- Request IDs for tracing
- Method names
- Latency measurements
- Response sizes
- Mismatch details

Example log output:
```json
{
  "level": "info",
  "time": "2024-01-01T12:00:00.000Z",
  "requestId": "a1b2c3d4e5f6",
  "method": "eth_getBlockByNumber",
  "endpoint": "stream",
  "latencyMs": 45,
  "msg": "Stream response started"
}
```

## Performance Considerations

- The proxy streams responses to minimize latency impact
- Comparison happens asynchronously without blocking the response
- Large responses are handled efficiently with streaming
- Connection pooling is used for upstream requests

## Docker Compose Example

```yaml
version: '3.8'

services:
  eth-proxy:
    build: .
    ports:
      - "8545:8545"
    environment:
      PRIMARY_RPC: http://geth:8545
      SECONDARY_RPC: http://besu:8545
      LATENCY_THRESHOLD_MS: 500
      LOG_LEVEL: info
    restart: unless-stopped
```

## Troubleshooting

### Common Issues

1. **Connection Refused**: Ensure upstream endpoints are accessible
2. **Timeout Errors**: Increase `REQUEST_TIMEOUT` for slow endpoints
3. **Memory Issues**: The proxy buffers secondary responses - ensure adequate memory for large responses

### Debug Mode

Enable debug logging for more detailed information:
```bash
LOG_LEVEL=debug npm start
```

## License

MIT 