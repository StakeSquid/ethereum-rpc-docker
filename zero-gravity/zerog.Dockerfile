
FROM rockylinux:9

COPY ./scripts/init.sh /usr/local/bin/init.sh
RUN chmod +x /usr/local/bin/init.sh

#RUN yum install -y curl tar gzip && yum clean all

ARG ZERO_GRAVITY_VERSION
ARG ZERO_GRAVITY_CHAIN_SPEC
RUN if [ "${ZERO_GRAVITY_CHAIN_SPEC}" = "aristotle" ]; then \
        curl -sL https://github.com/0gfoundation/0gchain-Aristotle/releases/download/${ZERO_GRAVITY_VERSION}/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz -o /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz; \
    else \
        curl -sL https://github.com/0gfoundation/0gchain-NG/releases/download/v${ZERO_GRAVITY_VERSION}/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz -o /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz; \
    fi
RUN tar -xzf /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}.tar.gz -C /tmp
RUN if [ "${ZERO_GRAVITY_CHAIN_SPEC}" = "galileo" ]; then \
        mv /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}/rpc /0g; \
    else \
        mkdir -p /0g && \
        cp -a /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}/* /0g/ 2>/dev/null || true; \
        cp -a /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}/.[^.]* /0g/ 2>/dev/null || true; \
        rm -rf /tmp/${ZERO_GRAVITY_CHAIN_SPEC}-v${ZERO_GRAVITY_VERSION}; \
    fi

RUN chmod +x /0g/bin/0gchaind
RUN chmod +x /0g/bin/geth

ENTRYPOINT [ "init.sh" ]