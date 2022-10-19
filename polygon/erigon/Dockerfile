# Build Bor in a stock Go builder container
FROM golang:1.19-alpine as builder

# Install packages we need
RUN apk add --no-cache make g++ gcc musl-dev linux-headers git

# Grab ERIGON_VERSION from Build Args
ARG ERIGON_VERSION

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

# Set entrypoint
COPY ./scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod u+x /usr/local/bin/entrypoint.sh
ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
