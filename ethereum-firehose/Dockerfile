FROM ubuntu:24.04

# Install required tools
RUN apt-get update && apt-get install -y wget curl jq tar

# Set environment variables for URLs
ARG FIREHOSE_ETHEREUM
ARG FIREHOSE_GETH_VERSION

# Download and extract the latest firehose-ethereum
RUN    wget -O- https://github.com/streamingfast/firehose-ethereum/releases/download/${FIREHOSE_ETHEREUM}/firehose-ethereum_linux_x86_64.tar.gz | tar xvz -C /usr/bin

# Download the latest go-ethereum (geth)
RUN    wget https://github.com/streamingfast/go-ethereum/releases/download/geth-${FIREHOSE_GETH_VERSION}/geth_linux -O /usr/bin/geth && chmod +x /usr/bin/geth

ENTRYPOINT ["fireeth"]


