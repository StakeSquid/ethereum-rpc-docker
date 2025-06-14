FROM golang:1.24 as builder

ARG VERSION
ARG COMMIT
ARG REPO
ARG PATCH

RUN apt-get update && apt-get install -y git musl-dev make

RUN cd /go && git clone ${REPO:-https://github.com/0xsoniclabs/sonic.git} sonic && cd sonic && git fetch --tags 

WORKDIR /go/sonic

RUN if [ -n "$COMMIT" ]; then \
      git checkout -b ${VERSION} ${COMMIT}; \
    else \
      git checkout -b ${VERSION} tags/${VERSION}; \
    fi

COPY ${PATCH:-empty.patch} /tmp/my-patch.patch

RUN if [ -n "$PATCH" ]; then \
      echo "Using patch file: $PATCH"; \
      git apply --verbose /tmp/my-patch.patch || \
      (echo "Patch failed to apply!" && exit 1); \
    else \
      echo "No patch file provided. Skipping."; \
    fi


ARG GOPROXY
RUN go mod download
RUN make all

FROM golang:1.24

COPY --from=builder /go/sonic/build/sonicd /usr/local/bin/
COPY --from=builder /go/sonic/build/sonictool /usr/local/bin/

COPY ./scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 18545 18546 5050 5050/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]