FROM golang:1.22 as geth

WORKDIR /app

ARG GETH_REPO=https://github.com/ethereum-optimism/op-geth.git
ARG GETH_VERSION=v1.101503.1

# avoid depth=1, so the geth build can read tags
RUN git clone $GETH_REPO --branch $GETH_VERSION --single-branch . && \
    git switch -c branch-$GETH_VERSION

RUN go run build/ci.go install -static ./cmd/geth

FROM golang:1.22

# not sure why that was in here ... maybe some script expecting it to clone peers ...
# but it broke the build on a server in japan for whatever reason. 
RUN apt-get update && \
    apt-get install -y jq curl && \
    rm -rf /var/lib/apt/lists

WORKDIR /app

COPY --from=geth /app/build/bin/geth /usr/local/bin/geth

ENTRYPOINT ["geth"]
