
FROM ubuntu:21.10

COPY ./scripts/init.sh /usr/local/bin/init.sh
RUN chmod +x /usr/local/bin/init.sh

#RUN apt update && apt install -y curl tar gzip

ARG OG_VERSION
ARG ${OG_CHAIN_SPEC:-galileo}
RUN curl -sL https://github.com/0glabs/0gchain-NG/releases/download/v${OG_VERSION}/${OG_CHAIN_SPEC}-v${OG_VERSION}.tar.gz -o /tmp/${OG_CHAIN_SPEC}-v${OG_VERSION}.tar.gz
RUN tar -xzf /tmp/${OG_CHAIN_SPEC}-v${OG_VERSION}.tar.gz -C /tmp
RUN mv /tmp/${OG_CHAIN_SPEC}-v${OG_VERSION} /0g

ENTRYPOINT [ "init.sh" ]