ARG SEI_IMAGE
ARG SEI_VERSION
FROM ${SEI_IMAGE}:${SEI_VERSION}

COPY ./scripts/init.sh /usr/local/bin/init.sh

RUN chmod +x /usr/local/bin/init.sh

ENTRYPOINT [ "init.sh" ]