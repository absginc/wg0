#!/usr/bin/env bash
# wg0 Docker connector — entrypoint
#
# Enrolls with the brain, brings up WireGuard, and heartbeats forever.
# The heartbeat loop is the foreground process — the container stays
# alive as long as the tunnel is running.
#
# Required environment:
#   ENROLLMENT_TOKEN   Enrollment token from the dashboard
#   BRAIN_URL          Brain API URL (e.g. https://connect.wg0.io)
#
# Optional:
#   NODE_NAME          Display name (default: container hostname)
#   ROLE               client (default) or host
#   ADVERTISED_ROUTES  Comma-separated CIDRs (host mode)
#   HEARTBEAT_INTERVAL Seconds between heartbeats (default: 30)

set -euo pipefail

# ── Validate ─────────────────────────────────────────────────────────────────
[[ -z "${ENROLLMENT_TOKEN:-}" ]] && { echo "ERROR: ENROLLMENT_TOKEN is required."; exit 1; }
[[ -z "${BRAIN_URL:-}" ]] && { echo "ERROR: BRAIN_URL is required."; exit 1; }

BRAIN_URL="${BRAIN_URL%/}"
# Connector version. Bumped per release of the container image — the
# heartbeat carries this so the portal can flag nodes running a stale
# image.
CONNECTOR_VERSION="2026.04.22-b"
WG_IFACE="wg0"
WG_CONF="/etc/wireguard/wg0.conf"
INSTALLATION_ID_FILE="/etc/wireguard/installation_id"
DEVICE_ID_FILE="/etc/wireguard/device_id"
KEY_DIR="/etc/wireguard/wg0"
PRIV_KEY_FILE="${KEY_DIR}/private.key"
PUB_KEY_FILE="${KEY_DIR}/public.key"
NODE_ID_FILE="${KEY_DIR}/node_id"
DEVICE_SECRET_FILE="${KEY_DIR}/device_secret"
CONFIG_VERSION_FILE="${KEY_DIR}/config_version"
ROUTE_ALL_STATE="${KEY_DIR}/route_all_state"
PROBE_PEERS_FILE="${KEY_DIR}/probe_peers"
COLLECT_TELEMETRY_STATE="${KEY_DIR}/collect_device_telemetry"
TELEMETRY_CPU_SAMPLE="${KEY_DIR}/telemetry_cpu_sample"
EGRESS_IFACES_FILE="${KEY_DIR}/egress_ifaces"
NODE_NAME="${NODE_NAME:-$(hostname)}"
ROLE="${ROLE:-client}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"

log() { echo "[wg0 $(date -u +%H:%M:%SZ)] $*"; }
die() { log "FATAL: $*" >&2; exit 1; }

is_ipv4_cidr() {
    local value="${1:-}"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]
}

first_valid_ipv4_cidr() {
    local raw="${1:-}" route
    IFS=',' read -ra routes <<< "$raw"
    for route in "${routes[@]}"; do
        route=$(echo "$route" | xargs)
        [[ -z "$route" ]] && continue
        if is_ipv4_cidr "$route"; then
            printf '%s\n' "$route"
            return 0
        fi
    done
    return 1
}

get_or_create_installation_id() {
    local iid=""
    if [[ -f "$INSTALLATION_ID_FILE" ]]; then
        iid="$(cat "$INSTALLATION_ID_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "$iid" ]]; then
        iid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true)"
        [[ -n "$iid" ]] || die "Unable to generate installation_id"
        printf '%s' "$iid" > "$INSTALLATION_ID_FILE"
        chmod 600 "$INSTALLATION_ID_FILE"
    fi
    printf '%s' "$iid"
}

current_capabilities_json() {
    # Docker containers are single-interface by design — one container
    # per attached network. See connector/docker/README.md for the
    # "run one wg0-connector container per network" pattern and why
    # that's cleaner than a multi-iface container. Advertising
    # multi_membership_v1 anyway so the brain knows the *device*
    # identity (shared across containers by installation_id) can
    # participate in the multi-membership flow.
    jq -cn '[
        "same_lan_detection",
        "split_tunnel_linux",
        "assisted_relay_probe_peers_v1",
        "peer_observations",
        "device_telemetry_v1",
        "desired_state_convergence",
        "multi_membership_v1"
    ]'
}

detect_host_lan_ip() {
    [[ "$ROLE" == "host" ]] || { echo ""; return; }
    [[ -n "${ADVERTISED_ROUTES:-}" ]] || { echo ""; return; }

    local phys_iface="" first_route="" probe_ip=""
    [[ -f "${KEY_DIR}/phys_iface" ]] && phys_iface=$(cat "${KEY_DIR}/phys_iface" 2>/dev/null || true)

    if [[ -z "$phys_iface" ]]; then
        first_route=$(first_valid_ipv4_cidr "${ADVERTISED_ROUTES:-}" || true)
        if [[ -n "$first_route" ]]; then
            probe_ip=$(echo "$first_route" | cut -d/ -f1)
            phys_iface=$({ ip -4 route get "$probe_ip" 2>/dev/null || true; } | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
        elif [[ -n "${ADVERTISED_ROUTES:-}" ]]; then
            log "WARNING: ADVERTISED_ROUTES='${ADVERTISED_ROUTES}' contains no valid IPv4 CIDRs. Falling back to default-route detection."
        fi
    fi

    if [[ -z "$phys_iface" || "$phys_iface" == "$WG_IFACE" ]]; then
        phys_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    fi
    [[ -n "$phys_iface" ]] || { echo ""; return; }

    ip -4 -o addr show dev "$phys_iface" scope global 2>/dev/null \
        | awk '{split($4, a, "/"); print a[1]; exit}'
}

collect_cpu_json() {
    local total idle now_ms prev_total prev_idle prev_ms total_delta idle_delta usage
    read -r total idle < <(awk '/^cpu / { total=0; for (i=2; i<=NF; i++) total += $i; idle=$5+$6; print total, idle; exit }' /proc/stat 2>/dev/null)
    [[ -n "$total" && -n "$idle" ]] || { echo "null"; return; }
    now_ms=$(date +%s%3N 2>/dev/null || awk 'BEGIN{srand(); print int(systime()*1000)}')
    if [[ -f "$TELEMETRY_CPU_SAMPLE" ]]; then
        read -r prev_total prev_idle prev_ms < "$TELEMETRY_CPU_SAMPLE" || true
    fi
    printf '%s %s %s\n' "$total" "$idle" "$now_ms" > "$TELEMETRY_CPU_SAMPLE" 2>/dev/null || true
    chmod 600 "$TELEMETRY_CPU_SAMPLE" 2>/dev/null || true
    [[ -n "${prev_total:-}" && -n "${prev_idle:-}" && -n "${prev_ms:-}" ]] || { echo "null"; return; }
    total_delta=$((total - prev_total))
    idle_delta=$((idle - prev_idle))
    [[ "$total_delta" -gt 0 ]] || { echo "null"; return; }
    usage=$(awk -v t="$total_delta" -v i="$idle_delta" 'BEGIN { v=((t-i)*100)/t; if (v < 0) v = 0; if (v > 100) v = 100; printf "%.2f", v }')
    jq -cn --argjson system_usage_percent "$usage" --argjson sample_window_ms "$((now_ms - prev_ms))" \
        '{system_usage_percent:$system_usage_percent, app_usage_percent:null, sample_window_ms:$sample_window_ms}'
}

collect_memory_json() {
    local total_kb available_kb app_rss_kb app_pss_bytes low_memory
    total_kb=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    available_kb=$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    app_rss_kb=$(awk '/VmRSS:/ {print $2; exit}' /proc/self/status 2>/dev/null || echo "")
    [[ -n "$total_kb" && -n "$available_kb" ]] || { echo "null"; return; }
    app_pss_bytes=null
    if [[ -n "$app_rss_kb" ]]; then
        app_pss_bytes=$((app_rss_kb * 1024))
    fi
    low_memory=$(awk -v a="$available_kb" -v t="$total_kb" 'BEGIN { print (t > 0 && (a / t) < 0.10) ? "true" : "false" }')
    jq -cn \
        --argjson total_bytes "$((total_kb * 1024))" \
        --argjson available_bytes "$((available_kb * 1024))" \
        --argjson app_pss_bytes "$app_pss_bytes" \
        --argjson low_memory "$low_memory" \
        '{total_bytes:$total_bytes, available_bytes:$available_bytes, app_pss_bytes:$app_pss_bytes, low_memory:$low_memory}'
}

collect_device_telemetry_json() {
    [[ "$(cat "$COLLECT_TELEMETRY_STATE" 2>/dev/null || echo off)" == "on" ]] || { echo "null"; return; }
    local cpu_json memory_json
    cpu_json=$(collect_cpu_json)
    memory_json=$(collect_memory_json)
    if [[ "$cpu_json" == "null" && "$memory_json" == "null" ]]; then
        echo "null"
        return
    fi
    jq -cn --argjson cpu "$cpu_json" --argjson memory "$memory_json" \
        '{battery:null, cpu:$cpu, memory:$memory}'
}

# ── iptables backend detection (CRITICAL for --network host) ─────────────────
#
# Alpine's `iptables` is the nft variant. Many host kernels (CentOS 7, older
# Debian, anywhere Docker uses iptables-legacy) read ONLY the legacy xtables
# API. Rules written to nft on those kernels are phantom rules — they
# appear in the container's iptables-save output but never hit the actual
# forwarding path.
#
# Fix: install BOTH backends, detect which the host's real forwarding path
# uses, and write rules through that binary. If detection is ambiguous,
# write to BOTH backends as belt-and-suspenders.
detect_iptables_backend() {
    local legacy_has_rules=0 nft_has_rules=0
    if command -v iptables-legacy >/dev/null 2>&1; then
        if iptables-legacy -S FORWARD 2>/dev/null | grep -qE '^-A|DOCKER|-P FORWARD (DROP|REJECT)'; then
            legacy_has_rules=1
        fi
    fi
    if command -v iptables-nft >/dev/null 2>&1; then
        if iptables-nft -S FORWARD 2>/dev/null | grep -qE '^-A|DOCKER|-P FORWARD (DROP|REJECT)'; then
            nft_has_rules=1
        fi
    fi
    if [[ "$legacy_has_rules" == "1" && "$nft_has_rules" == "0" ]]; then
        echo "legacy"
    elif [[ "$nft_has_rules" == "1" && "$legacy_has_rules" == "0" ]]; then
        echo "nft"
    else
        echo "both"
    fi
}

IPTABLES_BACKEND=$(detect_iptables_backend)
case "$IPTABLES_BACKEND" in
    legacy) IPTABLES_BINS=("iptables-legacy") ;;
    nft)    IPTABLES_BINS=("iptables-nft") ;;
    both)   IPTABLES_BINS=("iptables-legacy" "iptables-nft") ;;
esac
# Legacy back-compat for lines still using $IPTABLES (we're transitioning).
IPTABLES="${IPTABLES_BINS[0]}"

log "iptables backend selected: ${IPTABLES_BACKEND} (${IPTABLES_BINS[*]})"

# ── Config sanitization (applied on every config write) ─────────────────────
# The brain renders a wg0.conf with PostUp/PreDown commands that are correct
# for a regular Linux host but dangerous in a container:
#   - sysctl/proc writes fail on read-only /proc (silently with sed).
#   - proxy_arp writes on "all" poison the LAN (never allow).
#   - `ip route add <subnet> dev wg0` hijacks the physical LAN into the tunnel.
#
# This function rewrites wg0.conf in place to neutralize those lines. Call it
# after every write to wg0.conf — startup AND the config-drift refresh path.
# Otherwise a docker stop/start later would re-run the toxic commands.
sanitize_wg_conf() {
    [[ -f "$WG_CONF" ]] || return 0

    # Replace any sysctl / /proc/sys write with `true` (no-op).
    sed -i \
        -e 's/sysctl -qw [^;]*/true/g' \
        -e 's|echo [01] > /proc/sys/[^ ;]*|true|g' \
        "$WG_CONF"

    # For host-mode with advertised routes, strip "ip route add <route> dev wg0"
    # including any trailing "2>/dev/null" and "|| true" tail so we don't
    # leave a dangling shell fragment that breaks wg-quick eval.
    if [[ "$ROLE" == "host" && -n "${ADVERTISED_ROUTES:-}" ]]; then
        local routes route escaped
        IFS=',' read -ra routes <<< "$ADVERTISED_ROUTES"
        for route in "${routes[@]}"; do
            route=$(echo "$route" | xargs)
            [[ -z "$route" ]] && continue
            escaped=$(echo "$route" | sed 's/[.\/]/\\&/g')
            sed -i "s|ip route add ${escaped} dev [^ ]* [^;]*||g" "$WG_CONF"
        done
        # Clean up leftover orphaned "|| true" or empty semicolons from the strip.
        sed -i -e 's/; *|| true//g' -e 's/;  *;/;/g' -e 's/; *$//' "$WG_CONF"
    fi
}

# ── Graceful shutdown ────────────────────────────────────────────────────────
cleanup() {
    log "Shutting down WireGuard..."
    wg-quick down "$WG_CONF" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Key generation ───────────────────────────────────────────────────────────
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [[ ! -f "$PRIV_KEY_FILE" ]]; then
    log "Generating WireGuard keypair..."
    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE" "$PUB_KEY_FILE"
fi
PRIV_KEY=$(cat "$PRIV_KEY_FILE")
PUB_KEY=$(cat "$PUB_KEY_FILE")
INSTALLATION_ID=$(get_or_create_installation_id)

# ── Detect public IP ─────────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
ENDPOINT=""
[[ -n "$PUBLIC_IP" ]] && ENDPOINT="${PUBLIC_IP}:51820"

# ── Enrollment (idempotent — skips if already enrolled) ──────────────────────
if [[ ! -f "$NODE_ID_FILE" ]]; then
    log "Enrolling '${NODE_NAME}' (role=${ROLE}) with ${BRAIN_URL}..."

    ROUTES_JSON="[]"
    if [[ -n "${ADVERTISED_ROUTES:-}" ]]; then
        ROUTES_JSON=$(echo "$ADVERTISED_ROUTES" | jq -R 'split(",") | map(select(length > 0) | gsub("^ +| +$"; ""))')
    fi

    PAYLOAD=$(jq -cn \
        --arg token "$ENROLLMENT_TOKEN" \
        --arg installation_id "$INSTALLATION_ID" \
        --arg public_key "$PUB_KEY" \
        --arg node_name "$NODE_NAME" \
        --arg os_type "linux-docker" \
        --arg role "$ROLE" \
        --arg endpoint "$ENDPOINT" \
        --argjson advertised_routes "$ROUTES_JSON" \
        '{token:$token, installation_id:$installation_id, public_key:$public_key, node_name:$node_name,
          os_type:$os_type, role:$role, endpoint:$endpoint,
          advertised_routes:$advertised_routes}')

    ENROLL_RESPONSE=$(curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${BRAIN_URL}/api/v1/enroll/register") \
        || die "Enrollment failed. Check ENROLLMENT_TOKEN and BRAIN_URL."

    DEVICE_ID=$(echo "$ENROLL_RESPONSE" | jq -r '.device_id // empty')
    NODE_ID=$(echo "$ENROLL_RESPONSE" | jq -r '.node_id')
    OVERLAY_IP=$(echo "$ENROLL_RESPONSE" | jq -r '.overlay_ip')
    WG_CONFIG=$(echo "$ENROLL_RESPONSE" | jq -r '.wg_config')
    DEVICE_SECRET=$(echo "$ENROLL_RESPONSE" | jq -r '.device_secret // empty')

    echo "$NODE_ID" > "$NODE_ID_FILE" && chmod 600 "$NODE_ID_FILE"
    if [[ -n "$DEVICE_ID" ]]; then
        printf '%s' "$DEVICE_ID" > "$DEVICE_ID_FILE" && chmod 600 "$DEVICE_ID_FILE"
    fi
    echo "$BRAIN_URL" > "${KEY_DIR}/brain_url" && chmod 600 "${KEY_DIR}/brain_url"
    echo "${OVERLAY_IP%/*}" > "${KEY_DIR}/overlay_ip" && chmod 600 "${KEY_DIR}/overlay_ip"

    if [[ -n "$DEVICE_SECRET" ]]; then
        printf '%s' "$DEVICE_SECRET" > "$DEVICE_SECRET_FILE" && chmod 600 "$DEVICE_SECRET_FILE"
    fi

    # Write WireGuard config with private key substituted.
    echo "$WG_CONFIG" \
        | sed "s|# PrivateKey = <CONNECTOR_FILLS_THIS_IN>|PrivateKey = ${PRIV_KEY}|" \
        > "$WG_CONF"
    chmod 600 "$WG_CONF"

    log "Enrolled! Overlay IP: ${OVERLAY_IP} | Node ID: ${NODE_ID}"
else
    log "Already enrolled (node $(cat "$NODE_ID_FILE")). Skipping enrollment."
fi

NODE_ID=$(cat "$NODE_ID_FILE")

# ── Strip sysctl/route commands from the rendered PostUp ─────────────────────
# Sanitize the brain-rendered config for container use.
# (Sets up the startup wg-quick up; config-drift refreshes must also call
# sanitize_wg_conf — see the heartbeat loop below.)
sanitize_wg_conf

# ── Bring up WireGuard ───────────────────────────────────────────────────────
log "Bringing up WireGuard interface ${WG_IFACE}..."
wg-quick up "$WG_CONF" || die "Failed to bring up WireGuard."
log "Interface ${WG_IFACE} is up."

# ── Native-LAN host forwarding setup (mirrors connector.sh setup_native_lan_host) ──
#
# Runs when --network host is in use (only then can we see and configure the
# host's physical interface, iptables, and sysctls). With default bridge
# networking, we're on docker0 and there's nothing useful to do here — the
# container has no line-of-sight to the physical LAN anyway.
setup_native_lan_host_docker() {
    [[ "$ROLE" == "host" ]] || return 0
    [[ -n "${ADVERTISED_ROUTES:-}" ]] || return 0

    log "Configuring native-LAN host forwarding (Docker)..."

    # Detect the physical LAN interface.
    #
    # On multi-homed hosts (separate management + data NICs), the default
    # route is often on the management NIC while the advertised LAN subnet
    # is on a different data NIC. Pick the interface that has a route to
    # the FIRST advertised CIDR — that's where traffic needs to exit.
    # Only fall back to the default route if we can't find one.
    local phys_iface first_route probe_ip wan_iface
    first_route=$(first_valid_ipv4_cidr "$ADVERTISED_ROUTES" || true)
    if [[ -n "$first_route" ]]; then
        probe_ip=$(echo "$first_route" | cut -d/ -f1)
        phys_iface=$({ ip -4 route get "$probe_ip" 2>/dev/null || true; } | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    elif [[ -n "$ADVERTISED_ROUTES" ]]; then
        log "WARNING: ADVERTISED_ROUTES='${ADVERTISED_ROUTES}' contains no valid IPv4 CIDRs. Falling back to default-route detection."
    fi
    if [[ -z "$phys_iface" || "$phys_iface" == "$WG_IFACE" ]]; then
        phys_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    fi
    if [[ -z "$phys_iface" || "$phys_iface" == "$WG_IFACE" ]]; then
        log "WARNING: could not detect physical LAN interface."
        log "         Is the container running with --network host?"
        log "         Host forwarding setup skipped."
        return 0
    fi
    log "Physical LAN interface: ${phys_iface} (route to ${first_route:-default})"
    echo "$phys_iface" > "${KEY_DIR}/phys_iface" 2>/dev/null || true

    # Bridge-mode detection. If the selected phys_iface carries ONLY a
    # Docker bridge address (172.17.x.x / 172.18.x.x / 172.20.x.x …),
    # we're running in the default bridge networking mode, NOT --network
    # host. That's a silent config error for LAN-placement hosts: MASQUERADE
    # lands on the bridge interface, not the host's real LAN NIC, so
    # mesh clients can ping each other (via crypto routing) but can't
    # reach the host's LAN devices (10.0.0.x, 192.168.x.x, etc.). This
    # matches the "I can ping mesh peers but not 10.0.0.1" symptom.
    local phys_ip_first
    phys_ip_first=$(ip -4 -o addr show dev "$phys_iface" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1)
    if [[ "$phys_ip_first" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
        log "WARNING: ${phys_iface} has IP ${phys_ip_first}, which looks like a Docker bridge."
        log "         This container is likely NOT running with 'network_mode: host'."
        log "         Consequence: MASQUERADE + FORWARD rules land on the container's"
        log "         bridge interface, NOT the docker host's real LAN NIC — so wg0"
        log "         clients can reach each other via the overlay but cannot reach"
        log "         devices on your actual LAN (e.g. 10.0.0.1, 192.168.1.50)."
        log "         Fix: add 'network_mode: host' to the compose service (or"
        log "         '--network host' on docker run) and restart the container."
    fi

    wan_iface=$(ip route show default 2>/dev/null | awk '/^default/ && $5 != "'"${WG_IFACE}"'" && $5 != "wg0-up" {print $5; exit}')
    if [[ -n "$wan_iface" ]]; then
        echo "$wan_iface" > "${KEY_DIR}/wan_iface" 2>/dev/null || true
        log "Default WAN interface: ${wan_iface}"
    else
        rm -f "${KEY_DIR}/wan_iface" 2>/dev/null || true
        log "WARNING: could not detect a default WAN interface for host internet exit."
    fi

    # Snapshot original sysctl values so shutdown can restore them.
    # With --network host we're mutating the *host's* shared namespace —
    # leaving ip_forward=1 and rp_filter=0 behind after docker stop would
    # be the same leak we fixed in the Linux connector.
    local state_file="${KEY_DIR}/sysctl_state"
    if [[ ! -f "$state_file" ]]; then
        {
            echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
            echo "rp_filter_all=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo 2)"
            echo "rp_filter_wg=$(cat /proc/sys/net/ipv4/conf/${WG_IFACE}/rp_filter 2>/dev/null || echo 2)"
            echo "rp_filter_phys=$(cat /proc/sys/net/ipv4/conf/${phys_iface}/rp_filter 2>/dev/null || echo 2)"
            echo "rp_filter_wan=$(cat /proc/sys/net/ipv4/conf/${wan_iface}/rp_filter 2>/dev/null || echo 2)"
            echo "proxy_arp_wg=$(cat /proc/sys/net/ipv4/conf/${WG_IFACE}/proxy_arp 2>/dev/null || echo 0)"
            echo "phys_iface=${phys_iface}"
            echo "wan_iface=${wan_iface}"
        } > "$state_file" 2>/dev/null || true
    fi

    # ip_forward — required. --sysctl net.ipv4.ip_forward=1 on docker run
    # OR --privileged is needed, otherwise /proc/sys is read-only.
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]]; then
        if ! sysctl -qw net.ipv4.ip_forward=1 2>/dev/null; then
            log "ERROR: IP forwarding is OFF and /proc/sys is read-only."
            log "       Add either --privileged or --sysctl net.ipv4.ip_forward=1 to docker run."
            log "       Host forwarding will NOT work until this is fixed."
        fi
    fi

    # rp_filter — must be 0 on wg0, physical, and all so forwarded packets
    # aren't dropped when source doesn't match the incoming interface.
    for iface in all "$WG_IFACE" "$phys_iface"; do
        sysctl -qw "net.ipv4.conf.${iface}.rp_filter=0" 2>/dev/null || true
    done
    if [[ -n "$wan_iface" && "$wan_iface" != "$phys_iface" ]]; then
        sysctl -qw "net.ipv4.conf.${wan_iface}.rp_filter=0" 2>/dev/null || true
    fi

    # proxy_arp on wg0 — mirrors the Linux shell connector's host setup.
    # With MASQUERADE alone, return traffic finds its way back via the host's
    # SNAT'd IP, so strictly speaking proxy_arp isn't required. But keeping
    # it on wg0 matches the host health model in connector.sh check and
    # keeps future per-client proxy-ARP work viable. NEVER on "all".
    sysctl -qw "net.ipv4.conf.${WG_IFACE}.proxy_arp=1" 2>/dev/null || \
        echo 1 > "/proc/sys/net/ipv4/conf/${WG_IFACE}/proxy_arp" 2>/dev/null || true

    # iptables FORWARD + NAT — write through EVERY selected backend so rules
    # land in whichever table the kernel actually consults. Silently-dormant
    # rules in the other backend are harmless (cleaned up on shutdown).
    ensure_host_rules() {
        local iface="$1"
        local route
        [[ -z "$iface" ]] && return 0
        for bin in "${IPTABLES_BINS[@]}"; do
            command -v "$bin" >/dev/null 2>&1 || continue
            if ! "$bin" -C FORWARD -i "$WG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null; then
                "$bin" -I FORWARD 1 -i "$WG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null || true
            fi
            if ! "$bin" -C FORWARD -i "$iface" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; then
                "$bin" -I FORWARD 1 -i "$iface" -o "$WG_IFACE" -j ACCEPT 2>/dev/null || true
            fi
            IFS=',' read -ra MASQ_ROUTES <<< "$ADVERTISED_ROUTES"
            for route in "${MASQ_ROUTES[@]}"; do
                route=$(echo "$route" | xargs)
                [[ -z "$route" ]] && continue
                if ! "$bin" -t nat -C POSTROUTING -s "$route" -o "$iface" -j MASQUERADE 2>/dev/null; then
                    "$bin" -t nat -I POSTROUTING 1 -s "$route" -o "$iface" -j MASQUERADE 2>/dev/null || true
                fi
            done
        done
    }

    ensure_same_tunnel_forward() {
        for bin in "${IPTABLES_BINS[@]}"; do
            command -v "$bin" >/dev/null 2>&1 || continue
            if ! "$bin" -C FORWARD -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; then
                "$bin" -I FORWARD 1 -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT 2>/dev/null || true
            fi
        done
    }

    verify_nat_iface() {
        local iface="$1" route verified=0
        [[ -z "$iface" ]] && return 0
        route=$(echo "$ADVERTISED_ROUTES" | cut -d',' -f1 | xargs)
        [[ -z "$route" ]] && return 0
        for bin in "${IPTABLES_BINS[@]}"; do
            command -v "$bin" >/dev/null 2>&1 || continue
            if "$bin" -t nat -C POSTROUTING -s "$route" -o "$iface" -j MASQUERADE 2>/dev/null; then
                log "Verified MASQUERADE in ${bin} (route=${route} iface=${iface})"
                verified=1
            fi
        done
        if [[ "$verified" == "0" ]]; then
            log "═══════════════════════════════════════════════════════════════════"
            log "⚠ WARNING: MASQUERADE verification FAILED across ${IPTABLES_BINS[*]}"
            log "  Remote peers will NOT be able to reach destinations via ${iface}."
            log "  Manual fix on host: iptables -t nat -I POSTROUTING 1 -s ${route} -o ${iface} -j MASQUERADE"
            log "═══════════════════════════════════════════════════════════════════"
        fi
    }

    discover_egress_ifaces() {
        local route line iface
        declare -A seen=()
        local ifaces=()

        for iface in "$phys_iface" "$wan_iface"; do
            [[ -z "$iface" ]] && continue
            [[ -n "${seen[$iface]:-}" ]] && continue
            seen["$iface"]=1
            ifaces+=("$iface")
        done

        IFS=',' read -ra MASQ_ROUTES <<< "$ADVERTISED_ROUTES"
        for route in "${MASQ_ROUTES[@]}"; do
            route=$(echo "$route" | xargs)
            [[ -z "$route" ]] && continue
            is_ipv4_cidr "$route" || continue
            while read -r line; do
                iface=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
                [[ -z "$iface" || "$iface" == "$WG_IFACE" || "$iface" == "wg0-up" || "$iface" == "lo" ]] && continue
                [[ -n "${seen[$iface]:-}" ]] && continue
                seen["$iface"]=1
                ifaces+=("$iface")
            done < <({ ip -4 route show root "$route" 2>/dev/null || true; })
        done

        printf '%s\n' "${ifaces[@]}"
    }

    mapfile -t EGRESS_IFACES < <(discover_egress_ifaces)
    printf '%s\n' "${EGRESS_IFACES[@]}" > "$EGRESS_IFACES_FILE"

    for iface in "${EGRESS_IFACES[@]}"; do
        ensure_host_rules "$iface"
    done
    ensure_same_tunnel_forward

    for iface in "${EGRESS_IFACES[@]}"; do
        verify_nat_iface "$iface"
    done
    log "Host forwarding configured (backend=${IPTABLES_BACKEND}): LAN=${phys_iface}${wan_iface:+ WAN=${wan_iface}} egress_ifaces=$(printf '%s,' "${EGRESS_IFACES[@]}" | sed 's/,$//')."
}

setup_native_lan_host_docker

# ── Cleanup host forwarding on shutdown ──────────────────────────────────────
# Extends the cleanup() trap so a docker stop removes our iptables rules
# instead of leaving them behind on the host (since --network host shares
# the real iptables).
cleanup_host_forwarding() {
    [[ "$ROLE" == "host" ]] || return 0
    local phys_iface wan_iface
    phys_iface=$(cat "${KEY_DIR}/phys_iface" 2>/dev/null || true)
    wan_iface=$(cat "${KEY_DIR}/wan_iface" 2>/dev/null || true)
    mapfile -t saved_ifaces < "${EGRESS_IFACES_FILE}" 2>/dev/null || saved_ifaces=()
    [[ -z "$phys_iface" && -z "$wan_iface" && "${#saved_ifaces[@]}" -eq 0 ]] && return 0

    log "Removing host forwarding rules for phys=${phys_iface:-none} wan=${wan_iface:-none} extra=$(printf '%s,' "${saved_ifaces[@]}" | sed 's/,$//') backends=${IPTABLES_BINS[*]}..."
    for bin in "${IPTABLES_BINS[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || continue
        declare -A seen_ifaces=()
        for iface in "$phys_iface" "$wan_iface" "${saved_ifaces[@]}"; do
            [[ -z "$iface" ]] && continue
            [[ -n "${seen_ifaces[$iface]:-}" ]] && continue
            seen_ifaces["$iface"]=1
            while "$bin" -C FORWARD -i "$WG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null; do
                "$bin" -D FORWARD -i "$WG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null || break
            done
            while "$bin" -C FORWARD -i "$iface" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; do
                "$bin" -D FORWARD -i "$iface" -o "$WG_IFACE" -j ACCEPT 2>/dev/null || break
            done
            if [[ -n "${ADVERTISED_ROUTES:-}" ]]; then
                IFS=',' read -ra MASQ_ROUTES <<< "$ADVERTISED_ROUTES"
                for route in "${MASQ_ROUTES[@]}"; do
                    route=$(echo "$route" | xargs)
                    [[ -z "$route" ]] && continue
                    while "$bin" -t nat -C POSTROUTING -s "$route" -o "$iface" -j MASQUERADE 2>/dev/null; do
                        "$bin" -t nat -D POSTROUTING -s "$route" -o "$iface" -j MASQUERADE 2>/dev/null || break
                    done
                done
            fi
        done
        while "$bin" -C FORWARD -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; do
            "$bin" -D FORWARD -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT 2>/dev/null || break
        done
    done
}

# Restore host sysctl state on shutdown. With --network host the container
# mutated the *host's* shared namespace, so leaving ip_forward=1 or
# rp_filter=0 behind would be a leak. Mirrors connector.sh unenroll (3c).
cleanup_sysctl_state() {
    [[ "$ROLE" == "host" ]] || return 0
    local state_file="${KEY_DIR}/sysctl_state"
    [[ -f "$state_file" ]] || return 0

    local ip_forward rp_filter_all rp_filter_wg rp_filter_phys rp_filter_wan proxy_arp_wg phys_iface wan_iface
    # shellcheck disable=SC1090
    source "$state_file"

    log "Restoring host sysctl state..."
    [[ -n "${ip_forward:-}" ]]      && sysctl -qw "net.ipv4.ip_forward=${ip_forward}" 2>/dev/null || true
    [[ -n "${rp_filter_all:-}" ]]   && sysctl -qw "net.ipv4.conf.all.rp_filter=${rp_filter_all}" 2>/dev/null || true
    # wg0 will be gone after wg-quick down — no-op if interface doesn't exist.
    [[ -n "${rp_filter_wg:-}" ]]    && sysctl -qw "net.ipv4.conf.${WG_IFACE}.rp_filter=${rp_filter_wg}" 2>/dev/null || true
    [[ -n "${proxy_arp_wg:-}" ]]    && sysctl -qw "net.ipv4.conf.${WG_IFACE}.proxy_arp=${proxy_arp_wg}" 2>/dev/null || true
    if [[ -n "${phys_iface:-}" && -n "${rp_filter_phys:-}" ]]; then
        sysctl -qw "net.ipv4.conf.${phys_iface}.rp_filter=${rp_filter_phys}" 2>/dev/null || true
    fi
    if [[ -n "${wan_iface:-}" && -n "${rp_filter_wan:-}" ]]; then
        sysctl -qw "net.ipv4.conf.${wan_iface}.rp_filter=${rp_filter_wan}" 2>/dev/null || true
    fi
}

# Override the earlier cleanup trap: remove installed kernel routes + host
# forwarding rules + wg interface + restore host sysctls. Order matters:
# iptables/routes first (wg0 still up), then wg-quick down (removes wg0),
# then sysctl restore.
cleanup_installed_routes() {
    local routes_file="${KEY_DIR}/installed_routes"
    [[ -f "$routes_file" ]] || return 0
    while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        ip route del "$cidr" dev ${WG_IFACE} 2>/dev/null || true
    done < "$routes_file"
    rm -f "$routes_file" 2>/dev/null || true
}

cleanup_route_all_state() {
    local prev endpoint_ip
    prev=$(cat "$ROUTE_ALL_STATE" 2>/dev/null || echo "off")
    ip route del 0.0.0.0/1 dev ${WG_IFACE} 2>/dev/null || true
    ip route del 128.0.0.0/1 dev ${WG_IFACE} 2>/dev/null || true
    if [[ "$prev" == on* ]]; then
        endpoint_ip="${prev#*|}"
        [[ -n "$endpoint_ip" ]] && ip route del "${endpoint_ip}/32" 2>/dev/null || true
    fi
    echo "off" > "$ROUTE_ALL_STATE"
}

cleanup() {
    log "Shutting down WireGuard..."
    cleanup_route_all_state
    cleanup_installed_routes
    cleanup_host_forwarding
    wg-quick down "$WG_CONF" 2>/dev/null || true
    cleanup_sysctl_state
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Host default-exit health probe ───────────────────────────────────────────
get_default() {
    ip route show default 2>/dev/null \
        | awk '/^default/ && $5 != "'"${WG_IFACE}"'" && $5 != "wg0-up" {print $5, $3; exit}'
}

default_exit_route() {
    get_default
}

iptables_rule_present_any() {
    local args=("$@")
    local bin
    for bin in "${IPTABLES_BINS[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || continue
        if "$bin" "${args[@]}" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

build_default_exit_health_json() {
    [[ "$ROLE" == "host" ]] || { echo "null"; return; }
    [[ -n "${ADVERTISED_ROUTES:-}" ]] || { echo "null"; return; }

    local wan_iface wan_gw interface_up=false nat_ok=false forward_ok=false route now_ts
    read -r wan_iface wan_gw < <(default_exit_route)
    if [[ -z "$wan_iface" || "$wan_iface" == "$WG_IFACE" || "$wan_iface" == "wg0-up" ]]; then
        echo '{"interface_up": false, "last_handshake": null}'
        return
    fi

    [[ -d "/sys/class/net/${wan_iface}" ]] && interface_up=true

    if $interface_up; then
        if iptables_rule_present_any -C FORWARD -i "$WG_IFACE" -o "$wan_iface" -j ACCEPT \
            && iptables_rule_present_any -C FORWARD -i "$wan_iface" -o "$WG_IFACE" -j ACCEPT; then
            forward_ok=true
        fi

        IFS=',' read -ra ROUTE_LIST <<< "$ADVERTISED_ROUTES"
        for route in "${ROUTE_LIST[@]}"; do
            route=$(echo "$route" | xargs)
            [[ -z "$route" ]] && continue
            if iptables_rule_present_any -t nat -C POSTROUTING -s "$route" -o "$wan_iface" -j MASQUERADE; then
                nat_ok=true
                break
            fi
        done
    fi

    if $interface_up && $nat_ok && $forward_ok && [[ -n "$PUBLIC_IP" ]]; then
        now_ts=$(date +%s)
        jq -cn --argjson lh "$now_ts" '{interface_up: true, last_handshake: $lh}'
    elif $interface_up && $nat_ok && $forward_ok; then
        echo '{"interface_up": true, "last_handshake": null}'
    else
        echo '{"interface_up": false, "last_handshake": null}'
    fi
}

# ── Heartbeat loop (foreground — keeps the container alive) ──────────────────
log "Starting heartbeat loop (every ${HEARTBEAT_INTERVAL}s)..."

while true; do
    sleep "$HEARTBEAT_INTERVAL" &
    wait $!  # allows trap to fire during sleep

    DEVICE_SECRET=$(cat "$DEVICE_SECRET_FILE" 2>/dev/null || true)

    # ── Collect tunnel stats ──
    TRANSFER=$(wg show ${WG_IFACE} transfer 2>/dev/null || true)
    TX_BYTES=$(echo "$TRANSFER" | awk '{sum += $3} END {print sum+0}')
    RX_BYTES=$(echo "$TRANSFER" | awk '{sum += $2} END {print sum+0}')

    # Refresh public IP.
    PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    ENDPOINT=""
    [[ -n "$PUBLIC_IP" ]] && ENDPOINT="${PUBLIC_IP}:51820"

    # Per-peer observations.
    PEERS_JSON=$(wg show ${WG_IFACE} dump 2>/dev/null | tail -n +2 | awk -F'\t' 'NF>=8 {
        printf "%s\t%s\t%s\t%s\n", $1, $5, $6, $7
    }' | jq -Rsc '
        split("\n") | map(select(length > 0) | split("\t") | {
            public_key: .[0],
            last_handshake: (if .[1] == "0" then null else (.[1] | tonumber) end),
            rx_bytes: (.[2] | tonumber),
            tx_bytes: (.[3] | tonumber)
        })' 2>/dev/null || echo "[]")
    [[ -z "$PEERS_JSON" ]] && PEERS_JSON="[]"

    UPSTREAM_HEALTH_JSON="null"
    if [[ "$ROLE" == "host" ]]; then
        UPSTREAM_HEALTH_JSON=$(build_default_exit_health_json)
    fi

    ROUTE_ALL_ACTIVE=false
    if [[ $(cat "$ROUTE_ALL_STATE" 2>/dev/null || echo "off") == on* ]]; then
        ROUTE_ALL_ACTIVE=true
    fi

    CAPABILITIES_JSON=$(current_capabilities_json)
    HOST_LAN_IP=$(detect_host_lan_ip)
    HOST_LAN_IP_JSON=$(jq -Rn --arg v "$HOST_LAN_IP" 'if ($v | length) > 0 then $v else null end')
    INSTALLATION_ID_JSON=$(jq -Rn --arg v "$(cat "$INSTALLATION_ID_FILE" 2>/dev/null || echo "")" 'if ($v | length) > 0 then $v else null end')
    TELEMETRY_JSON=$(collect_device_telemetry_json)

    # ── Send heartbeat ──
    HB_BODY=$(jq -cn \
        --arg endpoint "$ENDPOINT" \
        --arg connector_version "${CONNECTOR_VERSION}" \
        --argjson installation_id "$INSTALLATION_ID_JSON" \
        --argjson capabilities "$CAPABILITIES_JSON" \
        --argjson tx_bytes "$TX_BYTES" \
        --argjson rx_bytes "$RX_BYTES" \
        --argjson peers "$PEERS_JSON" \
        --argjson route_all_active "$ROUTE_ALL_ACTIVE" \
        --argjson host_lan_ip "$HOST_LAN_IP_JSON" \
        --argjson upstream_exit_health "$UPSTREAM_HEALTH_JSON" \
        --argjson telemetry "$TELEMETRY_JSON" \
        '{endpoint:$endpoint, installation_id:$installation_id, capabilities:$capabilities,
          host_lan_ip:$host_lan_ip, tx_bytes:$tx_bytes, rx_bytes:$rx_bytes,
          peers:$peers, route_all_active:$route_all_active, upstream_exit_health:$upstream_exit_health,
          telemetry:$telemetry, connector_version:$connector_version}')

    CURL_ARGS=( -sf -X POST -H "Content-Type: application/json" )
    [[ -n "$DEVICE_SECRET" ]] && CURL_ARGS+=( -H "X-Device-Secret: $DEVICE_SECRET" )

    RESPONSE=$(curl "${CURL_ARGS[@]}" \
        -d "$HB_BODY" \
        "${BRAIN_URL}/api/v1/nodes/${NODE_ID}/heartbeat" 2>/dev/null) || continue

    if [[ "$(echo "$RESPONSE" | jq -r '.collect_device_telemetry // false' 2>/dev/null)" == "true" ]]; then
        echo "on" > "$COLLECT_TELEMETRY_STATE"
    else
        echo "off" > "$COLLECT_TELEMETRY_STATE"
    fi

    # ── Config drift detection ──
    REMOTE_CV=$(echo "$RESPONSE" | jq -r '.config_version // 0')
    LOCAL_CV=$(cat "$CONFIG_VERSION_FILE" 2>/dev/null || echo 0)

    if [[ "$REMOTE_CV" -gt "$LOCAL_CV" ]]; then
        CFG_ARGS=( -sf )
        [[ -n "$DEVICE_SECRET" ]] && CFG_ARGS+=( -H "X-Device-Secret: $DEVICE_SECRET" )
        NEW_CFG_JSON=$(curl "${CFG_ARGS[@]}" \
            "${BRAIN_URL}/api/v1/nodes/${NODE_ID}/config" 2>/dev/null || true)

        if [[ -n "$NEW_CFG_JSON" ]]; then
            NEW_WG=$(echo "$NEW_CFG_JSON" | jq -r '.wg_config // empty')
            if [[ -n "$NEW_WG" ]]; then
                TMP_CONF=$(mktemp)
                echo "$NEW_WG" \
                    | sed "s|# PrivateKey = <CONNECTOR_FILLS_THIS_IN>|PrivateKey = ${PRIV_KEY}|" \
                    > "$TMP_CONF"
                chmod 600 "$TMP_CONF"
                mv -f "$TMP_CONF" "$WG_CONF"
                # Re-run the container sanitization on the fresh config so a
                # later docker stop/restart doesn't execute the raw brain-
                # rendered PostUp/PreDown (which would fail or hijack routes).
                sanitize_wg_conf
                wg syncconf ${WG_IFACE} <(wg-quick strip "$WG_CONF") 2>/dev/null || true
                echo "$REMOTE_CV" > "$CONFIG_VERSION_FILE"
                log "Config updated to version ${REMOTE_CV}."
            fi
        fi
    fi

    # ── Route-all (VPN-through-host) state machine ──
    WANT_ROUTE_ALL=0
    ROUTE_ALL_EP=""
    ON_SAME_LAN=0
    while read -r peer; do
        allowed=$(echo "$peer" | jq -r '.allowed_ips')
        same_lan=$(echo "$peer" | jq -r '.on_same_lan // false')
        if [[ "$allowed" == *"0.0.0.0/0"* ]]; then
            WANT_ROUTE_ALL=1
            ROUTE_ALL_EP=$(echo "$peer" | jq -r '.endpoint // empty')
        fi
        [[ "$same_lan" == "true" ]] && ON_SAME_LAN=1
    done < <(echo "$RESPONSE" | jq -c '.peers[]' 2>/dev/null)

    ROUTE_ALL_PREV=$(cat "$ROUTE_ALL_STATE" 2>/dev/null || echo "off")
    if [[ "$WANT_ROUTE_ALL" == "1" && "$ON_SAME_LAN" == "0" && -n "$ROUTE_ALL_EP" ]]; then
        ENDPOINT_IP="${ROUTE_ALL_EP%:*}"
        read -r _ DEFAULT_GW < <(get_default)
        if [[ -n "$DEFAULT_GW" && -n "$ENDPOINT_IP" ]]; then
            ip route replace "${ENDPOINT_IP}/32" via "$DEFAULT_GW" 2>/dev/null || true
        fi
        ip route replace 0.0.0.0/1 dev ${WG_IFACE} 2>/dev/null || true
        ip route replace 128.0.0.0/1 dev ${WG_IFACE} 2>/dev/null || true
        echo "on|${ENDPOINT_IP}" > "$ROUTE_ALL_STATE"
    elif [[ "$ROUTE_ALL_PREV" == on* ]]; then
        cleanup_route_all_state
    fi

    # ── Apply peer map updates + stale-route cleanup ──
    # Mirrors connector.sh: track installed routes in a state file, diff
    # against last cycle, and remove any CIDRs that are no longer advertised.
    # Without this, a shrunk allowed_ips or a route policy change leaves
    # stale kernel routes pointing at wg0 until the container restarts.
    INSTALLED_ROUTES_FILE="${KEY_DIR}/installed_routes"
    PREV_ROUTES=""
    [[ -f "$INSTALLED_ROUTES_FILE" ]] && PREV_ROUTES=$(cat "$INSTALLED_ROUTES_FILE")
    rm -f "${INSTALLED_ROUTES_FILE}.new"

    echo "$RESPONSE" | jq -c '.peers[]' 2>/dev/null | while read -r peer; do
        PUBKEY=$(echo "$peer" | jq -r '.public_key')
        ALLOWED=$(echo "$peer" | jq -r '.allowed_ips')
        EP=$(echo "$peer" | jq -r '.endpoint // empty')

        if [[ -n "$EP" ]]; then
            wg set ${WG_IFACE} peer "$PUBKEY" allowed-ips "$ALLOWED" endpoint "$EP" persistent-keepalive 25
        else
            wg set ${WG_IFACE} peer "$PUBKEY" allowed-ips "$ALLOWED" persistent-keepalive 25
        fi

        # Install system routes + record each CIDR for diff.
        echo "$ALLOWED" | tr ',' '\n' | tr -d ' ' | while read -r cidr; do
            [[ -z "$cidr" || "$cidr" == "0.0.0.0/0" ]] && continue
            ip route replace "$cidr" dev ${WG_IFACE} 2>/dev/null || true
            echo "$cidr" >> "${INSTALLED_ROUTES_FILE}.new"
        done
    done

    echo "$RESPONSE" | jq -c '.probe_peers // []' > "$PROBE_PEERS_FILE" 2>/dev/null || true

    # Shadow direct-probe peers: keep the direct path warm with endpoint +
    # keepalive only, but never let it claim any routes until the brain
    # promotes it back to the active carrier.
    echo "$RESPONSE" | jq -c '.probe_peers[]?' 2>/dev/null | while read -r peer; do
        PUBKEY=$(echo "$peer" | jq -r '.public_key // empty')
        EP=$(echo "$peer" | jq -r '.endpoint // empty')
        KEEPALIVE=$(echo "$peer" | jq -r '.persistent_keepalive // 25')
        [[ -z "$PUBKEY" || -z "$EP" ]] && continue
        wg set ${WG_IFACE} peer "$PUBKEY" endpoint "$EP" persistent-keepalive "$KEEPALIVE"
    done

    # Diff old vs new and remove CIDRs no longer advertised.
    if [[ -f "${INSTALLED_ROUTES_FILE}.new" ]]; then
        sort -u "${INSTALLED_ROUTES_FILE}.new" > "${INSTALLED_ROUTES_FILE}.sorted" 2>/dev/null || true
        if [[ -n "$PREV_ROUTES" ]]; then
            echo "$PREV_ROUTES" | while read -r old_cidr; do
                [[ -z "$old_cidr" ]] && continue
                if ! grep -qxF "$old_cidr" "${INSTALLED_ROUTES_FILE}.sorted" 2>/dev/null; then
                    ip route del "$old_cidr" dev ${WG_IFACE} 2>/dev/null || true
                fi
            done
        fi
        mv -f "${INSTALLED_ROUTES_FILE}.sorted" "$INSTALLED_ROUTES_FILE" 2>/dev/null || true
        rm -f "${INSTALLED_ROUTES_FILE}.new" 2>/dev/null || true
    else
        # No routes this cycle — remove every previously-tracked CIDR.
        if [[ -n "$PREV_ROUTES" ]]; then
            echo "$PREV_ROUTES" | while read -r old_cidr; do
                [[ -z "$old_cidr" ]] && continue
                ip route del "$old_cidr" dev ${WG_IFACE} 2>/dev/null || true
            done
        fi
        rm -f "$INSTALLED_ROUTES_FILE" 2>/dev/null || true
    fi

    # ── Remove stale WireGuard peers ──
    RESPONSE_PUBKEYS=$(
        echo "$RESPONSE" \
            | jq -r '[(.peers[]?.public_key), (.probe_peers[]?.public_key)] | map(select(. != null and . != "")) | .[]' 2>/dev/null \
            | sort -u
    )
    WG_PUBKEYS=$(wg show ${WG_IFACE} peers 2>/dev/null | sort -u)
    if [[ -n "$WG_PUBKEYS" ]]; then
        echo "$WG_PUBKEYS" | while read -r wg_pk; do
            [[ -z "$wg_pk" ]] && continue
            if ! echo "$RESPONSE_PUBKEYS" | grep -qxF "$wg_pk"; then
                wg set ${WG_IFACE} peer "$wg_pk" remove 2>/dev/null || true
            fi
        done
    fi
done
