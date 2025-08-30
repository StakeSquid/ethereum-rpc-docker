# syntax = docker/dockerfile:1.2
ARG REPO=https://github.com/erigontech/erigon.git
ARG VERSION=v3.0.7
ARG COMMIT=${COMMIT:-${VERSION}}

FROM docker.io/library/golang:1.24.1-alpine3.20 AS builder

ARG REPO
ARG COMMIT

RUN apk --no-cache add build-base linux-headers git bash ca-certificates libstdc++

WORKDIR /app

RUN git clone --recursive ${REPO} . && \
    git checkout ${COMMIT}

RUN go mod download

RUN --mount=type=cache,target=/root/.cache \
    --mount=type=cache,target=/tmp/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    make BUILD_TAGS=nosqlite,noboltdb,nosilkworm all


# FROM docker.io/library/golang:1.24.1-alpine3.20 AS tools-builder

# ARG REPO
# ARG COMMIT

# RUN apk --no-cache add build-base linux-headers git bash ca-certificates libstdc++

# WORKDIR /app

# RUN git clone --recursive ${REPO} . && \
#     git checkout ${COMMIT}

# RUN mkdir -p /app/build/bin

# RUN --mount=type=cache,target=/root/.cache \
#     --mount=type=cache,target=/tmp/go-build \
#     --mount=type=cache,target=/go/pkg/mod \
#     make db-tools


FROM docker.io/library/alpine:3.19

RUN apk add --no-cache ca-certificates libstdc++ tzdata
RUN apk add --no-cache curl jq bind-tools

ARG UID=1000
ARG GID=1000
RUN adduser -D -u $UID -g $GID erigon
USER erigon
RUN mkdir -p ~/.local/share/erigon

# Copy MDBX tools
# COPY --from=tools-builder /app/build/bin/mdbx_* /usr/local/bin/

# Copy Erigon binaries
COPY --from=builder /app/build/bin/devnet /usr/local/bin/devnet
COPY --from=builder /app/build/bin/downloader /usr/local/bin/downloader
COPY --from=builder /app/build/bin/erigon /usr/local/bin/erigon
COPY --from=builder /app/build/bin/evm /usr/local/bin/evm
COPY --from=builder /app/build/bin/hack /usr/local/bin/hack
COPY --from=builder /app/build/bin/integration /usr/local/bin/integration
COPY --from=builder /app/build/bin/observer /usr/local/bin/observer
COPY --from=builder /app/build/bin/pics /usr/local/bin/pics
COPY --from=builder /app/build/bin/rpcdaemon /usr/local/bin/rpcdaemon
COPY --from=builder /app/build/bin/rpctest /usr/local/bin/rpctest
COPY --from=builder /app/build/bin/sentinel /usr/local/bin/sentinel
COPY --from=builder /app/build/bin/sentry /usr/local/bin/sentry
COPY --from=builder /app/build/bin/state /usr/local/bin/state
COPY --from=builder /app/build/bin/txpool /usr/local/bin/txpool
COPY --from=builder /app/build/bin/verkle /usr/local/bin/verkle
COPY --from=builder /app/build/bin/caplin /usr/local/bin/caplin

EXPOSE 8545 \
    8551 \
    8546 \
    30303 \
    30303/udp \
    42069 \
    42069/udp \
    8080 \
    9090 \
    6060

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION
LABEL org.label-schema.build-date=$BUILD_DATE \
    org.label-schema.description="Erigon Ethereum Client" \
    org.label-schema.name="Erigon" \
    org.label-schema.schema-version="1.0" \
    org.label-schema.url="https://torquem.ch" \
    org.label-schema.vcs-ref=$VCS_REF \
    org.label-schema.vcs-url=$REPO \
    org.label-schema.vendor="Torquem" \
    org.label-schema.version=$VERSION

ENTRYPOINT ["erigon"]
