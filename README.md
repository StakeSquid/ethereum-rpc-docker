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

### Ports

The default ports are defined in the templates. They are randomised to avoid conflicts. Some configurations can require 7 ports to be opened for P2P discovery. Docker will override any UFW firewall rule that you define on the host. You should prevent the containers to try to reach out to other nodes on local IP ranges.

You can use the following service definition as a starting point. Replace the {{ chains_subnet }} with the subnet of your network. Default is 192.168.0.0/26.

```
[Unit]
Description= iptables firewall docker fix
After=docker.service

[Service]
ExecStart=/usr/local/bin/iptables-firewall.sh start
RemainAfterExit=true
StandardOutput=journal

[Install]
WantedBy=multi-user.target
```

```bash
#!/bin/bash
PATH="/sbin:/usr/sbin:/bin:/usr/bin"

# Flush existing rules in the DOCKER-USER chain
# this is potentially dangerous if other scripts write in that chain too but for now this should be the only one
iptables -F DOCKER-USER

# block heise.de to test it's working. ./ping.sh heise.de will ping from a container in the subnet.
iptables -I DOCKER-USER -s {{ chains_subnet }} -d 193.99.144.80/32  -j REJECT

# block local networks
iptables -I DOCKER-USER -s {{ chains_subnet }} -d 192.168.0.0/16  -j REJECT
iptables -I DOCKER-USER -s {{ chains_subnet }} -d 172.16.0.0/12 -j REJECT
iptables -I DOCKER-USER -s {{ chains_subnet }} -d 10.0.0.0/8 -j REJECT

# accept the subnet so containers can reach each other.
iptables -I DOCKER-USER -s {{ chains_subnet }} -d {{ chains_subnet }}  -j ACCEPT

# I don't know why that is
iptables -I DOCKER-USER -s {{ chains_subnet }} -d 10.13.13.0/24  -j ACCEPT 
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


### Syncing

The configurations aim to work standalone restoring state as much as possible from public sources. Using snapshots can help syncing faster. For some configurations it's not reasonably possible to maintain a version that can be bootstrapped from scratch using only the compose file.


### Naming conventions

- default client is the default client for the network. Usually it's geth or op-geth.
- default sync mode is pruned. If available clients are snap synced.
- default node is op-node or prysm or whatever is the default for the network (e.g. beacon-kit for berachain, goat for goat, etc.)
- default sync mode for nodes is pruned
- default client for archive nodes is (op-)erigon or (op-)reth
- default sync mode for (op-)reth and (op-)erigon is archive-trace. 
- default sync mode for erigon3 is pruned-trace.
- default db is postgres
- default proxy is nginx

#### Node features

The idea is to assume a default node configuration that is able to drive the execution client. In case the beacon node database has special features then the file name would include the features after a double hyphen. e.g. `ethereum-mainnet-geth-pruned-pebble-hash--lighthouse-pruned-blobs.yml` would be a node that has a pruned execution client and a pruned beacon node database with a complete blob history.

#### Container names

The docker containers are generally named using the base name and the component suffix. The base name is generally the network name and the chain name and the sync mode archive in case of archive nodes. The rationale is that it doesn't make sense to run 2 pruned nodes for the same chain on the same machine as well as 2 archive nodes for the same chain. The volumes that are created in /var/lib/docker/volumes are using the full name of the node including the sync mode and database features. This is to allow switching out the implementation of parts of the configuration and not causing conflicts, e.g. exchanging prysm for nimbus as node implementation but keep using the same exection client. Environment variables are also using the full name of the component that they are defined for.


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

#### Debugging tips

To get the configuration name for one of the commands use `./show-status.sh` which lists all the configrations and their status to copy paste for further inspection with e.g. `./catchup.sh <config-name>` or repeated use of `./latest.sh <config-name>` which will give you and idea if the sync is actually progressing and if it is on the canonical chain.
Note: some configurations use staged sync which means that there is no measurable progress on the RPC in between bacthes of processed blocks. In any case `./logs.sh <config-name>` will give you insights into problems, potentially filtered by a LLM to spot common errors. It could be that clients are syncing slower than the chain progresses.

#### Further automation

You can chain `./success-if-almost-synced.sh <config-name> <age-of-last-block-in-seconds-to-be-considered-almost-synced>` with other scripts to create more complex automation, e.g. notify you once a node synced up to chainhead or adding the node to the dshackle configuration or taking a backup to clone the node to a different server.

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