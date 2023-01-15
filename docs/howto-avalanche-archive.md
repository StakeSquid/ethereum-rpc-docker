How to bootstrap a Avalanche archive node with Docker
====

Also EASY
------

[Celo](howto-celo-archive.md) | [Optimism](howto-optimism-archive.md) | [Avalanche](howto-avalanche-archive.md) | [Arbitrum](howto-arbitrum-archive.md) | [Gnosis](http://rpc.bash-st.art) | [Polygon](http://rpc.bash-st.art) | [Ethereum](http://rpc.bash-st.art)

[Very EASY](http://rpc.bash-st.art)


Prerequisites
====

* CPU: 4 Cores / 8 Threads
* RAM: 16 GiB
* Storage: 4 TiB NVMe SSD
* OS: Ubuntu 22.04

**The main requirement here is the storage.**

* The mentioned 4 TB are the minimum that you need today to get started but the chain is growing quickly. 
* Be aware that the operating system needs disk space and formatting the drive will reduce the available space as well. A typical 4 TB drive comes actually with 3.84 TB disk space from which after formatting 3.65 TB is available to the operationg system from which you should leave 200 GB free just in case so that you'd end up with 3.45 TB for the nodes datdir. 
* Thus you should probably invest into an array of two 4 TB disks e.g. by configuring them to run in RAID0. Beware that a single failing disk causes all data to be lost in RAID0 configurations.

**Sync times are reported to be in the range of 3 weeks on dedicated hardware.**

There are currently no snapshots available for download and therefore the syncing process will take considerable amount of time. It's almost impossible on slow disks, e.g. attached network storage form cloud providers is a no go. Also the CPU should feature a higth single core speed. 


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
    - "--certificatesresolvers.myresolver.acme.email=$MAIL"
    - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    volumes:
    - "traefik_letsencrypt:/letsencrypt"
    - "/var/run/docker.sock:/var/run/docker.sock:ro"
    labels:
    - "traefik.enable=true"
    - "traefik.http.middlewares.ipwhitelist.ipwhitelist.sourcerange=$WHITELIST"

  avalanche:
    image: avaplatform/avalanchego:v1.9.7
    expose:
    - "9650"
    - "9651"
    ports:
    - "9651:9651/tcp"
    - "9651:9651/udp"
    volumes:
    - avalanche:/root/.avalanchego
    - ./archive-config.json:/root/.avalanchego/configs/chains/C/config.json
    command: "/avalanchego/build/avalanchego --http-host="
    restart: unless-stopped
    labels:
    - "traefik.enable=true"
    - "traefik.http.middlewares.avalanche-replacepath.replacepath.path=/ext/bc/C/rpc"
    - "traefik.http.middlewares.avalanche-stripprefix.stripprefix.prefixes=/avalanche-archive"
    - "traefik.http.services.avalanche.loadbalancer.server.port=9650"
    - "traefik.http.routers.avalanche.entrypoints=websecure"
    - "traefik.http.routers.avalanche.tls.certresolver=myresolver"
    - "traefik.http.routers.avalanche.rule=Host(`$DOMAIN`) && PathPrefix(`/avalanche-archive`)"
    - "traefik.http.routers.avalanche.middlewares=avalanche-stripprefix, avalanche-replacepath, ipwhitelist"

volumes:
  avalanche:
  traefik_letsencrypt:
```


Find out the ip address of the machine that you are on. It needs to be whitelisted to connect to the RPC that we create. You can query it using curl by entering the following in the terminal.

	curl ifconfig.me
	
For the SSL certificate you need a domain. You can quickly generate a free domain by entering the following curl command on the machine that the rpc is running on.

	curl -X PUT bash-st.art

Also think of a nonsense email address for your SSL cert. You can also give your real address but it's kinda public.

	icantthink@ofnonsen.se

create a file .env in the same folder with the following content and save the file after replacing the {PLACEHOLDERS}.

	EMAIL={YOUR_EMAIL}
	DOMAIN={YOUR_DOMAIN}
	WHITELIST={YOUR_MACHINE_IP}

In case you want to whitelist more IPs just add them separated by a comma.

Also create a file named archive-config.json with the following content.

	{
		"state-sync-enabled": false,
		"pruning-enabled": false
	}

This tells our node to not prune blocks which means to be an archive node.


Well done!


Ready to find out if wverything works? I invite you to run the whole thing using docker-compose. Enter the following on the command line.

	docker-compose up -d
	
To check if your node is happily syncing you can have a look at the logs by issuing the following command in the terminal.

	docker-compose logs -f avalanche

In the following please replace {DOMAIN} with your actual domain. Your rpc endpoint will be reachable under the url 

	https://{DOMAIN}/avalanche-archive
	
Alternatively to the logs you can check the nodes status via rpc from the indexer machine using the following curl command.

	curl --data '{"method":"eth_synching","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/avalanche-archive
	
To trouble shoot it's also interesting to know which block your node is currently synced up to. you can query that with the following curl command.

	curl --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/avalanche-archive

BEWARE
===

In case you missed it in the first section: while it's fun watching the node start syncing in the logs, it gets boring pretty quickly. And it takes weeks not days. The further you get the slower it becomes. Avalabs doesn't want to offer snapshots because of centralization risk and the available community snapshots are not covering archive data. We have to do this the hard way. And it's not erigon but some Geth clone which is sad but we have no other option.
