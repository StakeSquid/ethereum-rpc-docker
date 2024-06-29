FROM golang:1.21 as op

WORKDIR /app

ARG OP_REPO=https://github.com/ethereum-optimism/optimism.git
ARG OP_VERSION=v1.7.7
# for verification:


RUN git clone $OP_REPO --branch op-node/$OP_VERSION --single-branch . && \
    git switch -c branch-$OP_VERSION


RUN cd op-node && \
    make op-node

FROM golang:1.21 as geth

WORKDIR /app

ARG GETH_REPO=https://github.com/ethereum-optimism/op-geth.git
ARG GETH_VERSION=v1.101315.2

# avoid depth=1, so the geth build can read tags
RUN git clone $GETH_REPO --branch $GETH_VERSION --single-branch . && \
    git switch -c branch-$GETH_VERSION

RUN go run build/ci.go install -static ./cmd/geth

FROM golang:1.21

RUN apt-get update && \
    apt-get install -y jq curl && \
    rm -rf /var/lib/apt/lists

WORKDIR /app

COPY --from=op /app/op-node/bin/op-node ./
COPY --from=geth /app/build/bin/geth ./
COPY geth-entrypoint .
COPY op-node-entrypoint .
COPY sepolia ./sepolia
COPY mainnet ./mainnet