FROM golang:1.19-alpine as builder
RUN apk add --no-cache make g++ gcc musl-dev linux-headers git
ARG ERIGON_VERSION=v0.0.5
ARG ERIGON_REPOSITORY=https://github.com/maticnetwork/erigon.git

RUN git clone --recurse-submodules -j8 $ERIGON_REPOSITORY

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

COPY ./scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod u+x /usr/local/bin/entrypoint.sh
ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
