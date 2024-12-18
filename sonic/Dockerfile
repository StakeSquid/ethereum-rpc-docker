# Running Sonic in Docker is Experimental - not recommended for production use!

# Example of usage:
# docker build -t sonic .
# docker run --name sonic1 --entrypoint sonictool sonic --datadir=/var/sonic genesis fake 1
# docker run --volumes-from sonic1 -p 5050:5050 -p 5050:5050/udp -p 18545:18545 sonic --fakenet 1/1 --http --http.addr=0.0.0.0

FROM golang:1.22 as builder

RUN apt-get update && apt-get install -y git musl-dev make

RUN cd /go && git clone https://github.com/Fantom-foundation/Sonic.git && git fetch --tags && git checkout -b v2.0.1 tags/v2.0.1

WORKDIR /go/Sonic

ARG GOPROXY
RUN go mod download
RUN make all

FROM golang:1.22

COPY --from=builder /go/Sonic/build/sonicd /usr/local/bin/
COPY --from=builder /go/Sonic/build/sonictool /usr/local/bin/

COPY ./entrypoint.sh /entrypoint.sh

EXPOSE 18545 18546 5050 5050/udp

VOLUME /var/sonic

ENTRYPOINT ["bash", "entrypoint.sh"]