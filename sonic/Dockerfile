FROM golang:1.22 as builder

ARG VERSION

RUN apt-get update && apt-get install -y git musl-dev make

RUN cd /go && git clone https://github.com/0xsoniclabs/sonic.git && cd sonic && git fetch --tags && git checkout -b ${VERSION} tags/${VERSION}

WORKDIR /go/sonic

ARG GOPROXY
RUN go mod download
RUN make all

FROM golang:1.22

COPY --from=builder /go/sonic/build/sonicd /usr/local/bin/
COPY --from=builder /go/sonic/build/sonictool /usr/local/bin/

COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 18545 18546 5050 5050/udp

VOLUME /var/sonic

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]