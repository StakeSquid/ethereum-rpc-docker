FROM ubuntu:24.04

ARG CHAIN_NAME=Testnet

# Define URLs as environment variables
ARG PUB_KEY_URL=https://raw.githubusercontent.com/hyperliquid-dex/node/refs/heads/main/pub_key.asc
ARG HL_VISOR_URL_TESTNET=https://binaries.hyperliquid-testnet.xyz/Testnet/hl-visor
ARG HL_VISOR_URL_MAINNET=https://binaries.hyperliquid.xyz/Mainnet/hl-visor

WORKDIR /root

# Install required tools including tini
RUN apt-get update && \
    apt-get install -y curl gnupg gawk tini && \
    rm -rf /var/lib/apt/lists/*

RUN curl -o /root/pub_key.asc $PUB_KEY_URL \
    && gpg --import /root/pub_key.asc

# Configure chain to testnet
RUN echo "{\"chain\": \"${CHAIN_NAME}\"}" > /root/visor.json

RUN echo '#!/bin/bash\n\
IPS=$(echo "$ROOT_NODE_IPS" | tr "," "\n" | awk \047{print "{\"Ip\": \""$1"\"}"}\047 | paste -sd,)\n\
cat > /root/override_gossip_config.json << EOF\n\
{"root_node_ips": [$IPS], "try_new_peers": false, "chain": "'${CHAIN_NAME}'"}\n\
EOF\n\
exec /root/hl-visor run-non-validator --replica-cmds-style recent-actions --serve-evm-rpc' > /root/entrypoint.sh && \
chmod +x /root/entrypoint.sh

# Download and verify hl-visor binary
RUN if [ "$CHAIN_NAME" = "Testnet" ]; then \
      curl -o /root/hl-visor $HL_VISOR_URL_TESTNET; \
    else \
      curl -o /root/hl-visor $HL_VISOR_URL_MAINNET; \
    fi \
    && chmod +x /root/hl-visor \
    && mkdir -p /root/hl/data
    
VOLUME /root/hl/data

# Expose gossip ports
EXPOSE 4000-4010

# Run a non-validating node with tini as init
ENTRYPOINT ["tini", "--", "/root/entrypoint.sh"]