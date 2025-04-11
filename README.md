# Blockchain Node Configurations

This directory contains Docker Compose configurations for various blockchain networks and node implementations.

## Directory Structure

- Root level YAML files (e.g. `ethereum-mainnet.yml`, `arbitrum-one.yml`) - Main Docker Compose configurations for specific networks
- Network-specific subdirectories - Contain additional configurations, genesis files, and client-specific implementations
- Utility scripts (e.g. `show-networks.sh`, `logs.sh`) - Helper scripts for managing and monitoring nodes

## Node Types

This repository supports multiple node types for various blockchain networks:

- **Ethereum networks**: Mainnet, Sepolia, Holesky
- **Layer 2 networks**: Arbitrum, Optimism, Base, Scroll, ZKSync Era, etc.
- **Alternative L1 networks**: Avalanche, BSC, Fantom, Polygon, etc.

Most networks have both archive and pruned node configurations available, with support for different client implementations (Geth, Erigon, Reth, etc.).

## Quick Start

1. Create a `.env` file in this directory (see example below)
2. Select which node configurations you want to run by adding them to the `COMPOSE_FILE` variable
3. Run `docker compose up -d`
4. Access your RPC endpoints at `https://yourdomain.tld/path` or `http://localhost:port`

### Example .env File

```bash
# Domain settings
DOMAIN=node.traefik.me  # Use <anything>.traefik.me for automatic SSL certificates
MAIL=your-email@example.com  # Required for Let's Encrypt SSL
WHITELIST=0.0.0.0/0  # IP whitelist for access (0.0.0.0/0 allows all)

# Network settings
CHAINS_SUBNET=192.168.0.0/26

# RPC provider endpoints (fallback/bootstrap nodes)
ETHEREUM_MAINNET_EXECUTION_RPC=https://ethereum-rpc.publicnode.com
ETHEREUM_MAINNET_EXECUTION_WS=wss://ethereum-rpc.publicnode.com
ETHEREUM_MAINNET_BEACON_REST=https://ethereum-beacon-api.publicnode.com

ETHEREUM_SEPOLIA_EXECUTION_RPC=https://ethereum-sepolia-rpc.publicnode.com
ETHEREUM_SEPOLIA_EXECUTION_WS=wss://ethereum-sepolia-rpc.publicnode.com
ETHEREUM_SEPOLIA_BEACON_REST=https://ethereum-sepolia-beacon-api.publicnode.com

ARBITRUM_SEPOLIA_EXECUTION_RPC=https://arbitrum-sepolia-rpc.publicnode.com
ARBITRUM_SEPOLIA_EXECUTION_WS=wss://arbitrum-sepolia-rpc.publicnode.com

# SSL settings (set NO_SSL=true to disable SSL)
# NO_SSL=true

# Docker Compose configuration
# Always include base.yml and rpc.yml, then add the networks you want
COMPOSE_FILE=base.yml:rpc.yml:ethereum-mainnet.yml
```

## Usage

To start nodes defined in your `.env` file:

```bash
docker compose up -d
```

## Utility Scripts

This directory includes several useful scripts to help you manage and monitor your nodes:

### Status and Monitoring

- `show-status.sh [config-name]` - Check sync status of all configured nodes (or specific config if provided)
- `show-db-size.sh` - Display disk usage of all Docker volumes, sorted by size
- `show-networks.sh` - List all available network configurations
- `show-running.sh` - List currently running containers
- `sync-status.sh <config-name>` - Check synchronization status of a specific configuration
- `logs.sh <config-name>` - View logs of all containers for a specific configuration (e.g., `ethereum-mainnet`)

### Node Management

- `stop.sh <config-name>` - Stop all containers for a specific configuration (e.g., `ethereum-mainnet`)
- `force-recreate.sh <config-name>` - Force recreate all containers for a specific configuration
- `backup-node.sh <config-name> [webdav_url]` - Backup Docker volumes for a configuration (locally or to WebDAV)
- `restore-volumes.sh <config-name> [http_url]` - Restore Docker volumes from backup (local or HTTP source)
- `cleanup-backups.sh` - Clean up old backup files
- `list-backups.sh` - List available backup files

Note: `<config-name>` refers to the compose file name without the .yml extension (e.g., `ethereum-mainnet` for ethereum-mainnet.yml)

## SSL Certificates with Traefik

This system uses Traefik as a reverse proxy and can automatically handle SSL certificates:

1. By default, SSL certificates are obtained from Let's Encrypt
2. Use the domain `yourdomain.traefik.me` for testing (Traefik.me will automatically generate certificates)
3. You can also use your IP address with traefik.me by replacing dots with hyphens, e.g., `127-0-0-1.traefik.me`
4. For production, use your own domain and set MAIL in .env to your email for Let's Encrypt notifications
5. To disable SSL, set `NO_SSL=true` in your .env file

## Configuration

Each network configuration includes:

- Node client software (Geth, Erigon, etc.)
- Synchronization type (archive or pruned)
- Database backend and configuration
- Network-specific parameters

## Accessing RPC Endpoints

Once your nodes are running, you can access the RPC endpoints at:

- HTTPS: `https://yourdomain.tld/ethereum` (or other network paths)
- HTTP: `http://yourdomain.tld/ethereum` (or other network paths)
- WebSocket: `wss://yourdomain.tld/ethereum/ws` (or other network paths with /ws suffix)

All services use standard ports (80 for HTTP, 443 for HTTPS), so no port specification is required in the URL.

## Resource Requirements

Different node types have different hardware requirements:

- Pruned Ethereum node: ~500GB disk, 8GB RAM
- Archive Ethereum node: ~2TB disk, 16GB RAM
- L2 nodes typically require less resources than L1 nodes
- Consider using SSD or NVMe storage for better performance

## DRPC Integration

This system includes support for DRPC (Decentralized RPC) integration, allowing you to monetize your RPC nodes by selling excess capacity:

### Setting Up DRPC

1. Add `drpc.yml` to your `COMPOSE_FILE` variable in `.env`
2. Configure the following variables in your `.env` file:
   ```
   GW_DOMAIN=your-gateway-domain.com
   GW_REDIS_RAM=2gb  # Memory allocation for Redis
   DRPC_VERSION=0.64.16  # Or latest version
   ```
3. Generate the upstream configurations for dshackle:
   ```bash
   # Using domain URLs (default)
   ./upstreams.sh
   
   # Using internal container URLs (recommended for lower latency)
   ./upstreams.sh true
   ```

The `upstreams.sh` script automatically detects all running nodes on your machine and generates the appropriate configuration for the dshackle load balancer. This allows you to connect your nodes to drpc.org and sell RPC capacity.

For more information about DRPC, visit [drpc.org](https://drpc.org/).