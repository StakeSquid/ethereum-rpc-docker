
FROM rockylinux:9

COPY ./scripts/init.sh /usr/local/bin/init.sh
RUN chmod +x /usr/local/bin/init.sh

#RUN yum install -y curl tar gzip && yum clean all

ARG ZERO_GRAVITY_VERSION
ARG ZERO_GRAVITY_CHAIN_SPEC
RUN if [ "${ZERO_GRAVITY_CHAIN_SPEC}" = "aristotle" ]; then \
        curl -sL https://github.com/0gfoundation/0gchain-Aristotle/releases/download/${ZERO_GRAVITY_VERSION}/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz -o /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz; \
    else \
        curl -sL https://github.com/0glabs/0gchain-NG/releases/download/v${ZERO_GRAVITY_VERSION}/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz -o /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz; \
    fi
RUN tar -xzf /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz -C /tmp
RUN mv /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}/rpc /0g

RUN chmod +x /0g/bin/0gchaind
RUN chmod +x /0g/bin/geth

ENTRYPOINT [ "init.sh" ]