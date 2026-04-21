# wg0-connector (compat) — userspace WireGuard edition.
#
# Unlike the standard Docker connector, this image does NOT require the
# host kernel to have the WireGuard module. It runs wireguard-go entirely
# in userspace. All it needs is /dev/net/tun on the host, which every Linux
# 2.6+ kernel provides.
#
# When to use:
#   - Older Linux hosts without wireguard kernel module (pre-5.6 without backports)
#   - Legacy CentOS 7 / Debian 9 / Ubuntu 18.04 hosts
#   - Container platforms that don't expose kernel modules to containers
#   - Any host where `modprobe wireguard` fails
#
# Trade-offs vs. the kernel-WG image:
#   - ~25-40% lower throughput (crypto in userspace)
#   - Higher CPU per packet
#   - Identical behavior otherwise — same enrollment, heartbeat, host setup
FROM alpine:3.20

# wireguard-tools provides `wg` + `wg-quick` (control plane, stable repo).
# wireguard-go (userspace data plane) is only in edge/community — pin the
# repo so reproducible builds work. wg-quick detects it via
# WG_QUICK_USERSPACE_IMPLEMENTATION and uses it when the kernel module is
# absent or the env var forces it.
RUN apk add --no-cache \
        wireguard-tools \
        iproute2 \
        iptables \
        iptables-legacy \
        curl \
        jq \
        bash \
    && apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
        wireguard-go \
    && rm -rf /var/cache/apk/*
# iptables-legacy is REQUIRED for CentOS 7 / older-kernel hosts whose
# netfilter path uses the legacy xtables API. Alpine's `iptables` package
# ships only the nft variant; without iptables-legacy, rules written from
# the container never land in the kernel tables the host actually reads.

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV ENROLLMENT_TOKEN="" \
    BRAIN_URL="" \
    NODE_NAME="" \
    ROLE="client" \
    ADVERTISED_ROUTES="" \
    HEARTBEAT_INTERVAL="30" \
    WG_QUICK_USERSPACE_IMPLEMENTATION="wireguard-go" \
    LOG_LEVEL="info"

ENTRYPOINT ["/entrypoint.sh"]
