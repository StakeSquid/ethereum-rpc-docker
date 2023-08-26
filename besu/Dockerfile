ARG UPSTREAM_VERSION

FROM hyperledger/besu:${UPSTREAM_VERSION}

USER root

RUN mkdir /var/lib/besu
RUN chown -R besu:besu /var/lib/besu

USER besu

ENTRYPOINT ["besu"]