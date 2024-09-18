FROM docker.io/library/golang:1.22-alpine3.20.1 AS builder
RUN apk add --no-cache make g++ gcc musl-dev linux-headers git
ARG ERIGON_VERSION=2.60.8
ARG ERIGON_REPOSITORY=https://github.com/erigontech/erigon.git

RUN git clone --branch release/$ERIGON_VERSION --single-branch $ERIGON_REPOSITORY

WORKDIR ./erigon

RUN make erigon

FROM alpine:latest

RUN apk add --no-cache ca-certificates curl jq libstdc++ libgcc
COPY --from=builder /go/erigon/build/bin/erigon /usr/local/bin/

COPY ./scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod u+x /usr/local/bin/entrypoint.sh
ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
