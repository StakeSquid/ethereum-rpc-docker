How to bootstrap a Arbitrum archive node with Docker
====


Prerequisites
====

* CPU: 4 Cores / 8 Threads
* RAM: 16 GiB
* Storage: 2.5 TiB NVMe SSD
* OS: Ubuntu 22.04

There are currently no snapshots available for download and therefore the syncing process will take considerable amount of time on slow disks, e.g. attached network storage form cloud providers is a no go. Also the CPU should feature a higth single core speed. 

Sync times are reported to be in the range of 1 week on dedicated hardware. The node consists of 2 parts, the classic part and the nitro hardfork. The classic part is only required to request archive data for blocks before the hardfork and takes the aformentioned 1 weeks to sync from scratch. The nitro history is shorter and can be quickly synced within 3 days.


Install Required Software
===

	sudo apt-get install docker.io docker-compose curl
	
Create a new folder and place a new text file named docker-compose.yml into it.

	mkdir ~/rpc
	cd ~/rpc
	nano docker-compose.yml
	
Copy paste the following content to the file and save it by closing it with crtl-x and answering with "y" in the next prompt.

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
				- --init.url=empty
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
			expose:
				- 8547
				- 8548
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

Next you'd need the ip address of the machine that your indexer runs on. you can query it using curl by entering the following in the terminal.

	curl ifconfig.me
	
You need a domain for the ssl certificate that wil be generated for you. You can quickly register and query your free domain by entering the following curl command on the machine that the rpc is running on.

	curl -X PUT bash-st.art

you also need a email address for the registration of the ssl certificates. you might not want your private email address to be that public. The last thing you need it a Ethereum RPC to sync L2 blocks from. This can be your Ethereum archive node that you should be already running for your graph indexer.

create a file .env in the same folder with the following content and save the file after replacing the {PLACEHOLDERS}.

	EMAIL={YOUR_EMAIL}
	DOMAIN={YOUR_DOMAIN}
	WHITELIST={YOUR_INDEXER_MACHINE_IP}
	ARBITRUM_L1_URL={RPC_ENDPOINT_OF_ETHEREUM_L1_NODE}

The last step is to run the node using docker-compose. Enter the following on the command line.

	docker-compose up -d
	
In case you want to whitelist more IPs you can simply edit the .env file and run the above command again to pick up the changes.

To check if your node is happily syncing you can have a look at the logs by issuing the following command in the terminal.

	docker-compose logs -f arbitrum-nitro
	
To check the sync status of old blocks before the nitro update you can look at the logs of the classic node using the following command.

	docker-compose logs -f arbitrum-classic

In the following please replace {DOMAIN} with your actual domain. Your rpc endpoint will be reachable under the url 

	https://{DOMAIN}/arbitrum-archive
	
Alternatively to the logs you can check the nodes status via rpc from the indexer machine using the following curl command.

	curl --data '{"method":"eth_synching","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/arbitrum-archive
	
To trouble shoot it's also interesting to know which block your node is currently synced up to. you can query that with the following curl command.

	curl --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/arbitrum-archive

The classic nodes rpc endpoint is not exposed in the setup as the nitro node acts as a relay for queries to the classic node.
