FROM alpine:3.20

RUN apk add --no-cache \
    wireguard-tools \
    iproute2 \
    iptables \
    curl \
    jq \
    bash \
    && rm -rf /var/cache/apk/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV ENROLLMENT_TOKEN="" \
    BRAIN_URL="" \
    NODE_NAME="" \
    ROLE="client" \
    ADVERTISED_ROUTES="" \
    HEARTBEAT_INTERVAL="30"

ENTRYPOINT ["/entrypoint.sh"]
