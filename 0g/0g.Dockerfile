
FROM rockylinux:9

COPY ./scripts/init.sh /usr/local/bin/init.sh
RUN chmod +x /usr/local/bin/init.sh

RUN yum install -y curl tar gzip && yum clean all

ARG OG_VERSION
ARG OG_CHAIN_SPEC
RUN curl -sL https://github.com/0glabs/0gchain-NG/releases/download/v${OG_VERSION}/${OG_CHAIN_SPEC}-v${OG_VERSION}.tar.gz -o /tmp/${OG_CHAIN_SPEC}-v${OG_VERSION}.tar.gz
RUN tar -xzf /tmp/${OG_CHAIN_SPEC}-v${OG_VERSION}.tar.gz -C /tmp
RUN mv /tmp/${OG_CHAIN_SPEC}-v${OG_VERSION} /0g

RUN chmod +x /0g/bin/0gchaind
RUN chmod +x /0g/bin/geth

ENTRYPOINT [ "init.sh" ]