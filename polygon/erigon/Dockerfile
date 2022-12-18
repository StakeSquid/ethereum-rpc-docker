# Build Bor in a stock Go builder container
FROM golang:1.19-alpine as builder

# Install packages we need
RUN apk add --no-cache make g++ gcc musl-dev linux-headers git

# Grab ERIGON_VERSION from Build Args
ARG ERIGON_VERSION=v0.0.4

# Clone the repo to that folder
RUN git clone --recurse-submodules -j8 https://github.com/maticnetwork/erigon.git

# change into repo
WORKDIR ./erigon

# checkout version
RUN git checkout ${ERIGON_VERSION}

# Build Bor
RUN make erigon

# Pull Bor into a second stage deploy alpine container
FROM alpine:latest

RUN apk add --no-cache ca-certificates curl jq libstdc++ libgcc
COPY --from=builder /go/erigon/build/bin/erigon /usr/local/bin/

# ENV HEIMDALLD=http://heimdalld:26657
# ENV HEIMDALLR=http://heimdallr:1317

ENV HEIMDALLD=https://polygon-mainnet-rpc.allthatnode.com:26657
ENV HEIMDALLR=https://polygon-mainnet-rpc.allthatnode.com:1317

# P2P
EXPOSE 27113

# HTTP / WS
EXPOSE 8545

# Metrics
EXPOSE 6060

# PProf
EXPOSE 6061


# Set entrypoint
COPY ./scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod u+x /usr/local/bin/entrypoint.sh
ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
