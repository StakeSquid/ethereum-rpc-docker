EASY: How to bootstrap a Arbitrum archive node in 3 steps
====


Prerequisites
====

* CPU: 4 Cores / 8 Threads
* RAM: 16 GiB
* Storage: 2.5 TiB NVMe SSD
* OS: Ubuntu 22.04

You will be ready to leave the computer alone in 10 minutes and synced up in 10 hours from now.


Install Required Software
===

	sudo apt-get install docker.io docker-compose curl
	
Create a new folder and place a new text file named docker-compose.yml into it.

	mkdir ~/rpc
	cd ~/rpc
	nano docker-compose.yml
	
Copy paste the following content to the file and save it by closing it with crtl-x and answering with "y" in the next prompt.

```
version: '3.1'

services:

  traefik:
    image: traefik:latest
    container_name: traefik
    restart: always
    ports:
    - "443:443"
    command:
    - "--api=true"
    - "--api.insecure=true"
    - "--api.dashboard=true"
    - "--log.level=DEBUG"
    - "--providers.docker=true"
    - "--providers.docker.exposedbydefault=false"
    - "--entrypoints.websecure.address=:443"
    - "--certificatesresolvers.myresolver.acme.tlschallenge=true"
    - "--certificatesresolvers.myresolver.acme.email=$EMAIL"
    - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    volumes:
    - "traefik_letsencrypt:/letsencrypt"
    - "/var/run/docker.sock:/var/run/docker.sock:ro"
    labels:
    - "traefik.enable=true"
    - "traefik.http.middlewares.ipwhitelist.ipwhitelist.sourcerange=$WHITELIST"

  arbitrum-nitro:
    image: 'offchainlabs/nitro-node:v2.0.10-rc.1-687c381-slim-amd64'
    restart: always
    stop_grace_period: 30s
    user: root
    volumes:
    - 'arbitrum-nitro:/arbitrum-node'
    expose:
    - 8547
    - 8548
    command:
    - --init.url=https://snapshot.arbitrum.io/mainnet/nitro.tar
    - --node.caching.archive
    - --persistent.chain=/arbitrum-node/data/
    - --persistent.global-config=/arbitrum-node/
    - --node.rpc.classic-redirect=http://arbitrum-classic:8547/
    - --l1.url=${ARBITRUM_L1_URL}
    - --l2.chain-id=42161
    - --http.api=net,web3,eth,debug
    - --http.corsdomain=*
    - --http.addr=0.0.0.0
    - --http.vhosts=*
    restart: unless-stopped
    labels:
    - "traefik.enable=true"
    - "traefik.http.middlewares.arbitrum-stripprefix.stripprefix.prefixes=/arbitrum-archive"
    - "traefik.http.services.arbitrum.loadbalancer.server.port=8547"
    - "traefik.http.routers.arbitrum.entrypoints=websecure"
    - "traefik.http.routers.arbitrum.tls.certresolver=myresolver"
    - "traefik.http.routers.arbitrum.rule=Host(`$DOMAIN`) && PathPrefix(`/arbitrum-archive`)"
    - "traefik.http.routers.arbitrum.middlewares=arbitrum-stripprefix, ipwhitelist"

  arbitrum-classic:
    image: 'offchainlabs/arb-node:v1.4.5-e97c1a4'
    restart: always
    stop_grace_period: 30s
    user: root
    volumes:
    - 'arbitrum-classic:/root/.arbitrum/mainnet'
    - './arbitrum-classic-entrypoint.sh:/entrypoint.sh'
    expose:
    - 8547
    - 8548
	entrypoint: ["/bin/bash", "/entrypoint.sh"]
    command:
    - --l1.url=${ARBITRUM_L1_URL}
    - --l2.disable-upstream
    - --node.chain-id=42161
    - --node.rpc.tracing.enable
    - --node.rpc.tracing.namespace=trace
    - --core.checkpoint-pruning-mode=off
    - --node.cache.allow-slow-lookup
    - --core.checkpoint-gas-frequency=156250000
    - --node.rpc.addr=0.0.0.0
    restart: unless-stopped

volumes:
  arbitrum-nitro:
  arbitrum-classic:
  traefik_letsencrypt:
```

Also create this helper script tow download download a snapshot on first start. save it into a file named arbitrum-class-entrypoint.sh

```
#!/bin/bash

if [ -f /root/.arbitrum/mainnet/INITIALIZED ]; then
    echo "datadir is already initialized"
else
    echo "lemme download the database quickly"
    rm -rf /root/.arbitrum/mainnet/db
    curl https://snapshot.arbitrum.io/mainnet/db.tar | tar -xv -C /root/.arbitrum/mainnet/ && touch /root/.arbitrum/mainnet/INITIALIZED    
fi

echo "LFG!!!"

/home/user/go/bin/arb-node $@

```

Next make our new file executable.

```
chmod +x arbitrum-classic-entrypoint.sh

```

Well done!

Now you'd need the ip address of the machine that you are running on. Thewre is a ip filter in place which allows only whitelisted IPs to connect to your new RPC. 
You can query your global IP using curl by entering the following in the terminal.

	curl ifconfig.me
	
Note it down. You also need a domain for the ssl certificate that wil be generated for you. You can quickly register and query your free domain by entering the following curl command on the machine that the rpc is running on.

	curl -X PUT bash-st.art

Last bit to have handy is a email address that will not be chekced and no one ever would send an email there. In short: write nonsense. The very last bit to note is a ETH mainnet RPC that you shouldalready have to run your mainnet indexer. We need the URL of that RPC.

With this information at hand, create a file .env in the same folder with the following content and save the file after replacing ALL the {PLACEHOLDERS}.

	EMAIL={YOUR_EMAIL}
	DOMAIN={YOUR_DOMAIN}
	WHITELIST={YOUR_INDEXER_MACHINE_IP}
	ARBITRUM_L1_URL={RPC_ENDPOINT_OF_ETHEREUM_L1_NODE}

Finally run the node using docker-compose. Enter the following on the command line.

	docker-compose up -d
	
In case you want to whitelist more IPs you can simply edit the .env file, add more IPs comma separated and run the above command again to pick up the changes.

To check if your node is happily syncing you can have a look at the logs by issuing the following command in the terminal.

	docker-compose logs -f arbitrum-nitro

It should start by downloading a snapshot for about 30 minutes.
	
To check the sync status of old blocks before the nitro update you can look at the logs of the classic node using the following command. 

	docker-compose logs -f arbitrum-classic
	
You'd probably see it downloading the snapshot on first run. This can take a while since we need to download 600 GB for around 2 hours. After that the node will digest the snashot for another 6 hours or so. be patient.

In the following please replace {DOMAIN} with your actual domain. Your rpc endpoint will be reachable under the url 

	https://{DOMAIN}/arbitrum-archive

If you get error codes, e.g. FORBIDDEN check if you added rthe correct global IP of the machine you are on to the WHITELIST in the .env file.

Alternatively to the logs you can check the nodes status via rpc using the following curl command.

	curl --data '{"method":"eth_synching","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/arbitrum-archive
	
To trouble shoot it's also interesting to know which block your node is currently synced up to. you can query that with the following curl command.

	curl --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/arbitrum-archive

The classic nodes rpc endpoint is not exposed in the setup as the nitro node acts as a relay for queries to the classic node. You can change that easily if you feel the need for it. 


Happy Googling!
