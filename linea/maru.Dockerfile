ARG MARU_IMAGE=consensys/maru
ARG MARU_VERSION=bcfdb4
FROM ${MARU_IMAGE}:${MARU_VERSION}

RUN apt-get update && apt-get install -y gettext && rm -rf /var/lib/apt/lists/*