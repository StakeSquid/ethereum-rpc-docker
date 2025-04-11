FROM golang:1.22 as op

WORKDIR /app

ARG OP_REPO=https://github.com/ethereum-optimism/optimism.git
ARG OP_VERSION=v1.12.2
ARG OP_PATCH

RUN curl -fsSL https://github.com/casey/just/releases/download/1.38.0/just-1.38.0-x86_64-unknown-linux-musl.tar.gz | tar -xzf - -C /usr/local/bin

RUN git clone $OP_REPO --branch op-node/$OP_VERSION --single-branch . && \
    git switch -c branch-$OP_VERSION

# Apply patch if provided and valid
COPY ${OP_PATCH:-empty.patch} /tmp/my-patch.patch
RUN if [ -n "$OP_PATCH" ]; then \
      echo "Using patch file: $OP_PATCH"; \
      cd op-node && git apply --verbose /tmp/my-patch.patch || \
      (echo "Patch failed to apply!" && exit 1); \
    else \
      echo "No patch file provided. Skipping."; \
    fi

RUN cd op-node && \
    just op-node

FROM golang:1.22

# not sure why that was in here ... maybe some script expecting it to clone peers ...
# but it broke the build on a server in japan for whatever reason. 
RUN apt-get update && \
    apt-get install -y jq curl && \
    rm -rf /var/lib/apt/lists

WORKDIR /app

COPY --from=op /app/op-node/bin/op-node /usr/local/bin/op-node

ENTRYPOINT ["op-node"]
