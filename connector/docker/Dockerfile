FROM alpine:3.20

RUN apk add --no-cache \
    wireguard-tools \
    iproute2 \
    iptables \
    iptables-legacy \
    curl \
    jq \
    bash \
    && rm -rf /var/cache/apk/*
# iptables-legacy is REQUIRED for hosts whose netfilter path uses the
# legacy xtables API (CentOS 7, older Debian, anywhere Docker uses
# iptables-legacy itself). Without it, rules written from inside the
# container never land in the kernel tables the host actually reads.

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV ENROLLMENT_TOKEN="" \
    BRAIN_URL="" \
    NODE_NAME="" \
    ROLE="client" \
    ADVERTISED_ROUTES="" \
    HEARTBEAT_INTERVAL="30"

ENTRYPOINT ["/entrypoint.sh"]
