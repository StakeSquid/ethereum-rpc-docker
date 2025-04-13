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
DOMAIN=203-0-113-42.traefik.me  # Use your PUBLIC IP with dots replaced by hyphens
MAIL=your-email@example.com  # Required for Let's Encrypt SSL
WHITELIST=0.0.0.0/0  # IP whitelist for access (0.0.0.0/0 allows all)

# Public IP (required for many chains)
IP=203.0.113.42  # Your PUBLIC IP (get it with: curl ipinfo.io/ip)

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

### Node Structure

In general Nodes can have one or all of the following components:

- a client (execution layer)
- a node (for consensus)
- a relay (for data availability access)
- a database (external to the client mostly zk rollups, can have mulitple databases)
- a proxy (to map http access and websockets to the same endpoint)

The simplest examples have only a client. The compose files define one entrypoint to query the node. usually it's the client otherwise it's the proxy. some clients have multiple entrypoints because they allow to query the consensus layer and the execution layer.

In the root folder of this repository you can find convenience yml files which are symlinks to specific compose files. The naming  for the symlinks follow the principle {network_name}-{chain_name}.yml which leaves the client and bd type unspecified so they are defaults.

- default client is the default client for the network. Usually it's geth or op-geth.
- default sync mode is pruned. If available clients are snap synced.
- default node is op-node or prysm or whatever is the default for the network (e.g. beacon-kit for berachain, goat for goat, etc.)
- default sync mode for nodes is pruned
- default client for archive nodes is (op-)erigon or (op-)reth
- default sync mode for (op-)reth and (op-)erigon is archive-trace. 
- default sync mode for erigon3 is pruned-trace.
- default db is postgres
- default proxy is nginx



## Utility Scripts

This directory includes several useful scripts to help you manage and monitor your nodes:

### Status and Monitoring

- `show-status.sh [config-name]` - Check sync status of all configured nodes (or specific config if provided)
- `show-db-size.sh` - Display disk usage of all Docker volumes, sorted by size
- `show-networks.sh` - List all available network configurations
- `show-running.sh` - List currently running containers
- `sync-status.sh <config-name>` - Check synchronization status of a specific configuration
- `logs.sh <config-name>` - View logs of all containers for a specific configuration
- `latest.sh <config-name>` - Get the latest block number and hash of a local node
- `ping.sh <container-name>` - Test connectivity to a container from inside the Docker network

### Node Management

- `stop.sh <config-name>` - Stop all containers for a specific configuration
- `force-recreate.sh <config-name>` - Force recreate all containers for a specific configuration
- `backup-node.sh <config-name> [webdav_url]` - Backup Docker volumes for a configuration (locally or to WebDAV)
- `restore-volumes.sh <config-name> [http_url]` - Restore Docker volumes from backup (local or HTTP source)
- `cleanup-backups.sh` - Clean up old backup files
- `list-backups.sh` - List available backup files
- `op-wheel.sh` - Tool for Optimism rollup maintenance, including rewinding to a specific block

#### Nuclear option to recreate a node

```bash
./stop.sh <config-name> && ./rm.sh <config-name> && ./delete-volumes.sh <config-name> && ./force-recreate.sh <config-name> && ./logs.sh <config-name>
```

#### OP Wheel Usage Example

```bash
# Rewind an Optimism rollup to a specific block
./op-wheel.sh engine set-forkchoice --unsafe=0x111AC7F --safe=0x111AC7F --finalized=0x111AC7F \
  --engine=http://op-lisk-sepolia:8551/ --engine.open=http://op-lisk-sepolia:8545 \
  --engine.jwt-secret-path=/jwtsecret
```

Note: `<config-name>` refers to the compose file name without the .yml extension (e.g., `ethereum-mainnet` for ethereum-mainnet.yml)

## SSL Certificates and IP Configuration

### Public IP Configuration

Many blockchain nodes require your public IP address to function properly:

1. Get your public IP address:
   ```bash
   curl ipinfo.io/ip
   ```

2. Add this IP to your `.env` file:
   ```bash
   IP=203.0.113.42  # Your actual public IP
   ```

3. This IP is used by several chains for P2P discovery and network communication

### SSL Certificates with Traefik

This system uses Traefik as a reverse proxy for SSL certificates:

1. By default, certificates are obtained from Let's Encrypt
2. Use your **public** IP address with traefik.me by replacing dots with hyphens
   ```
   # If your public IP is 203.0.113.42
   DOMAIN=203-0-113-42.traefik.me
   ```
3. Traefik.me automatically generates valid SSL certificates for this domain
4. For production, use your own domain and set MAIL for Let's Encrypt notifications
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
- WebSocket: `wss://yourdomain.tld/ethereum` (same URL as HTTP/HTTPS)

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

## Supported Networks

This repository supports a comprehensive range of blockchain networks:

### Layer 1 Networks
- **Major Networks**: Ethereum (Mainnet, Sepolia, Holesky), BSC, Polygon, Avalanche, Gnosis
- **Alternative L1s**: Fantom, Core, Berachain, Ronin, Viction, Fuse, Tron, ThunderCore
- **Emerging L1s**: Goat, AlephZero, Haqq, Taiko, Rootstock

### Layer 2 Networks
- **OP Stack**: Optimism, Base, Zora, Mode, Blast, Fraxtal, Bob, Boba, Worldchain, Metal, Ink, Lisk, SNAX, Celo
- **Arbitrum Ecosystem**: Arbitrum One, Arbitrum Nova, Everclear, Playblock, Real, Connext, OpenCampusCodex
- **Other L2s**: Linea, Scroll, zkSync Era, Metis, Moonbeam

Most networks support multiple node implementations (Geth, Erigon, Reth) and environments (mainnet, testnet).

## Backup and Restore System

This repository includes a comprehensive backup and restore system for Docker volumes:

### Local Backups

- `backup-node.sh <config-name>` - Create a backup of all volumes for a configuration to the `/backup` directory
- `restore-volumes.sh <config-name>` - Restore volumes from the latest backup in the `/backup` directory

### Remote Backups

To serve backups via HTTP and WebDAV:

1. Add `backup-http.yml` to your `COMPOSE_FILE` variable in `.env`
2. This exposes:
   - HTTP access to backups at `https://yourdomain.tld/backup`
   - WebDAV access at `https://yourdomain.tld/dav`

### Cross-Server Backup and Restore

For multi-server setups:

1. On server A: Include `backup-http.yml` in `COMPOSE_FILE` to serve backups
2. On server B: Use restore from server A's backups:
   ```bash
   # Restore directly from server A
   ./restore-volumes.sh ethereum-mainnet https://serverA.domain.tld/backup/
   ```

3. Create backups on server B and send to server A via WebDAV:
   ```bash
   # Backup to server A's WebDAV
   ./backup-node.sh ethereum-mainnet https://serverA.domain.tld/dav
   ```

This allows for efficient volume transfers between servers without needing SSH access.