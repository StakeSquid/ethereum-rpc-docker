FROM docker.io/library/golang:1.20-alpine3.17 AS builder
RUN apk add --no-cache make g++ gcc musl-dev linux-headers git
ARG ERIGON_VERSION=v2.48.1
ARG ERIGON_REPOSITORY=https://github.com/ledgerwatch/erigon.git

RUN git clone --recurse-submodules -j8 $ERIGON_REPOSITORY

WORKDIR ./erigon

RUN git checkout ${ERIGON_VERSION}

RUN make erigon

FROM alpine:latest

RUN apk add --no-cache ca-certificates curl jq libstdc++ libgcc
COPY --from=builder /go/erigon/build/bin/erigon /usr/local/bin/

COPY ./scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod u+x /usr/local/bin/entrypoint.sh
ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
