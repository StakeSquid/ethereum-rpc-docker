FROM debian
RUN apt-get update && apt-get install -y wget
RUN wget -O- https://github.com/streamingfast/firehose-ethereum/releases/download/v1.4.13/firehose-ethereum_linux_x86_64.tar.gz | tar xvz -C /usr/bin
RUN wget https://github.com/streamingfast/go-ethereum/releases/download/geth-v1.12.1-fh2.3/geth_linux -O /usr/bin/geth
RUN chmod +x /usr/bin/geth

ENTRYPOINT ["fireeth"]