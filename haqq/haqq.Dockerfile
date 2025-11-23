ARG HAQQ_HAQQ_IMAGE
ARG HAQQ_HAQQ_VERSION
FROM ${HAQQ_HAQQ_IMAGE}:${HAQQ_HAQQ_VERSION}

USER root
COPY ./scripts/init.sh /usr/local/bin/init.sh

RUN chmod +x /usr/local/bin/init.sh

ENTRYPOINT [ "init.sh" ]