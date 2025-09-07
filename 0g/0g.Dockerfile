
FROM ubuntu:21.10

COPY ./scripts/init.sh /usr/local/bin/init.sh
RUN chmod +x /usr/local/bin/init.sh

RUN apt update && apt install -y curl tar gzip

ARG 0G_VERSION
ARG ${0G_CHAIN_SPEC:-galileo}
RUN curl -sL https://github.com/0glabs/0gchain-NG/releases/download/v${0G_VERSION}/${0G_CHAIN_SPEC}-v${0G_VERSION}.tar.gz -o /tmp/${0G_CHAIN_SPEC}-v${0G_VERSION}.tar.gz
RUN tar -xzf /tmp/${0G_CHAIN_SPEC}-v${0G_VERSION}.tar.gz -C /tmp
RUN mv /tmp/${0G_CHAIN_SPEC}-v${0G_VERSION} /0g

ENTRYPOINT [ "init.sh" ]