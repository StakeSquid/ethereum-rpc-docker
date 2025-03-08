ARG UPSTREAM_VERSION

FROM statusim/nimbus-eth2:multiarch-${UPSTREAM_VERSION}

USER root
RUN apt update && apt install curl jq -y

COPY entrypoint.sh /usr/bin/entrypoint.sh
COPY auth-token /auth-token

ENTRYPOINT [ "/usr/bin/entrypoint.sh" ]