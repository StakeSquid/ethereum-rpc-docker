How to bootstrap a Optimism archive node with Docker
====

Also EASY
------

[Celo](howto-celo-archive.md) | [Optimism](howto-optimism-archive.md) | [Avalanche](howto-avalanche-archive.md) | [Arbitrum](howto-arbitrum-archive.md) | [Gnosis](http://rpc.bash-st.art) | [Polygon](http://rpc.bash-st.art) | [Ethereum](http://rpc.bash-st.art)

[Very EASY](http://rpc.bash-st.art)


Prerequisites
====

* CPU: 4 Cores / 8 Threads
* RAM: 16 GiB
* Storage: 2.5 TiB NVMe SSD
* OS: Ubuntu 22.04

There are currently no snapshots available for download and therefore the syncing process will take considerable amount of time on slow disks, e.g. attached network storage form cloud providers is a no go. Also the CPU should feature a higth single core speed. 

Sync times are reported to be in the range of 1 week on dedicated hardware.


Install Required Software
===

Okay guys I know you will be done in less than 5 minutes. Let me tell you it took ages for me to comes up with the copy pasta that allows you to spinup that archive node in between choosing nutella or jam for your next breakfast toast. 50 hours of crunching compressed to a bite.

It goes like this...

	sudo apt-get install docker.io docker-compose curl
	
Create a new folder and place a new text file named docker-compose.yml into it.

	mkdir ~/rpc
	cd ~/rpc
	nano docker-compose.yml
	
Copy pasta the following content to the file and save it by closing it with crtl-x and answering with "y" in the next prompt. Beware that you don't have to select all the text you can click the copy icon that appears when you hover over the upper right corner of the block.

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
  
  optimism-dtl:
    image: ethereumoptimism/data-transport-layer:${IMAGE_TAG__DTL:-latest}
    restart: unless-stopped
    user: root
    entrypoint:
    - /bin/sh
    - -c
    - "/scripts/dtl-start.sh"
    environment:
    - "NODE_TYPE=archive"
    - "SYNC_SOURCE=l1"
    - "DATA_TRANSPORT_LAYER__ADDRESS_MANAGER=0xdE1FCfB0851916CA5101820A69b13a4E276bd81F"
    - "DATA_TRANSPORT_LAYER__L1_START_HEIGHT=13596466"
    - "DATA_TRANSPORT_LAYER__CONFIRMATIONS=12"
    - "DATA_TRANSPORT_LAYER__DANGEROUSLY_CATCH_ALL_ERRORS=true"
    - "DATA_TRANSPORT_LAYER__DB_PATH=/db"
    - "DATA_TRANSPORT_LAYER__ENABLE_METRICS=true"
    - "DATA_TRANSPORT_LAYER__ETH_NETWORK_NAME=mainnet"
    - "DATA_TRANSPORT_LAYER__L2_CHAIN_ID=10"
    - "DATA_TRANSPORT_LAYER__LOGS_PER_POLLING_INTERVAL=2000"
    - "DATA_TRANSPORT_LAYER__NODE_ENV=production"
    - "DATA_TRANSPORT_LAYER__POLLING_INTERVAL=500"
    - "DATA_TRANSPORT_LAYER__SENTRY_TRACE_RATE=0.05"
    - "DATA_TRANSPORT_LAYER__SERVER_HOSTNAME=0.0.0.0"
    - "DATA_TRANSPORT_LAYER__SERVER_PORT=7878"
    - "DATA_TRANSPORT_LAYER__TRANSACTIONS_PER_POLLING_INTERVAL=1000"
    volumes:
    - optimism-dtl:/db
    - ./optimism/scripts/:/scripts/
  
  optimism-l2geth:
    image: ethereumoptimism/l2geth:${IMAGE_TAG__L2GETH:-latest}
    restart: unless-stopped
    stop_grace_period: 3m
    user: root
    entrypoint:
    - /bin/sh
    - -c
    - "/scripts/l2geth-init.sh && /scripts/l2geth-start.sh"
    environment:
    - "NODE_TYPE=archive"
    - "SYNC_SOURCE=l1"
    - "USING_OVM=true"
    - "SEQUENCER_CLIENT_HTTP=https://mainnet.optimism.io"
    - "BLOCK_SIGNER_ADDRESS=0x00000398232E2064F896018496b4b44b3D62751F"
    - "BLOCK_SIGNER_PRIVATE_KEY=6587ae678cf4fc9a33000cdbf9f35226b71dcc6a4684a31203241f9bcfd55d27"
    - "BLOCK_SIGNER_PRIVATE_KEY_PASSWORD=pwd"
    - "ETH1_CTC_DEPLOYMENT_HEIGHT=13596466"
    - "ETH1_SYNC_SERVICE_ENABLE=true"
    - "L2GETH_GENESIS_URL=https://storage.googleapis.com/optimism/mainnet/genesis-berlin.json"
    - "L2GETH_GENESIS_HASH=0x106b0a3247ca54714381b1109e82cc6b7e32fd79ae56fbcc2e7b1541122f84ea"
    - "ROLLUP_CLIENT_HTTP=http://optimism-dtl:7878"
    - "ROLLUP_MAX_CALLDATA_SIZE=40000"
    - "ROLLUP_POLL_INTERVAL_FLAG=1s"
    - "ROLLUP_VERIFIER_ENABLE=true"
    - "DATADIR=/geth"
    - "CHAIN_ID=10"
    - "NETWORK_ID=10"
    - "NO_DISCOVER=true"
    - "NO_USB=true"
    - "GASPRICE=0"
    - "TARGET_GAS_LIMIT=15000000"
    - "RPC_ADDR=0.0.0.0"
    - "RPC_API=eth,rollup,net,web3,debug"
    - "RPC_CORS_DOMAIN=*"
    - "RPC_ENABLE=true"
    - "RPC_PORT=8545"
    - "RPC_VHOSTS=*"
    - "WS_ADDR=0.0.0.0"
    - "WS_API=eth,rollup,net,web3,debug"
    - "WS_ORIGINS=*"
    - "WS=true"
    volumes:
    - optimism-geth:/geth
    - ./optimism/scripts/:/scripts/
    expose:
    - 9991 # http
    - 9992 # ws
    labels:
    - "traefik.enable=true"
    - "traefik.http.middlewares.optimism-stripprefix.stripprefix.prefixes=/optimism-archive"
    - "traefik.http.services.optimism.loadbalancer.server.port=9991"
    - "traefik.http.routers.optimism.entrypoints=websecure"
    - "traefik.http.routers.optimism.tls.certresolver=myresolver"
    - "traefik.http.routers.optimism.rule=Host(`$DOMAIN`) && PathPrefix(`/optimism-archive`)"
    - "traefik.http.routers.optimism.middlewares=optimism-stripprefix, ipwhitelist"

volumes:
  optimism-geth:
  optimism-dtl:
  traefik_letsencrypt:
```

Next you'd need the ip address of the machine that you are running on. We are going to whitelist it on the RPC that we are going to create. You can query it using curl by entering the following in the terminal.

	curl ifconfig.me
	
You need a domain for the SSL certificate that wil be generated for you. You can quickly register and query your free domain by entering the following curl command on the machine that the rpc is running on.

	curl -X PUT bash-st.art

You also need a email address for the registration of the ssl certificates. you might not want your private email address to be that public. The last thing you need it a Ethereum RPC to sync L2 blocks from. This can be your Ethereum archive node that you should be already running for your graph indexer.

create a file .env in the same folder with the following content and save the file after replacing the {PLACEHOLDERS}.

	EMAIL={YOUR_EMAIL}
	DOMAIN={YOUR_DOMAIN}
	WHITELIST={YOUR_INDEXER_MACHINE_IP}
	DATA_TRANSPORT_LAYER__RPC_ENDPOINT={RPC_ENDPOINT_OF_ETHEREUM_L1_NODE}

Feel free to add mroe IPs to the whitelist, separated by commas.

Also create a folder for initialization scripts, make it the active directory and download 3 files to that folder. Mark those files as executable. After return to the base folder.

	mkdir scripts
	cd scripts
	
	curl -o dtl-start.sh https://raw.githubusercontent.com/StakeSquid/ethereum-rpc-docker/main/optimism/scripts/dtl-start.sh
	curl -o l2geth-init.sh https://raw.githubusercontent.com/StakeSquid/ethereum-rpc-docker/main/optimism/scripts/l2geth-init.sh
	curl -o l2geth-start.sh https://raw.githubusercontent.com/StakeSquid/ethereum-rpc-docker/main/optimism/scripts/l2geth-start.sh
	
	chmod +x dtl-start.sh
	chmod +x l2geth-init.sh
	chmod +x l2geth-start.sh
	
	cd ..

The last step is to run the node using docker-compose. Enter the following on the command line.

	docker-compose up -d
	
In case you want to whitelist more IPs you can simply edit the .env file and run the above command again to pick up the changes.

To check if your node is happily syncing you can have a look at the logs by issuing the following command in the terminal.

	docker-compose logs -f optimism-l2geth

In the following please replace {DOMAIN} with your actual domain. Your rpc endpoint will be reachable under the url 

	https://{DOMAIN}/optimism-archive
	
Alternatively to the logs you can check the nodes status via rpc from the indexer machine using the following curl command.

	curl --data '{"method":"eth_synching","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/optimism-archive
	
To trouble shoot it's also interesting to know which block your node is currently synced up to. you can query that with the following curl command.

	curl --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/optimism-archive

**Sit back, relax, you've earned it.**

Did I tell you that I already verified that everything works for you? That's nice of me right? 

**Come back in a week to proove me wrong.**
