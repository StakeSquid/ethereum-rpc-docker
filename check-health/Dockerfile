FROM alpine:3.19

# Install necessary dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    ca-certificates

WORKDIR /repo

ENV RPC_URL
ENV REF_URL
ENV CHECK_INTERVAL=30

# Make the mounted script executable at runtime
while true; do \
   /repo/check-health.sh ${RPC_URL} ${REF_URL} > /health/status 2>&1; \
   sleep ${CHECK_INTERVAL}; \
done