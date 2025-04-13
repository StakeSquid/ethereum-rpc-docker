ARG BEACONKIT_IMAGE
ARG BEACONKIT_VERSION
FROM ${BEACONKIT_IMAGE}:${BEACONKIT_VERSION}

COPY ./scripts/init.sh /usr/local/bin/init.sh

RUN chmod +x /usr/local/bin/init.sh

ENTRYPOINT [ "init.sh" ]