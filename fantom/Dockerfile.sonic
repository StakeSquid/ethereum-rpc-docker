FROM golang:1.22 as builder

ARG VERSION
ARG REPO

RUN apt-get update && apt-get install -y git musl-dev make

RUN cd /go && git clone ${REPO:-https://github.com/Fantom-foundation/sonic.git} sonic && cd sonic && git fetch --tags && git checkout -b ${VERSION} tags/${VERSION}

WORKDIR /go/sonic

ARG GOPROXY
RUN go mod download
RUN make all

FROM golang:1.22

COPY --from=builder /go/sonic/build/sonicd /usr/local/bin/
COPY --from=builder /go/sonic/build/sonictool /usr/local/bin/

COPY ./scripts/entrypoint.sonic.sh /usr/local/bin/entrypoint.sh

VOLUME /var/sonic

RUN chmod u+x /usr/local/bin/entrypoint.sh
ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
