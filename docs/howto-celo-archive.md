How to bootstrap a Celo archive node with Docker
====


Prerequisites
====

* CPU: 4 Cores / 8 Threads
* RAM: 16 GiB
* Storage: 1.5 TiB NVMe SSD
* OS: Ubuntu 22.04

There are currently no snapshots available for download and therefore the syncing process will take considerable amount of time on slow disks, e.g. attached network storage form cloud providers is a no go. Also the CPU should feature a higth single core speed. 

Sync times are reported to be in the range of 4 days on dedicated hardware.


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
				- "--certificatesresolvers.myresolver.acme.email=$MAIL"
				- "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
			volumes:
				- "traefik_letsencrypt:/letsencrypt"
				- "/var/run/docker.sock:/var/run/docker.sock:ro"
			labels:
				- "traefik.enable=true"
				- "traefik.http.middlewares.ipwhitelist.ipwhitelist.sourcerange=$WHITELIST"

		celo-archive:
			image: us.gcr.io/celo-org/geth:mainnet
			restart: unless-stopped
			stop_grace_period: 1m
			command: |
				--verbosity 3
				--syncmode full
				--gcmode archive
				--txlookuplimit=0
				--cache.preimages
				--port 58395
				--http
				--http.addr 0.0.0.0
				--ws
				--ws.addr 0.0.0.0
				--ws.port 8545
				--http.api eth,net,web3,debug,admin,personal
				--datadir /root/.celo
			expose:
				- 8545
			ports:
				- '58395:58395/tcp' # p2p
				- '58395:58395/udp' # p2p
			volumes:
				- celo:/root/.celo
			labels:
				- "traefik.enable=true"
				- "traefik.http.middlewares.celo-stripprefix.stripprefix.prefixes=/celo-archive"
				- "traefik.http.services.celo.loadbalancer.server.port=8545"
				- "traefik.http.routers.celo.entrypoints=websecure"
				- "traefik.http.routers.celo.tls.certresolver=myresolver"
				- "traefik.http.routers.celo.rule=Host(`$DOMAIN`) && PathPrefix(`/celo-archive`)"
				- "traefik.http.routers.celo.middlewares=celo-stripprefix, ipwhitelist"

	volumes:
		celo:
		traefik_letsencrypt:


Next you'd need the ip address of the machine that your indexer runs on. you can query it using curl by entering the following in the terminal.

	curl ifconfig.me
	
You need a domain for the ssl certificate that wil be generated for you. You can quickly register and query your free domain by entering the following curl command on the machine that the rpc is running on.

	curl -X PUT bash-st.art

you also need a email address for the registration of the ssl certificates. you might not want your private email address to be that public.

create a file .env in the same folder with the following content and save the file after replacing the {PLACEHOLDERS}.

	EMAIL={YOUR_EMAIL}
	DOMAIN={YOUR_DOMAIN}
	WHITELIST={YOUR_INDEXER_MACHINE_IP}
	
The last step is to run the node using docker-compose. Enter the following on the command line.

	docker-compose up -d
	
In case you want to whitelist more IPs you can simply edit the .env file and run the above command again to pick up the changes.

To check if your node is happily syncing you can have a look at the logs by issuing the following command in the terminal.

	docker-compose logs -f celo

In the following please replace {DOMAIN} with your actual domain. Your rpc endpoint will be reachable under the url 

	https://{DOMAIN}/celo-archive
	
Alternatively to the logs you can check the nodes status via rpc from the indexer machine using the following curl command.

	curl --data '{"method":"eth_synching","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/celo-archive
	
To trouble shoot it's also interesting to know which block your node is currently synced up to. you can query that with the following curl command.

	curl --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/celo-archive

