EASY: How to bootstrap a Polygon archive node in 3 steps
====

Also EASY
------

[Celo](howto-celo-archive.md) | [Optimism](howto-optimism-archive.md) | [Avalanche](howto-avalanche-archive.md) | [Arbitrum](howto-arbitrum-archive.md) | [Gnosis](http://rpc.bash-st.art) | [Polygon](howto-polygon-archive.md) | [Ethereum](http://rpc.bash-st.art)

[Very EASY](http://rpc.bash-st.art)


Prerequisites
====

* CPU: 4 Cores / 8 Threads
* RAM: 16 GiB
* Storage: 6.5 TiB NVMe SSD
* OS: Ubuntu 22.04

**The main requirement here is the storage.**

* The mentioned 6.5 TB are the minimum that you need today to get started but the chain is growing quickly. 
* Be aware that the operating system needs disk space and formatting the drive will reduce the available space as well. A typical 4 TB drive comes actually with 3.84 TB disk space from which after formatting 3.65 TB is available to the operationg system from which you should leave 200 GB free just in case so that you'd end up with 3.45 TB for the nodes datdir. 
* Thus you should probably invest into an array of three 4 TB disks e.g. by configuring them to run in RAID0. Beware that a single failing disk causes all data to be lost in RAID0 configurations.

**Sync times are reported to be in the range of 3 days using the official snapshot.**


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

  erigon-polygon:
    build:
      args:
        ERIGON_VERSION: v0.0.5
      context: ./erigon-polygon
      dockerfile: Dockerfile
    environment:
    - SNAPSHOT_URL=${SNAPSHOT_URL:-https://matic-blockchain-snapshots.s3-accelerate.amazonaws.com/matic-mainnet/erigon-archive-snapshot-2023-01-12.tar.gz}
    - BOOTSTRAP=1
    - HEIMDALLD=${HEIMDALLD:-http://heimdalld:26657}
    - HEIMDALLR=${HEIMDALLR:-http://heimdallr:1317}
    volumes:
    - "polygon-archive_data:/datadir"
    ports:
    - "27113:27113"
    - "27113:27113/udp"
    restart: unless-stopped
    stop_grace_period: 1m
    labels:
    - "traefik.enable=true"
    - "traefik.http.middlewares.erigon-polygon-stripprefix.stripprefix.prefixes=/polygon-archive"
    - "traefik.http.services.erigon-polygon.loadbalancer.server.port=8545"
    - "traefik.http.routers.erigon-polygon.entrypoints=websecure"
    - "traefik.http.routers.erigon-polygon.tls.certresolver=myresolver"
    - "traefik.http.routers.erigon-polygon.rule=Host(`$DOMAIN`) && PathPrefix(`/polygon-archive`)"
    - "traefik.http.routers.erigon-polygon.middlewares=erigon-polygon-stripprefix, ipwhitelist"

volumes:
    polygon-archive_data:
    traefik_letsencrypt:
```

Make a Dockerfile in a subfolder. First create a folder and open a new file.

	mkdir erigon-polygon
	nano erigon-polygon/Dockerfile

Then copy-paste the following and close and save the file.

```
FROM golang:1.19-alpine as builder
RUN apk add --no-cache make g++ gcc musl-dev linux-headers git
ARG ERIGON_VERSION=v0.0.4

RUN git clone --recurse-submodules -j8 https://github.com/maticnetwork/erigon.git

WORKDIR ./erigon

RUN git checkout ${ERIGON_VERSION}

RUN make erigon

FROM alpine:latest

RUN apk add --no-cache ca-certificates curl jq libstdc++ libgcc
COPY --from=builder /go/erigon/build/bin/erigon /usr/local/bin/

ENV HEIMDALLD=https://polygon-mainnet-rpc.allthatnode.com:26657
ENV HEIMDALLR=https://polygon-mainnet-rpc.allthatnode.com:1317

EXPOSE 27113
EXPOSE 8545
EXPOSE 6060
EXPOSE 6061

COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod u+x /usr/local/bin/entrypoint.sh
ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
```

You might notice that we define a entrypoint script in the Dockerfile above that we also need to create locally by entering in the console

	nano erigon-polygon/entrypoint.sh
	
And copy pasting below blob into that new editor window

```
#!/bin/sh

set -e

ERIGON_HOME=/datadir

if [ "${BOOTSTRAP}" == 1 ] && [ -n "${SNAPSHOT_URL}" ] && [ ! -f "${ERIGON_HOME}/bootstrapped" ];
then
  echo "downloading snapshot from ${SNAPSHOT_URL}"
  mkdir -p ${ERIGON_HOME:-/datadir}
  wget --tries=0 -O - "${SNAPSHOT_URL}" | tar -xz -C ${ERIGON_HOME:-/datadir} && touch ${ERIGON_HOME:-/datadir}/bootstrapped
fi

READY=$(curl -s ${HEIMDALLD:-http://heimdalld:26657}/status | jq '.result.sync_info.catching_up')
while [[ "${READY}" != "false" ]];
do
    echo "Waiting for heimdalld to catch up."
    sleep 30
    READY=$(curl -s ${HEIMDALLD:-http://heimdalld:26657}/status | jq '.result.sync_info.catching_up')
done

exec erigon \
      --chain=bor-mainnet \
      --bor.heimdall=${HEIMDALLR:-http://heimdallr:1317} \
      --datadir=${ERIGON_HOME} \
      --http --http.addr="0.0.0.0" --http.port="8545" --http.compression --http.vhosts="*" --http.corsdomain="*" --http.api="eth,debug,net,trace,web3,erigon,bor" \
      --ws --ws.compression \
      --port=27113
      --snap.keepblocks=true \
      --snapshots="true" \
      --torrent.upload.rate="1250mb" --torrent.download.rate="1250mb" \
      --metrics --metrics.addr=0.0.0.0 --metrics.port=6060 \
      --pprof --pprof.addr=0.0.0.0 --pprof.port=6061

```

That was a lot of work but you are not done yet!

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

To save some disk space and the requirement for a Ethereum RPC endpoint we used a shady trick here. Polygon has another part called Heimdall that is important for consensus. The configuration hardcoded a public endpoint to connect our erigon to. you can configure it right in the .env file by adding the following 2 variables if you ever need to.

	HEIMDALLD=https://polygon-mainnet-rpc.allthatnode.com:26657
	HEIMDALLR=https://polygon-mainnet-rpc.allthatnode.com:1317
	
Those are not needed right now as they are just the defaults we chose. We took it from [here](https://www.allthatnode.com/polygon.dsrv). Should they ever cease to function we don't have a replacement available right now. You can always run heimdalld and heimdallr locally which would consume another 300 GB of disk space. You also need a Ethereum RPC which can be your Mainnet node.

You might also want to use a more current snapshot to bootstrap your node. You can add this to your .env file.

	SNAPSHOT_URL=https://matic-blockchain-snapshots.s3-accelerate.amazonaws.com/matic-mainnet/erigon-archive-snapshot-2023-01-12.tar.gz
	
Replace the URL with the current snapshots that you find [here](https://snapshot.polygon.technology/)

You read a lot. Well done!


Ready to find out if wverything works? I invite you to run the whole thing using docker-compose. Enter the following on the command line.

	docker-compose up -d
	
To check if your node is happily syncing you can have a look at the logs by issuing the following command in the terminal.

	docker-compose logs -f erigon-polygon

In the following please replace {DOMAIN} with your actual domain. Your rpc endpoint will be reachable under the url 

	https://{DOMAIN}/polygon-archive
	
Alternatively to the logs you can check the nodes status via rpc from the indexer machine using the following curl command.

	curl --data '{"method":"eth_synching","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/polygon-archive
	
To trouble shoot it's also interesting to know which block your node is currently synced up to. you can query that with the following curl command.

	curl --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST http://{DOMAIN}/polygon-archive


