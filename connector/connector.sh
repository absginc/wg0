#!/usr/bin/env bash
# wg0 Connector
# Enrolls a node with the Brain and maintains WireGuard connectivity via heartbeat.
#
# Usage:
#   connector.sh enroll <TOKEN> <BRAIN_URL> [NODE_NAME] [OS_TYPE] [ROLE] [ADVERTISED_ROUTES_CSV]
#   connector.sh unenroll [BRAIN_URL]
#   connector.sh check            # health-check host forwarding config
#   connector.sh rotate-secret    # rotate device secret
#   connector.sh update <BRAIN_URL>
#
#   # Legacy positional form (backward compatible — treated as "enroll"):
#   connector.sh <TOKEN> <BRAIN_URL> [NODE_NAME] [OS_TYPE] [ROLE] [ADVERTISED_ROUTES_CSV]
#
# Examples:
#   # Simple client node
#   ./connector.sh enroll eyJhbG... https://brain.example.com
#
#   # Host node advertising a LAN
#   ./connector.sh enroll eyJhbG... https://brain.example.com site-a-gw linux host 192.168.1.0/24
#
#   # Remove this node from the Brain and wipe all local WireGuard config
#   ./connector.sh unenroll https://brain.example.com
#
# Idempotent enroll — safe to re-run. Skips keygen/re-enrollment if already done.

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
WG_IFACE="wg0"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
INSTALLATION_ID_FILE="/etc/wireguard/installation_id"
DEVICE_ID_FILE="/etc/wireguard/device_id"
KEY_DIR="/etc/wireguard/wg0"
PRIV_KEY_FILE="${KEY_DIR}/private.key"
PUB_KEY_FILE="${KEY_DIR}/public.key"
NODE_ID_FILE="${KEY_DIR}/node_id"
DEVICE_SECRET_FILE="${KEY_DIR}/device_secret"
CONFIG_VERSION_FILE="${KEY_DIR}/config_version"
ROLE_FILE="${KEY_DIR}/role"
ADVERTISED_ROUTES_FILE="${KEY_DIR}/advertised_routes"
EGRESS_IFACES_FILE="${KEY_DIR}/egress_ifaces"
NAT_SOURCE_CIDRS_FILE="${KEY_DIR}/nat_source_cidrs"
LAN_PUBLICATION_FILE="${KEY_DIR}/lan_publications"
HEARTBEAT_INTERVAL=30
HEARTBEAT_SCRIPT="/usr/local/bin/wg0-heartbeat"
# Connector version. Bumped each time this script changes in a way
# users need to redeploy — heartbeat carries this so the portal can
# show an "update available" badge on stale nodes.
CONNECTOR_VERSION="2026.05.01-a"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[wg0 $(date -u +%H:%M:%SZ)] $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }
warn() { log "WARNING: $*" >&2; }

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

persist_connector_state() {
    mkdir -p "$KEY_DIR"
    printf '%s' "${ROLE:-client}" > "$ROLE_FILE"
    chmod 600 "$ROLE_FILE"
    printf '%s' "${ADVERTISED_ROUTES_CSV:-}" > "$ADVERTISED_ROUTES_FILE"
    chmod 600 "$ADVERTISED_ROUTES_FILE"
}

load_connector_state() {
    ROLE="$(cat "$ROLE_FILE" 2>/dev/null || true)"
    ADVERTISED_ROUTES_CSV="$(cat "$ADVERTISED_ROUTES_FILE" 2>/dev/null || true)"
    local phys_iface="" default_iface=""

    if [[ -z "$ROLE" && -f "$HEARTBEAT_SCRIPT" ]]; then
        ROLE="$(awk -F'"' '/^ROLE=/{print $2; exit}' "$HEARTBEAT_SCRIPT" 2>/dev/null || true)"
    fi
    if [[ -z "$ADVERTISED_ROUTES_CSV" && -f "$HEARTBEAT_SCRIPT" ]]; then
        ADVERTISED_ROUTES_CSV="$(awk -F'"' '/^ADVERTISED_ROUTES_CSV=/{print $2; exit}' "$HEARTBEAT_SCRIPT" 2>/dev/null || true)"
    fi

    default_iface="$(ip route show default 2>/dev/null | awk '/^default/ && $5 != "'"${WG_IFACE}"'" && $5 != "wg0-up" {print $5; exit}')"

    if [[ -z "$ROLE" && ( -f "${KEY_DIR}/phys_iface" || -f "${KEY_DIR}/wan_iface" || -f "${KEY_DIR}/sysctl_state" ) ]]; then
        ROLE="host"
    fi

    if [[ "$ROLE" != "host" ]]; then
        phys_iface="$(cat "${KEY_DIR}/phys_iface" 2>/dev/null || true)"
        [[ -n "$phys_iface" ]] || phys_iface="$default_iface"
        if [[ -n "$phys_iface" ]] \
            && iptables -C FORWARD -i "$WG_IFACE" -o "$phys_iface" -j ACCEPT 2>/dev/null \
            && iptables -C FORWARD -i "$phys_iface" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; then
            ROLE="host"
        fi
    fi
    [[ -n "$ROLE" ]] || ROLE="client"

    if [[ -z "$ADVERTISED_ROUTES_CSV" && "$ROLE" == "host" ]]; then
        phys_iface="$(cat "${KEY_DIR}/phys_iface" 2>/dev/null || true)"
        [[ -n "$phys_iface" ]] || phys_iface="$default_iface"

        if [[ -n "$phys_iface" ]]; then
            ADVERTISED_ROUTES_CSV="$(
                iptables -t nat -S POSTROUTING 2>/dev/null \
                    | awk -v iface="$phys_iface" '
                        $0 ~ /^-A POSTROUTING/ && $0 ~ ("-o " iface) && $0 ~ /-j MASQUERADE/ {
                            for (i = 1; i <= NF; i++) if ($i == "-s") print $(i+1)
                        }' \
                    | sort -u \
                    | paste -sd, -
            )"
        fi

        if [[ -z "$ADVERTISED_ROUTES_CSV" && -n "$phys_iface" ]]; then
            ADVERTISED_ROUTES_CSV="$(
                ip -4 route show dev "$phys_iface" proto kernel scope link 2>/dev/null \
                    | awk '$1 !~ /^169\.254\./ { print $1 }' \
                    | sort -u \
                    | paste -sd, -
            )"
        fi
    fi

    ADVERTISED_ROUTES_CSV="${ADVERTISED_ROUTES_CSV:-}"
}

reapply_native_lan_host_forwarding_update() {
    [[ "${ROLE:-}" == "host" ]] || return 0
    [[ -n "${ADVERTISED_ROUTES_CSV:-}" ]] || return 0

    local phys_iface="" wan_iface="" first_route="" probe_ip="" iface="" route="" line=""
    declare -A seen=()
    local egress_ifaces=()

    first_route=$(first_valid_ipv4_cidr "$ADVERTISED_ROUTES_CSV" || true)
    if [[ -n "$first_route" ]]; then
        probe_ip=$(echo "$first_route" | cut -d/ -f1)
        phys_iface=$({ ip -4 route get "$probe_ip" 2>/dev/null || true; } | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    elif [[ -n "${ADVERTISED_ROUTES_CSV:-}" ]]; then
        warn "ADVERTISED_ROUTES_CSV='${ADVERTISED_ROUTES_CSV}' contains no valid IPv4 CIDRs. Falling back to default-route detection."
    fi
    if [[ -z "$phys_iface" || "$phys_iface" == "$WG_IFACE" ]]; then
        phys_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    fi
    wan_iface=$(ip route show default 2>/dev/null | awk '/^default/ && $5 != "'"${WG_IFACE}"'" && $5 != "wg0-up" {print $5; exit}')

    for iface in "$phys_iface" "$wan_iface"; do
        [[ -z "$iface" ]] && continue
        [[ -n "${seen[$iface]:-}" ]] && continue
        seen["$iface"]=1
        egress_ifaces+=("$iface")
    done

    IFS=',' read -ra MASQ_ROUTES <<< "$ADVERTISED_ROUTES_CSV"
    for route in "${MASQ_ROUTES[@]}"; do
        route=$(echo "$route" | xargs)
        [[ -z "$route" ]] && continue
        is_ipv4_cidr "$route" || continue
        while read -r line; do
            iface=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
            [[ -z "$iface" || "$iface" == "$WG_IFACE" || "$iface" == "wg0-up" || "$iface" == "lo" ]] && continue
            [[ -n "${seen[$iface]:-}" ]] && continue
            seen["$iface"]=1
            egress_ifaces+=("$iface")
        done < <({ ip -4 route show root "$route" 2>/dev/null || true; })
    done

    [[ -n "$phys_iface" ]] && printf '%s' "$phys_iface" > "${KEY_DIR}/phys_iface"
    [[ -n "$wan_iface" ]] && printf '%s' "$wan_iface" > "${KEY_DIR}/wan_iface"
    printf '%s\n' "${egress_ifaces[@]}" > "${EGRESS_IFACES_FILE}"
    chmod 600 "${KEY_DIR}/phys_iface" "${KEY_DIR}/wan_iface" "${EGRESS_IFACES_FILE}" 2>/dev/null || true

    sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
    sysctl -qw net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
    sysctl -qw "net.ipv4.conf.${WG_IFACE}.rp_filter=0" 2>/dev/null || true
    [[ -n "$phys_iface" ]] && sysctl -qw "net.ipv4.conf.${phys_iface}.rp_filter=0" 2>/dev/null || true
    [[ -n "$wan_iface" && "$wan_iface" != "$phys_iface" ]] && sysctl -qw "net.ipv4.conf.${wan_iface}.rp_filter=0" 2>/dev/null || true

    for iface in "${egress_ifaces[@]}"; do
        [[ -z "$iface" ]] && continue
        iptables -C FORWARD -i "$WG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$WG_IFACE" -o "$iface" -j ACCEPT
        iptables -C FORWARD -i "$iface" -o "$WG_IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$iface" -o "$WG_IFACE" -j ACCEPT
        for route in "${MASQ_ROUTES[@]}"; do
            route=$(echo "$route" | xargs)
            [[ -z "$route" ]] && continue
            iptables -t nat -C POSTROUTING -s "$route" -o "$iface" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$route" -o "$iface" -j MASQUERADE
        done
    done
}

# ── Heartbeat template writer ─────────────────────────────────────────────────
# Used by both `enroll` and `update`. Reads global vars: HEARTBEAT_SCRIPT,
# BRAIN_URL, NODE_ID_FILE, WG_IFACE. Writes a fresh script that:
#   - Reports TX/RX bytes via heartbeat
#   - Applies peer map via `wg set`
#   - Adds matching system routes via `ip route replace` (idempotent)
write_heartbeat_script() {
    cat > "$HEARTBEAT_SCRIPT" <<HBSCRIPT
#!/usr/bin/env bash
# Auto-generated by wg0 connector. Do not edit manually.
NODE_ID="\$(cat ${NODE_ID_FILE})"
ROLE="${ROLE}"
ADVERTISED_ROUTES_CSV="${ADVERTISED_ROUTES_CSV:-}"
ROUTE_ALL_STATE="${KEY_DIR}/route_all_state"
SAME_LAN_STATE="${KEY_DIR}/same_lan_state"
OVERLAY_IP_FILE="${KEY_DIR}/overlay_ip"
COLLECT_TELEMETRY_STATE="${KEY_DIR}/collect_device_telemetry"
TELEMETRY_CPU_SAMPLE="${KEY_DIR}/telemetry_cpu_sample"
EGRESS_IFACES_FILE="${EGRESS_IFACES_FILE}"
NAT_SOURCE_CIDRS_FILE="${NAT_SOURCE_CIDRS_FILE}"
LAN_PUBLICATION_FILE="${LAN_PUBLICATION_FILE}"
# Device protocol v2: read the per-device secret (if this node was
# enrolled under v2). Empty string if the file doesn't exist — the
# brain's DeviceAuth extractor will accept the legacy path for pre-v2
# rows that have no stored hash yet.
DEVICE_SECRET="\$(cat ${DEVICE_SECRET_FILE} 2>/dev/null || true)"
PUBLIC_IP=\$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
ENDPOINT=""
[[ -n "\$PUBLIC_IP" ]] && ENDPOINT="\${PUBLIC_IP}:51820"

# Revoked-node short-circuit (NEXT_STEPS #7C). The brain returned
# 404 "Node revoked" on a previous cycle; we dropped this marker
# and tore the tunnel down. Exit fast on every subsequent tickle.
if [[ -f "${KEY_DIR}/revoked" ]]; then
    exit 0
fi

# If WireGuard is not up, skip — restart will be handled elsewhere.
ip link show ${WG_IFACE} >/dev/null 2>&1 || exit 0

# Collect TX/RX bytes (wg show transfer: <pubkey> <rx_bytes> <tx_bytes>)
TRANSFER=\$(wg show ${WG_IFACE} transfer 2>/dev/null)
TX_BYTES=\$(echo "\$TRANSFER" | awk '{sum += \$3} END {print sum+0}')
RX_BYTES=\$(echo "\$TRANSFER" | awk '{sum += \$2} END {print sum+0}')

# Per-peer observations from \`wg show <iface> dump\` — the brain merges
# these with the discover sidecar for the four-state presence model.
# First line is interface metadata (4 fields), subsequent lines are
# peers (8 fields: pubkey, psk, endpoint, allowed_ips, latest_handshake,
# rx, tx, keepalive). latest_handshake == 0 means "never," mapped to
# JSON null. jq -Rsc builds the JSON safely — no string concat.
PEERS_JSON=\$(wg show ${WG_IFACE} dump 2>/dev/null | tail -n +2 | awk -F'\\t' 'NF>=8 {
    printf "%s\\t%s\\t%s\\t%s\\n", \$1, \$5, \$6, \$7
}' | jq -Rsc '
    split("\\n") | map(select(length > 0) | split("\\t") | {
        public_key: .[0],
        last_handshake: (if .[1] == "0" then null else (.[1] | tonumber) end),
        rx_bytes: (.[2] | tonumber),
        tx_bytes: (.[3] | tonumber)
    })' 2>/dev/null)
[[ -z "\$PEERS_JSON" ]] && PEERS_JSON="[]"

# Report whether route-all is CURRENTLY active on this device. Read from
# the persisted state file that the previous heartbeat cycle wrote. The
# brain uses this to suppress the public-IP-equality same-LAN heuristic
# (which gives a false positive when route-all makes the client appear
# to egress from the host's public IP). "off" or missing file = false.
ROUTE_ALL_PREV_STATE=\$(cat "${KEY_DIR}/route_all_state" 2>/dev/null || echo "off")
if [[ "\$ROUTE_ALL_PREV_STATE" == on* ]]; then
    ROUTE_ALL_ACTIVE=true
else
    ROUTE_ALL_ACTIVE=false
fi

# Helper: find the current non-wg default gateway interface + gateway IP.
get_default() {
    ip route show default 2>/dev/null \
        | grep -v "dev ${WG_IFACE}" \
        | grep -v "dev wg0-up" \
        | awk '/default/{print \$5, \$3; exit}'
}

current_capabilities_json() {
    # "multi_membership_v1" tells the brain this connector can safely
    # hold multiple attached networks at once. The brain checks for it
    # before allowing POST /api/v1/devices/:id/memberships (attach) to
    # succeed. Safe to advertise from any shell connector >=2026-04-20:
    # attach/detach live under distinct wg-quick interfaces (wg0, wg1,
    # wg2...), each with its own state dir, so one membership never
    # clobbers another's state.
    jq -cn '[
        "same_lan_detection",
        "split_tunnel_linux",
        "byo_exit_linux",
        "assisted_relay_probe_peers_v1",
        "peer_observations",
        "device_telemetry_v1",
        "desired_state_convergence",
        "multi_membership_v1",
        "lan_presence_client_v1",
        "lan_presence_linux_v1"
    ]'
}

is_ipv4_cidr() {
    local value="\${1:-}"
    [[ "\$value" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]
}

first_valid_ipv4_cidr() {
    local raw="\${1:-}" route
    IFS=',' read -ra routes <<< "\$raw"
    for route in "\${routes[@]}"; do
        route=\$(echo "\$route" | xargs)
        [[ -z "\$route" ]] && continue
        if is_ipv4_cidr "\$route"; then
            printf '%s\n' "\$route"
            return 0
        fi
    done
    return 1
}

detect_host_lan_ip() {
    [[ "\$ROLE" == "host" ]] || { echo ""; return; }
    [[ -n "\$ADVERTISED_ROUTES_CSV" ]] || { echo ""; return; }

    local phys_iface="" first_route="" probe_ip=""
    [[ -f "${KEY_DIR}/phys_iface" ]] && phys_iface=\$(cat "${KEY_DIR}/phys_iface" 2>/dev/null || true)

    if [[ -z "\$phys_iface" ]]; then
        first_route=\$(first_valid_ipv4_cidr "\$ADVERTISED_ROUTES_CSV" || true)
        if [[ -n "\$first_route" ]]; then
            probe_ip=\$(echo "\$first_route" | cut -d/ -f1)
            phys_iface=\$({ ip -4 route get "\$probe_ip" 2>/dev/null || true; } | awk '/dev/ {for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1); exit}')
        fi
    fi

    if [[ -z "\$phys_iface" || "\$phys_iface" == "${WG_IFACE}" ]]; then
        phys_iface=\$(ip route show default 2>/dev/null | awk '/^default/ {print \$5; exit}')
    fi
    [[ -n "\$phys_iface" ]] || { echo ""; return; }

    ip -4 -o addr show dev "\$phys_iface" scope global 2>/dev/null \
        | awk '{split(\$4, a, "/"); print a[1]; exit}'
}

detect_lan_presence_json() {
    local iface="" gw="" addr="" ip="" prefix="" prefix_json="null" cidr_json="null" transport="ethernet"
    read -r iface gw < <(get_default)
    [[ -n "\$iface" && "\$iface" != "${WG_IFACE}" && "\$iface" != "wg0-up" ]] || { echo "[]"; return; }

    addr=\$(ip -4 -o addr show dev "\$iface" scope global 2>/dev/null | awk '{print \$4; exit}')
    [[ -n "\$addr" ]] || { echo "[]"; return; }
    ip="\${addr%/*}"
    prefix="\${addr#*/}"
    [[ -n "\$ip" && "\$ip" != "\$addr" ]] || { echo "[]"; return; }
    [[ "\$prefix" =~ ^[0-9]+$ ]] && prefix_json="\$prefix"
    case "\$iface" in
        wl*|wifi*|wlan*) transport="wifi" ;;
    esac

    jq -cn \\
        --arg ip "\$ip" \\
        --arg iface "\$iface" \\
        --arg gateway "\$gw" \\
        --arg transport "\$transport" \\
        --argjson prefix_length "\$prefix_json" \\
        --argjson cidr "\$cidr_json" \\
        '[{ip:\$ip, prefix_length:\$prefix_length, cidr:\$cidr, gateway:(\$gateway | select(length > 0)), interface_name:\$iface, transport:\$transport}]'
}

collect_cpu_json() {
    local total idle now_ms prev_total prev_idle prev_ms total_delta idle_delta usage
    read -r total idle < <(awk '/^cpu / { total=0; for (i=2; i<=NF; i++) total += \$i; idle=\$5+\$6; print total, idle; exit }' /proc/stat 2>/dev/null)
    [[ -n "\$total" && -n "\$idle" ]] || { echo "null"; return; }
    now_ms=\$(date +%s%3N 2>/dev/null || awk 'BEGIN{srand(); print int(systime()*1000)}')
    if [[ -f "\$TELEMETRY_CPU_SAMPLE" ]]; then
        read -r prev_total prev_idle prev_ms < "\$TELEMETRY_CPU_SAMPLE" || true
    fi
    printf '%s %s %s\n' "\$total" "\$idle" "\$now_ms" > "\$TELEMETRY_CPU_SAMPLE" 2>/dev/null || true
    chmod 600 "\$TELEMETRY_CPU_SAMPLE" 2>/dev/null || true
    [[ -n "\${prev_total:-}" && -n "\${prev_idle:-}" && -n "\${prev_ms:-}" ]] || { echo "null"; return; }
    total_delta=\$((total - prev_total))
    idle_delta=\$((idle - prev_idle))
    [[ "\$total_delta" -gt 0 ]] || { echo "null"; return; }
    usage=\$(awk -v t="\$total_delta" -v i="\$idle_delta" 'BEGIN { v=((t-i)*100)/t; if (v < 0) v = 0; if (v > 100) v = 100; printf "%.2f", v }')
    jq -cn --argjson system_usage_percent "\$usage" --argjson sample_window_ms "\$((now_ms - prev_ms))" \
        '{system_usage_percent:\$system_usage_percent, app_usage_percent:null, sample_window_ms:\$sample_window_ms}'
}

collect_memory_json() {
    local total_kb available_kb app_rss_kb app_pss_bytes low_memory
    total_kb=\$(awk '/MemTotal:/ {print \$2; exit}' /proc/meminfo 2>/dev/null)
    available_kb=\$(awk '/MemAvailable:/ {print \$2; exit}' /proc/meminfo 2>/dev/null)
    app_rss_kb=\$(awk '/VmRSS:/ {print \$2; exit}' /proc/self/status 2>/dev/null || echo "")
    [[ -n "\$total_kb" && -n "\$available_kb" ]] || { echo "null"; return; }
    app_pss_bytes="null"
    if [[ -n "\$app_rss_kb" ]]; then
        app_pss_bytes=\$((app_rss_kb * 1024))
    fi
    low_memory=\$(awk -v a="\$available_kb" -v t="\$total_kb" 'BEGIN { print (t > 0 && (a / t) < 0.10) ? "true" : "false" }')
    jq -cn \
        --argjson total_bytes "\$((total_kb * 1024))" \
        --argjson available_bytes "\$((available_kb * 1024))" \
        --argjson app_pss_bytes "\$app_pss_bytes" \
        --argjson low_memory "\$low_memory" \
        '{total_bytes:\$total_bytes, available_bytes:\$available_bytes, app_pss_bytes:\$app_pss_bytes, low_memory:\$low_memory}'
}

collect_device_telemetry_json() {
    [[ "\$(cat "\$COLLECT_TELEMETRY_STATE" 2>/dev/null || echo off)" == "on" ]] || { echo "null"; return; }
    local cpu_json memory_json
    cpu_json=\$(collect_cpu_json)
    memory_json=\$(collect_memory_json)
    if [[ "\$cpu_json" == "null" && "\$memory_json" == "null" ]]; then
        echo "null"
        return
    fi
    jq -cn --argjson cpu "\$cpu_json" --argjson memory "\$memory_json" \
        '{battery:null, cpu:\$cpu, memory:\$memory}'
}

default_exit_health_json() {
    [[ "\$ROLE" == "host" ]] || { echo "null"; return; }
    [[ -n "\$ADVERTISED_ROUTES_CSV" ]] || { echo "null"; return; }

    local wan_iface wan_gw interface_up=false nat_ok=false forward_ok=false now_ts route
    read -r wan_iface wan_gw < <(get_default)
    if [[ -z "\$wan_iface" || "\$wan_iface" == "${WG_IFACE}" || "\$wan_iface" == "wg0-up" ]]; then
        echo '{"interface_up": false, "last_handshake": null}'
        return
    fi

    if ip link show "\$wan_iface" >/dev/null 2>&1; then
        interface_up=true
    fi

    if \$interface_up; then
        if iptables -C FORWARD -i "${WG_IFACE}" -o "\$wan_iface" -j ACCEPT 2>/dev/null \
            && iptables -C FORWARD -i "\$wan_iface" -o "${WG_IFACE}" -j ACCEPT 2>/dev/null; then
            forward_ok=true
        fi

        IFS=',' read -ra ROUTE_LIST <<< "\$ADVERTISED_ROUTES_CSV"
        for route in "\${ROUTE_LIST[@]}"; do
            route=\$(echo "\$route" | xargs)
            [[ -z "\$route" ]] && continue
            if iptables -t nat -C POSTROUTING -s "\$route" -o "\$wan_iface" -j MASQUERADE 2>/dev/null; then
                nat_ok=true
                break
            fi
        done
    fi

    if \$interface_up && \$nat_ok && \$forward_ok && [[ -n "\$PUBLIC_IP" ]]; then
        now_ts=\$(date +%s)
        jq -cn --argjson lh "\$now_ts" '{interface_up: true, last_handshake: \$lh}'
    elif \$interface_up && \$nat_ok && \$forward_ok; then
        echo '{"interface_up": true, "last_handshake": null}'
    else
        echo '{"interface_up": false, "last_handshake": null}'
    fi
}

# BYO Exit kill-switch health probe (host nodes). If a previous
# heartbeat's BYO state machine brought up wg0-up via wg-quick, read
# its current handshake timestamp and report it to the brain so the
# dashboard can surface upstream failures. Linux uses the literal
# interface name — no utun indirection. Non-hosts and hosts without
# a currently-installed upstream send null so the brain doesn't
# overwrite anything.
UPSTREAM_HEALTH_JSON="null"
if ip link show wg0-up >/dev/null 2>&1; then
    WG_UP_LAST_HS=\$(wg show wg0-up latest-handshakes 2>/dev/null | awk '{ if (\$2 > 0) print \$2 }' | sort -nr | head -1)
    if [[ -n "\$WG_UP_LAST_HS" ]]; then
        UPSTREAM_HEALTH_JSON=\$(jq -cn --argjson lh "\$WG_UP_LAST_HS" '{interface_up: true, last_handshake: \$lh}')
    else
        UPSTREAM_HEALTH_JSON='{"interface_up": true, "last_handshake": null}'
    fi
elif [[ "\$ROLE" == "host" ]]; then
    UPSTREAM_HEALTH_JSON=\$(default_exit_health_json)
fi

CAPABILITIES_JSON=\$(current_capabilities_json)
HOST_LAN_IP=\$(detect_host_lan_ip)
HOST_LAN_IP_JSON=\$(jq -Rn --arg v "\$HOST_LAN_IP" 'if (\$v | length) > 0 then \$v else null end')
LAN_PRESENCE_JSON=\$(detect_lan_presence_json)
INSTALLATION_ID_JSON=\$(jq -Rn --arg v "\$(cat ${INSTALLATION_ID_FILE} 2>/dev/null || echo "")" 'if (\$v | length) > 0 then \$v else null end')
TELEMETRY_JSON=\$(collect_device_telemetry_json)

HB_BODY=\$(jq -cn \\
    --arg endpoint "\$ENDPOINT" \\
    --arg connector_version "${CONNECTOR_VERSION}" \\
    --argjson installation_id "\$INSTALLATION_ID_JSON" \\
    --argjson capabilities "\$CAPABILITIES_JSON" \\
    --argjson tx_bytes \$TX_BYTES \\
    --argjson rx_bytes \$RX_BYTES \\
    --argjson peers "\$PEERS_JSON" \\
    --argjson route_all_active \$ROUTE_ALL_ACTIVE \\
    --argjson host_lan_ip "\$HOST_LAN_IP_JSON" \\
    --argjson lan_presence "\$LAN_PRESENCE_JSON" \\
    --argjson upstream_exit_health "\$UPSTREAM_HEALTH_JSON" \\
    --argjson telemetry "\$TELEMETRY_JSON" \\
    '{endpoint:\$endpoint, installation_id:\$installation_id, capabilities:\$capabilities,
      host_lan_ip:\$host_lan_ip, tx_bytes:\$tx_bytes, rx_bytes:\$rx_bytes, peers:\$peers,
      lan_presence:\$lan_presence,
      route_all_active:\$route_all_active, upstream_exit_health:\$upstream_exit_health,
      telemetry:\$telemetry, connector_version:\$connector_version}')

CURL_ARGS=( -sf -X POST -H "Content-Type: application/json" )
[[ -n "\$DEVICE_SECRET" ]] && CURL_ARGS+=( -H "X-Device-Secret: \$DEVICE_SECRET" )
HB_OUT=\$(curl -sS -w "\\n__hb_http_status__%{http_code}" \\
    -X POST -H "Content-Type: application/json" \\
    \$([[ -n "\$DEVICE_SECRET" ]] && echo "-H X-Device-Secret:\$DEVICE_SECRET") \\
    -d "\$HB_BODY" \\
    "${BRAIN_URL}/api/v1/nodes/\${NODE_ID}/heartbeat" 2>/dev/null || true)
HB_STATUS=\$(echo "\$HB_OUT" | awk -F'__hb_http_status__' 'END{print \$2}' | tr -d '[:space:]')
RESPONSE=\$(echo "\$HB_OUT" | awk -F'__hb_http_status__' '{print \$1}' | sed '\$d')

# Node-deletion tear-down (ROADBLOCKS §15, NEXT_STEPS #7). Brain now
# returns 404 "Node revoked" from the heartbeat endpoint when this
# node_id has been soft-deleted. Before this branch, curl -sf swallowed
# the response and we'd keep heartbeating into the void while the
# tunnel kept running as a zombie. Now: classify 404 + revoked/not
# found as terminal, tear down the tunnel, drop \$KEY_DIR/revoked so
# subsequent systemd tickles exit fast.
if [[ "\$HB_STATUS" == "404" ]]; then
    DETAIL=\$(echo "\$RESPONSE" | jq -r '.detail // .error // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if echo "\$DETAIL" | grep -qE 'revoked|not found|node not found'; then
        echo "[wg0 \$(date -u +%H:%M:%SZ)] brain returned 404 '\$DETAIL' — node revoked. Tearing down tunnel." >&2
        echo "\$DETAIL" > "${KEY_DIR}/revoked" 2>/dev/null || true
        wg-quick down ${WG_IFACE} 2>/dev/null || true
        echo "[wg0 \$(date -u +%H:%M:%SZ)] to reconnect: remove \${KEY_DIR}/revoked and re-enroll via '\$0 enroll <TOKEN> <BRAIN_URL>'" >&2
        exit 0
    fi
fi
if [[ -z "\$HB_STATUS" || "\$HB_STATUS" -ge 400 ]]; then
    if [[ "\${WG0_HEARTBEAT_STRICT:-0}" == "1" ]]; then
        exit 1
    fi
    exit 0
fi

# Successful heartbeat: stamp a marker file so \`wg0 status\` can report
# Last beat accurately. The systemd-appended log file only grows when
# the script writes to stdout/stderr, which almost never happens on
# the happy path — so relying on its mtime gives stale readings. Touch
# a dedicated marker every cycle; wg0-status prefers it over log mtime.
touch "${KEY_DIR}/last_heartbeat" 2>/dev/null || true

if [[ "\$(echo "\$RESPONSE" | jq -r '.collect_device_telemetry // false' 2>/dev/null)" == "true" ]]; then
    echo "on" > "\$COLLECT_TELEMETRY_STATE"
else
    echo "off" > "\$COLLECT_TELEMETRY_STATE"
fi

# ── Config drift detection (device protocol v2) ──────────────────────────
# Every heartbeat we GET the brain's rendered wg_config and check it
# against what's on disk. If different, rewrite the file AND wg
# syncconf. If identical, no-op — cmp returns 0.
#
# Why every heartbeat (not just on config_version bump): peer Endpoint
# values change with relay/discover/direct transitions and DO NOT bump
# config_version. Pre-2026.04.27, that meant /etc/wireguard/wg0.conf
# grew stale on disk while live kernel state was kept fresh by the
# per-peer \`wg set\` calls. After a reboot, wg-quick read the stale
# file and reinstated old endpoints — Scott saw a peer endpoint
# 24.127.208.189:1111 (months-old NAT mapping) hanging around for
# minutes after wg-quick up.
REMOTE_CONFIG_VERSION=\$(echo "\$RESPONSE" | jq -r '.config_version // 0')
CONFIG_CURL_ARGS=( -sf )
[[ -n "\$DEVICE_SECRET" ]] && CONFIG_CURL_ARGS+=( -H "X-Device-Secret: \$DEVICE_SECRET" )
NEW_CFG_JSON=\$(curl "\${CONFIG_CURL_ARGS[@]}" \\
    "${BRAIN_URL}/api/v1/nodes/\${NODE_ID}/config" 2>/dev/null || true)
if [[ -n "\$NEW_CFG_JSON" ]]; then
    NEW_WG_CONFIG=\$(echo "\$NEW_CFG_JSON" | jq -r '.wg_config // empty')
    if [[ -n "\$NEW_WG_CONFIG" && -f "${PRIV_KEY_FILE}" ]]; then
        PRIV_KEY_VALUE=\$(cat "${PRIV_KEY_FILE}")
        TMP_CONF=\$(mktemp)
        echo "\$NEW_WG_CONFIG" \\
            | sed "s|# PrivateKey = <CONNECTOR_FILLS_THIS_IN>|PrivateKey = \${PRIV_KEY_VALUE}|" \\
            > "\$TMP_CONF"
        chmod 600 "\$TMP_CONF"
        # Compare-and-swap: only syncconf when something actually
        # changed. Avoids thrashing the kernel state when the brain
        # returns the same bytes for two heartbeats running.
        if ! cmp -s "\$TMP_CONF" "${WG_CONF}" 2>/dev/null; then
            mv -f "\$TMP_CONF" "${WG_CONF}"
            wg syncconf ${WG_IFACE} <(wg-quick strip "${WG_CONF}") 2>/dev/null || true
        else
            rm -f "\$TMP_CONF"
        fi
        echo "\$REMOTE_CONFIG_VERSION" > "${CONFIG_VERSION_FILE}"
        chmod 600 "${CONFIG_VERSION_FILE}"
    fi
fi

# Our own overlay /32, kept for same-LAN route suppression and cleanup
# of aliases written by older connector builds.
OVERLAY_IP=\$(cat "\$OVERLAY_IP_FILE" 2>/dev/null | tr -d '[:space:]')

# ── First pass: extract control-plane signals from peer list ──────────────
WANT_ROUTE_ALL=0
ROUTE_ALL_EP=""
ON_SAME_LAN=0
SAME_LAN_PEER_CIDRS=""  # space-separated, to be skipped in the per-peer route loop
while read -r _p; do
    _a=\$(echo "\$_p" | jq -r '.allowed_ips')
    _sl=\$(echo "\$_p" | jq -r '.on_same_lan // false')
    if [[ "\$_a" == *"0.0.0.0/0"* ]]; then
        WANT_ROUTE_ALL=1
        ROUTE_ALL_EP=\$(echo "\$_p" | jq -r '.endpoint // empty')
    fi
    if [[ "\$_sl" == "true" ]]; then
        ON_SAME_LAN=1
        for _c in \$(echo "\$_a" | tr ',' ' '); do
            SAME_LAN_PEER_CIDRS="\$SAME_LAN_PEER_CIDRS \$_c"
        done
    fi
done < <(echo "\$RESPONSE" | jq -c '.peers[]' 2>/dev/null)

# ── Route-all (full VPN) state machine ──────────────────────────────────────
ROUTE_ALL_PREV=\$(cat "\$ROUTE_ALL_STATE" 2>/dev/null || echo "off")

if [[ "\$WANT_ROUTE_ALL" = "1" && "\$ON_SAME_LAN" = "0" && -n "\$ROUTE_ALL_EP" ]]; then
    # Install exception route for the host's public endpoint via the
    # physical default gateway, then overlay the tunnel with two /1 routes
    # (more specific than the existing /0, so the endpoint exception wins).
    # We SKIP route-all install when on_same_lan is set: the tunnel can't
    # be trusted to carry traffic when we're on the host's LAN (hairpin
    # NAT would break the handshake).
    ENDPOINT_IP="\${ROUTE_ALL_EP%:*}"
    read -r _ DEFAULT_GW < <(get_default)
    if [[ -n "\$DEFAULT_GW" && -n "\$ENDPOINT_IP" ]]; then
        ip route replace "\${ENDPOINT_IP}/32" via "\$DEFAULT_GW" 2>/dev/null || true
    fi
    ip route replace 0.0.0.0/1   dev ${WG_IFACE} 2>/dev/null || true
    ip route replace 128.0.0.0/1 dev ${WG_IFACE} 2>/dev/null || true
    echo "on|\${ENDPOINT_IP}" > "\$ROUTE_ALL_STATE"
elif [[ "\$ROUTE_ALL_PREV" == on* ]]; then
    # Transition OUT of route-all: tear down /1 routes and the endpoint exception.
    ip route del 0.0.0.0/1   dev ${WG_IFACE} 2>/dev/null || true
    ip route del 128.0.0.0/1 dev ${WG_IFACE} 2>/dev/null || true
    PREV_EP="\${ROUTE_ALL_PREV#*|}"
    [[ -n "\$PREV_EP" ]] && ip route del "\${PREV_EP}/32" 2>/dev/null || true
    echo "off" > "\$ROUTE_ALL_STATE"
fi

# ── Same-LAN state machine ─────────────────────────────────────────────────
# Same-LAN transition. Upgraded clients no longer alias their assigned
# native /32 onto the physical interface. They report lan_presence and
# the active host publishes assigned_ip -> physical_ip for LAN peers.
# Keep the route suppression, and clean up any alias left by older builds.
SAME_LAN_PREV=\$(cat "\$SAME_LAN_STATE" 2>/dev/null || echo "off")

if [[ "\$ON_SAME_LAN" = "1" && -n "\$OVERLAY_IP" ]]; then
    for _c in \$SAME_LAN_PEER_CIDRS; do
        ip route del "\$_c" dev ${WG_IFACE} 2>/dev/null || true
    done
    if [[ "\$SAME_LAN_PREV" == on* ]]; then
        IFS='|' read -r _ PREV_IFACE PREV_OVERLAY <<< "\$SAME_LAN_PREV"
        if [[ -n "\$PREV_IFACE" && -n "\$PREV_OVERLAY" ]]; then
            ip addr del "\${PREV_OVERLAY}/32" dev "\$PREV_IFACE" 2>/dev/null || true
        fi
    fi
    echo "off" > "\$SAME_LAN_STATE"
elif [[ "\$SAME_LAN_PREV" == on* ]]; then
    IFS='|' read -r _ PREV_IFACE PREV_OVERLAY <<< "\$SAME_LAN_PREV"
    if [[ -n "\$PREV_IFACE" && -n "\$PREV_OVERLAY" ]]; then
        ip addr del "\${PREV_OVERLAY}/32" dev "\$PREV_IFACE" 2>/dev/null || true
    fi
    echo "off" > "\$SAME_LAN_STATE"
fi

# ── BYO Exit: upstream WireGuard tunnel state machine (host nodes) ─────────
# The heartbeat response carries an optional \`upstream_exit\` object for host
# nodes that have an active exit assigned. Brain ships the full wg_config
# inline; we persist it as /etc/wireguard/wg0-up.conf and \`wg-quick up\` it.
#
# Desired state is encoded in UPSTREAM_STATE ("<id>" when active, "off"
# otherwise). Transitions:
#   off → on      : write conf, wg-quick up, install host-reachability
#                   policy route so our wg0 listener stays reachable
#   on  → on (same id): no-op (config may have been updated, refresh anyway)
#   on  → on (different id): tear down old, bring up new
#   on  → off     : wg-quick down, strip policy routing
UPSTREAM_STATE_FILE="${KEY_DIR}/upstream_exit_state"
UPSTREAM_CONF="/etc/wireguard/wg0-up.conf"

WANT_UPSTREAM_ID=\$(echo "\$RESPONSE" | jq -r '.upstream_exit.id // empty' 2>/dev/null)
WANT_UPSTREAM_CFG=\$(echo "\$RESPONSE" | jq -r '.upstream_exit.wg_config // empty' 2>/dev/null)
PREV_UPSTREAM_ID=\$(cat "\$UPSTREAM_STATE_FILE" 2>/dev/null || echo "off")

install_upstream_tunnel() {
    local cfg="\$1"

    # Write the config to disk with tight perms — it contains a private key.
    umask 077
    echo "\$cfg" > "\$UPSTREAM_CONF"

    # Host-reachability policy route: when the upstream tunnel becomes the
    # default route, our wg0 UDP listener's replies would go out via the
    # upstream (wrong interface, wrong source IP, black-holed). Mark packets
    # sourced from UDP 51820 and steer them via the ORIGINAL physical
    # gateway before the upstream takes over.
    local orig_iface orig_gw
    read -r orig_iface orig_gw < <(get_default)
    if [[ -n "\$orig_iface" && -n "\$orig_gw" ]]; then
        # Secondary routing table 51820: default via original ISP gateway
        grep -q '^51820 wg0-listener' /etc/iproute2/rt_tables 2>/dev/null \
            || echo "51820 wg0-listener" >> /etc/iproute2/rt_tables 2>/dev/null || true
        ip route replace default via "\$orig_gw" dev "\$orig_iface" table 51820 2>/dev/null || true
        ip rule del fwmark 0x100 lookup 51820 2>/dev/null || true
        ip rule add fwmark 0x100 lookup 51820 2>/dev/null || true
        # Tag packets sourced from UDP 51820 on output
        iptables -t mangle -C OUTPUT -p udp --sport 51820 -j MARK --set-mark 0x100 2>/dev/null \
            || iptables -t mangle -A OUTPUT -p udp --sport 51820 -j MARK --set-mark 0x100 2>/dev/null || true
    fi

    # Bring the upstream tunnel up (wg-quick handles the default route
    # replacement for us when AllowedIPs includes 0.0.0.0/0)
    wg-quick up "\$UPSTREAM_CONF" 2>/dev/null || wg-quick up wg0-up 2>/dev/null || true
}

teardown_upstream_tunnel() {
    wg-quick down wg0-up 2>/dev/null \
        || wg-quick down "\$UPSTREAM_CONF" 2>/dev/null || true
    # Remove policy rules (best-effort)
    ip rule del fwmark 0x100 lookup 51820 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p udp --sport 51820 -j MARK --set-mark 0x100 2>/dev/null || true
    rm -f "\$UPSTREAM_CONF"
}

if [[ -n "\$WANT_UPSTREAM_ID" && -n "\$WANT_UPSTREAM_CFG" ]]; then
    if [[ "\$PREV_UPSTREAM_ID" != "\$WANT_UPSTREAM_ID" ]]; then
        # Transition: either off→on or on→different id. Tear down any
        # existing upstream before installing the new one.
        [[ "\$PREV_UPSTREAM_ID" != "off" ]] && teardown_upstream_tunnel
        install_upstream_tunnel "\$WANT_UPSTREAM_CFG"
        echo "\$WANT_UPSTREAM_ID" > "\$UPSTREAM_STATE_FILE"
    fi
elif [[ "\$PREV_UPSTREAM_ID" != "off" ]]; then
    # Transition on → off
    teardown_upstream_tunnel
    echo "off" > "\$UPSTREAM_STATE_FILE"
fi

# ── Apply peer map updates + stale route cleanup ──────────────────────────
# wg set updates WireGuard's crypto-key routing table. System routes are
# added for each allowed_ips CIDR so packets actually reach the tunnel.
# 0.0.0.0/0 is handled above via the split-tunnel state machine — skip it
# in the per-peer loop so we don't clobber the /1 pair with a /0 replace.
# Peers flagged on_same_lan also skip route installation — LAN handles it.
#
# Kernel-truth reconciliation: \`ip route replace X dev \${WG_IFACE}\` is
# called for every desired CIDR every cycle. It's idempotent at the
# kernel level, so we don't need an on-disk cache to decide whether to
# add — we just always (re-)assert. Prune stale routes by listing what
# the kernel has on our iface right now and deleting anything not in
# the desired set. The on-disk INSTALLED_ROUTES_FILE is kept as an
# operator-visible record and a belt-and-suspenders input to the prune
# loop (in case a route is on disk but the kernel no longer has it —
# we still try the iface-scoped delete, which is a safe no-op if the
# kernel is already clean).

route_log() {
    echo "[wg0-route \$(date -u +%H:%M:%SZ)] \$*" >&2
}

# phys_iface_allows_tunnel_cidr: return 0 iff \$cidr is not already
# owned by a non-\${WG_IFACE} interface. Protects against the roaming
# case where a host-mode node (or client that happens to share LAN
# with its host) ends up with the same /24 on both wg0 and eth0.
# /32 routes are always allowed (host-specific; they don't collide).
phys_iface_allows_tunnel_cidr() {
    local cidr="\$1" prefix existing
    prefix="\${cidr#*/}"
    [[ "\$prefix" == "32" ]] && return 0
    existing=\$(ip -4 -o route show to exact "\$cidr" 2>/dev/null \\
        | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}' \\
        | grep -v "^${WG_IFACE}\$" \\
        | head -n1)
    if [[ -n "\$existing" ]]; then
        return 1
    fi
    return 0
}

# reconcile_iface_routes: shared kernel-truth reconciler used for both
# the primary wg0 and every attached wgN iface.
#   \$1 = iface name (e.g., wg0 or wg1)
#   \$2 = state dir (KEY_DIR for primary, /etc/wireguard/wgN for attached)
#   \$3 = the full v1 heartbeat RESPONSE JSON for this iface
#   \$4 = this iface's own overlay IP (skip pruning its /32)
#   \$5 = "primary" | "attached" — attached skips on_same_lan suppression
#         (attached memberships never run the same-LAN state machine).
reconcile_iface_routes() {
    local iface="\$1" state_dir="\$2" response="\$3" overlay_ip="\$4" mode="\${5:-primary}"
    [[ -z "\$iface" || -z "\$state_dir" || -z "\$response" ]] && return 0

    mkdir -p "\$state_dir" 2>/dev/null || true
    local installed_file="\${state_dir}/installed_routes"
    local desired_file="\${installed_file}.new"
    : > "\$desired_file"
    local prev_disk_routes=""
    [[ -f "\$installed_file" ]] && prev_disk_routes=\$(cat "\$installed_file")

    echo "\$response" | jq -c '.peers[]' 2>/dev/null | while read -r peer; do
        local pubkey allowed ep peer_same_lan
        pubkey=\$(echo "\$peer" | jq -r '.public_key')
        allowed=\$(echo "\$peer" | jq -r '.allowed_ips')
        ep=\$(echo "\$peer" | jq -r '.endpoint // empty')
        peer_same_lan=\$(echo "\$peer" | jq -r '.on_same_lan // false')
        if [[ -n "\$ep" ]]; then
            wg set "\$iface" peer "\$pubkey" allowed-ips "\$allowed" endpoint "\$ep" persistent-keepalive 25
        else
            wg set "\$iface" peer "\$pubkey" allowed-ips "\$allowed" persistent-keepalive 25
        fi
        if [[ "\$mode" == "primary" && "\$peer_same_lan" == "true" ]]; then
            continue
        fi
        echo "\$allowed" | tr ',' '\\n' | tr -d ' ' | while read -r cidr; do
            [[ -z "\$cidr" || "\$cidr" == "0.0.0.0/0" ]] && continue
            if ! phys_iface_allows_tunnel_cidr_for "\$cidr" "\$iface"; then
                route_log "skip add \$cidr on \$iface: physical interface already owns this prefix"
                continue
            fi
            local err
            if ! err=\$(ip route replace "\$cidr" dev "\$iface" 2>&1); then
                route_log "add \$cidr via \$iface failed: \${err:-no stderr}"
            fi
            echo "\$cidr" >> "\$desired_file"
        done
    done

    echo "\$response" | jq -c '.probe_peers[]?' 2>/dev/null | while read -r peer; do
        local pubkey ep keepalive
        pubkey=\$(echo "\$peer" | jq -r '.public_key // empty')
        ep=\$(echo "\$peer" | jq -r '.endpoint // empty')
        keepalive=\$(echo "\$peer" | jq -r '.persistent_keepalive // 25')
        [[ -z "\$pubkey" || -z "\$ep" ]] && continue
        wg set "\$iface" peer "\$pubkey" endpoint "\$ep" persistent-keepalive "\$keepalive"
    done

    local own_cidr=""
    [[ -n "\$overlay_ip" ]] && own_cidr="\${overlay_ip}/32"

    if [[ -s "\$desired_file" ]]; then
        sort -u "\$desired_file" > "\${desired_file}.sorted" 2>/dev/null || true
        local kernel_on_iface
        # Normalize kernel route output to CIDR form. \`ip route\` omits
        # \`/32\` for host routes (it prints \`10.0.0.5\` not \`10.0.0.5/32\`),
        # but the desired-routes file always carries the CIDR — so the
        # naive comparison flagged every /32 we just installed as stale
        # and the cleanup loop deleted it on the same heartbeat. Append
        # /32 to any prefix-less line so the comparison matches.
        kernel_on_iface=\$(ip -4 -o route show dev "\$iface" 2>/dev/null | awk '{print (\$1 ~ /\\//) ? \$1 : \$1 "/32"}' | sort -u)
        {
            echo "\$kernel_on_iface"
            echo "\$prev_disk_routes"
        } | sort -u | while read -r candidate; do
            [[ -z "\$candidate" ]] && continue
            [[ -n "\$own_cidr" && "\$candidate" == "\$own_cidr" ]] && continue
            if ! grep -qxF "\$candidate" "\${desired_file}.sorted" 2>/dev/null; then
                local err
                if ! err=\$(ip route del "\$candidate" dev "\$iface" 2>&1); then
                    echo "\$err" | grep -qi 'no such process\\|not found' || \\
                        route_log "delete \$candidate from \$iface failed: \${err:-no stderr}"
                fi
            fi
        done
        mv -f "\${desired_file}.sorted" "\$installed_file" 2>/dev/null || true
        rm -f "\$desired_file" 2>/dev/null || true
    else
        local kernel_on_iface
        # Normalize kernel route output to CIDR form. \`ip route\` omits
        # \`/32\` for host routes (it prints \`10.0.0.5\` not \`10.0.0.5/32\`),
        # but the desired-routes file always carries the CIDR — so the
        # naive comparison flagged every /32 we just installed as stale
        # and the cleanup loop deleted it on the same heartbeat. Append
        # /32 to any prefix-less line so the comparison matches.
        kernel_on_iface=\$(ip -4 -o route show dev "\$iface" 2>/dev/null | awk '{print (\$1 ~ /\\//) ? \$1 : \$1 "/32"}' | sort -u)
        {
            echo "\$kernel_on_iface"
            echo "\$prev_disk_routes"
        } | sort -u | while read -r candidate; do
            [[ -z "\$candidate" ]] && continue
            [[ -n "\$own_cidr" && "\$candidate" == "\$own_cidr" ]] && continue
            ip route del "\$candidate" dev "\$iface" 2>/dev/null || true
        done
        rm -f "\$installed_file" "\$desired_file" 2>/dev/null || true
    fi

    # Remove stale WireGuard peers the brain no longer advertises.
    local response_pubkeys wg_pubkeys
    response_pubkeys=\$(
        echo "\$response" \\
            | jq -r '[(.peers[]?.public_key), (.probe_peers[]?.public_key)] | map(select(. != null and . != "")) | .[]' 2>/dev/null \\
            | sort -u
    )
    wg_pubkeys=\$(wg show "\$iface" peers 2>/dev/null | sort -u)
    if [[ -n "\$wg_pubkeys" ]]; then
        echo "\$wg_pubkeys" | while read -r wg_pk; do
            [[ -z "\$wg_pk" ]] && continue
            if ! echo "\$response_pubkeys" | grep -qxF "\$wg_pk"; then
                wg set "\$iface" peer "\$wg_pk" remove 2>/dev/null || true
            fi
        done
    fi
}

# Iface-aware variant of phys_iface_allows_tunnel_cidr for the reusable
# reconciler (the original hard-coded \${WG_IFACE}).
phys_iface_allows_tunnel_cidr_for() {
    local cidr="\$1" tun_iface="\$2" prefix existing
    prefix="\${cidr#*/}"
    [[ "\$prefix" == "32" ]] && return 0
    existing=\$(ip -4 -o route show to exact "\$cidr" 2>/dev/null \\
        | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}' \\
        | grep -v "^\${tun_iface}\$" \\
        | head -n1)
    if [[ -n "\$existing" ]]; then
        return 1
    fi
    return 0
}

route_in_advertised_routes() {
    local candidate="\${1:-}" route
    [[ -z "\$candidate" ]] && return 1
    IFS=',' read -ra route_list <<< "\$ADVERTISED_ROUTES_CSV"
    for route in "\${route_list[@]}"; do
        route=\$(echo "\$route" | xargs)
        [[ -z "\$route" ]] && continue
        [[ "\$candidate" == "\$route" ]] && return 0
    done
    return 1
}

peer_source_cidrs_from_response() {
    local response="\${1:-}" cidr
    [[ -z "\$response" ]] && return 0
    echo "\$response" | jq -r '.peers[]?.allowed_ips // empty' 2>/dev/null \\
        | tr ',' '\\n' \\
        | while read -r cidr; do
            cidr=\$(echo "\$cidr" | xargs)
            [[ -z "\$cidr" || "\$cidr" == "0.0.0.0/0" || "\$cidr" == "100.64.1.1/32" ]] && continue
            is_ipv4_cidr "\$cidr" || continue
            route_in_advertised_routes "\$cidr" && continue
            printf '%s\\n' "\$cidr"
        done \\
        | sort -u
}

reconcile_host_source_nat_from_response() {
    [[ "\$ROLE" == "host" ]] || return 0
    [[ -n "\${ADVERTISED_ROUTES_CSV:-}" ]] || return 0
    local response="\${1:-}" tmp desired_file prev_file iface cidr old
    [[ -n "\$response" ]] || return 0

    mapfile -t egress_ifaces < "\$EGRESS_IFACES_FILE" 2>/dev/null || egress_ifaces=()
    [[ "\${#egress_ifaces[@]}" -gt 0 ]] || return 0

    tmp=\$(mktemp)
    peer_source_cidrs_from_response "\$response" > "\$tmp" || true

    desired_file="\${NAT_SOURCE_CIDRS_FILE}.new"
    : > "\$desired_file"
    for iface in "\${egress_ifaces[@]}"; do
        [[ -z "\$iface" ]] && continue
        while read -r cidr; do
            [[ -z "\$cidr" ]] && continue
            if ! iptables -t nat -C POSTROUTING -s "\$cidr" -o "\$iface" -m comment --comment "wg0 source NAT" -j MASQUERADE 2>/dev/null; then
                iptables -t nat -I POSTROUTING 1 -s "\$cidr" -o "\$iface" -m comment --comment "wg0 source NAT" -j MASQUERADE 2>/dev/null || true
            fi
            printf '%s %s\\n' "\$iface" "\$cidr" >> "\$desired_file"
        done < "\$tmp"
    done
    rm -f "\$tmp"

    prev_file="\$NAT_SOURCE_CIDRS_FILE"
    if [[ -f "\$prev_file" ]]; then
        while read -r iface old; do
            [[ -z "\$iface" || -z "\$old" ]] && continue
            grep -qxF "\$iface \$old" "\$desired_file" 2>/dev/null && continue
            while iptables -t nat -C POSTROUTING -s "\$old" -o "\$iface" -m comment --comment "wg0 source NAT" -j MASQUERADE 2>/dev/null; do
                iptables -t nat -D POSTROUTING -s "\$old" -o "\$iface" -m comment --comment "wg0 source NAT" -j MASQUERADE 2>/dev/null || break
            done
        done < "\$prev_file"
    fi
    mv -f "\$desired_file" "\$prev_file" 2>/dev/null || true
}

is_ipv4_addr() {
    local value="\${1:-}" IFS=. octet
    [[ "\$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<< "\$value"
    for octet in "\${octets[@]}"; do
        [[ "\$octet" =~ ^[0-9]+$ && "\$octet" -ge 0 && "\$octet" -le 255 ]] || return 1
    done
    return 0
}

host_lan_ip_for_iface() {
    local iface="\${1:-}"
    [[ -n "\$iface" ]] || return 0
    ip -4 -o addr show dev "\$iface" scope global 2>/dev/null \\
        | awk 'NR==1 {split(\$4, a, "/"); print a[1]}'
}

remove_lan_publication_mapping() {
    local iface="\$1" assigned="\$2" lan_ip="\$3" host_ip="\$4" nat_mode="\${5:-snat}"
    [[ -z "\$iface" || -z "\$assigned" || -z "\$lan_ip" ]] && return 0
    while iptables -t nat -C PREROUTING -i "\$iface" -d "\${assigned}/32" -m comment --comment "wg0 lan publish" -j DNAT --to-destination "\$lan_ip" 2>/dev/null; do
        iptables -t nat -D PREROUTING -i "\$iface" -d "\${assigned}/32" -m comment --comment "wg0 lan publish" -j DNAT --to-destination "\$lan_ip" 2>/dev/null || break
    done
    if [[ "\$nat_mode" == "snat" && -n "\$host_ip" ]]; then
        while iptables -t nat -C POSTROUTING -o "\$iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j SNAT --to-source "\$host_ip" 2>/dev/null; do
            iptables -t nat -D POSTROUTING -o "\$iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j SNAT --to-source "\$host_ip" 2>/dev/null || break
        done
    else
        while iptables -t nat -C POSTROUTING -o "\$iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j MASQUERADE 2>/dev/null; do
            iptables -t nat -D POSTROUTING -o "\$iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j MASQUERADE 2>/dev/null || break
        done
    fi
    while iptables -C FORWARD -i "\$iface" -o "\$iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "\$iface" -o "\$iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null || break
    done
    while iptables -C FORWARD -i "\$iface" -o "\$iface" -s "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "\$iface" -o "\$iface" -s "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null || break
    done
    ip addr del "\${assigned}/32" dev "\$iface" 2>/dev/null || true
}

reconcile_lan_publications_from_response() {
    [[ "\$ROLE" == "host" ]] || return 0
    local response="\${1:-}" phys_iface desired_file prev_file iface assigned lan_ip lan_cidr node_id host_ip nat_mode
    [[ -n "\$response" ]] || return 0

    phys_iface=\$(cat "${KEY_DIR}/phys_iface" 2>/dev/null || true)
    if [[ -z "\$phys_iface" && -f "\$EGRESS_IFACES_FILE" ]]; then
        phys_iface=\$(head -n 1 "\$EGRESS_IFACES_FILE" 2>/dev/null || true)
    fi
    [[ -n "\$phys_iface" ]] || return 0

    host_ip=\$(host_lan_ip_for_iface "\$phys_iface")
    desired_file="\${LAN_PUBLICATION_FILE}.new"
    : > "\$desired_file"

    echo "\$response" | jq -r '
        .lan_publication.published_clients[]?
        | select(.publication_mode == "lan_dnat")
        | select((.assigned_ip // "") != "" and (.lan_ip // "") != "")
        | [.assigned_ip, .lan_ip, (.lan_cidr // ""), (.node_id // "")]
        | @tsv
    ' 2>/dev/null | while IFS=\$'\\t' read -r assigned lan_ip lan_cidr node_id; do
        assigned="\${assigned%%/*}"
        [[ -n "\$assigned" && -n "\$lan_ip" && "\$assigned" != "\$lan_ip" ]] || continue
        is_ipv4_addr "\$assigned" && is_ipv4_addr "\$lan_ip" || continue

        ip addr add "\${assigned}/32" dev "\$phys_iface" 2>/dev/null || true
        command -v arping >/dev/null 2>&1 && arping -q -U -c 1 -I "\$phys_iface" "\$assigned" 2>/dev/null || true

        if [[ -n "\$host_ip" ]]; then
            nat_mode="snat"
        else
            nat_mode="masq"
        fi

        iptables -C FORWARD -i "\$phys_iface" -o "\$phys_iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null \\
            || iptables -I FORWARD 1 -i "\$phys_iface" -o "\$phys_iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -i "\$phys_iface" -o "\$phys_iface" -s "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null \\
            || iptables -I FORWARD 1 -i "\$phys_iface" -o "\$phys_iface" -s "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null || true
        iptables -t nat -C PREROUTING -i "\$phys_iface" -d "\${assigned}/32" -m comment --comment "wg0 lan publish" -j DNAT --to-destination "\$lan_ip" 2>/dev/null \\
            || iptables -t nat -I PREROUTING 1 -i "\$phys_iface" -d "\${assigned}/32" -m comment --comment "wg0 lan publish" -j DNAT --to-destination "\$lan_ip" 2>/dev/null || true
        if [[ "\$nat_mode" == "snat" ]]; then
            iptables -t nat -C POSTROUTING -o "\$phys_iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j SNAT --to-source "\$host_ip" 2>/dev/null \\
                || iptables -t nat -I POSTROUTING 1 -o "\$phys_iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j SNAT --to-source "\$host_ip" 2>/dev/null || true
        else
            iptables -t nat -C POSTROUTING -o "\$phys_iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j MASQUERADE 2>/dev/null \\
                || iptables -t nat -I POSTROUTING 1 -o "\$phys_iface" -d "\${lan_ip}/32" -m comment --comment "wg0 lan publish" -j MASQUERADE 2>/dev/null || true
        fi
        printf '%s %s %s %s\\n' "\$phys_iface" "\$assigned" "\$lan_ip" "\${host_ip:-_}:\${nat_mode}" >> "\$desired_file"
    done

    prev_file="\$LAN_PUBLICATION_FILE"
    if [[ -f "\$prev_file" ]]; then
        while read -r iface assigned lan_ip host_state; do
            [[ -z "\$iface" || -z "\$assigned" || -z "\$lan_ip" ]] && continue
            awk -v i="\$iface" -v a="\$assigned" -v l="\$lan_ip" '\$1 == i && \$2 == a && \$3 == l { found = 1 } END { exit found ? 0 : 1 }' "\$desired_file" 2>/dev/null && continue
            host_ip="\${host_state%:*}"
            [[ "\$host_ip" == "_" ]] && host_ip=""
            nat_mode="\${host_state##*:}"
            remove_lan_publication_mapping "\$iface" "\$assigned" "\$lan_ip" "\$host_ip" "\$nat_mode"
        done < "\$prev_file"
    fi
    mv -f "\$desired_file" "\$prev_file" 2>/dev/null || true
}

echo "\$RESPONSE" | jq -c '.probe_peers // []' > "${KEY_DIR}/probe_peers" 2>/dev/null || true
reconcile_iface_routes "${WG_IFACE}" "${KEY_DIR}" "\$RESPONSE" "\$OVERLAY_IP" primary
reconcile_host_source_nat_from_response "\$RESPONSE"
reconcile_lan_publications_from_response "\$RESPONSE"

# ── Multi-membership heartbeat pass (attached networks wg1+) ─────────────────
# Attached memberships share the primary's device_secret (same hash on
# the brain side). Each attached iface gets its OWN heartbeat AND its
# own route reconcile via reconcile_iface_routes — previously this
# loop reported bytes only and discarded the response, which left
# attached-membership peers' routes uninstalled. Host-mode state
# machines (route-all, same-LAN, BYO exit) stay primary-only.
ATTACHED_CAPABILITIES_JSON=\$(current_capabilities_json)
shopt -s nullglob
for att_dir in /etc/wireguard/wg* ; do
    [[ -d "\$att_dir" ]] || continue
    att_iface=\$(basename "\$att_dir")
    [[ "\$att_iface" == "${WG_IFACE}" ]] && continue
    att_node_id=\$(cat "\$att_dir/node_id" 2>/dev/null || true)
    att_brain=\$(cat "\$att_dir/brain_url" 2>/dev/null || true)
    att_overlay=\$(cat "\$att_dir/overlay_ip" 2>/dev/null | tr -d '[:space:]' || true)
    [[ -z "\$att_node_id" || -z "\$att_brain" ]] && continue
    ip link show "\$att_iface" >/dev/null 2>&1 || continue
    att_transfer=\$(wg show "\$att_iface" transfer 2>/dev/null)
    att_tx=\$(echo "\$att_transfer" | awk '{sum += \$3} END {print sum+0}')
    att_rx=\$(echo "\$att_transfer" | awk '{sum += \$2} END {print sum+0}')
    att_lan_presence=\$(detect_lan_presence_json)
    att_payload=\$(jq -cn \\
        --argjson tx_bytes "\$att_tx" \\
        --argjson rx_bytes "\$att_rx" \\
        --argjson installation_id "\$INSTALLATION_ID_JSON" \\
        --argjson capabilities "\$ATTACHED_CAPABILITIES_JSON" \\
        --argjson lan_presence "\$att_lan_presence" \\
        --arg connector_version "${CONNECTOR_VERSION}" \\
        '{tx_bytes:\$tx_bytes, rx_bytes:\$rx_bytes, installation_id:\$installation_id, capabilities:\$capabilities, lan_presence:\$lan_presence, connector_version:\$connector_version}')
    ATT_HEADERS=( -H "Content-Type: application/json" )
    [[ -n "\$DEVICE_SECRET" ]] && ATT_HEADERS+=( -H "X-Device-Secret: \$DEVICE_SECRET" )
    att_response=\$(curl -sf -X POST "\${ATT_HEADERS[@]}" \\
        -d "\$att_payload" \\
        "\${att_brain%/}/api/v1/nodes/\${att_node_id}/heartbeat" 2>/dev/null) || continue
    [[ -z "\$att_response" ]] && continue
    reconcile_iface_routes "\$att_iface" "\$att_dir" "\$att_response" "\$att_overlay" attached
done
HBSCRIPT
    chmod +x "$HEARTBEAT_SCRIPT"
}

# ── Subcommand dispatch ───────────────────────────────────────────────────────
SUBCMD="${1:-}"

# Multi-membership subcommands (M2 roadmap, 2026-04-20). See
# docs/CONNECTOR_MULTINETWORK_ROADMAP.md for the protocol; the brain
# requires the device to have advertised `multi_membership_v1` in a
# heartbeat before POST /api/v1/devices/:id/memberships will succeed.
KNOWN_SUBCMDS=( enroll unenroll update rotate-secret check attach detach list-networks )

is_known_subcmd() {
    local candidate="$1"
    local known
    for known in "${KNOWN_SUBCMDS[@]}"; do
        [[ "$candidate" == "$known" ]] && return 0
    done
    return 1
}

# Detect legacy positional form: first arg looks like a token (not a keyword)
if ! is_known_subcmd "$SUBCMD"; then
    # Treat entire invocation as "enroll TOKEN BRAIN_URL ..."
    SUBCMD="enroll"
    TOKEN="${1:-}"
    BRAIN_URL="${2:-}"
    NODE_NAME="${3:-$(hostname)}"
    OS_TYPE="${4:-linux}"
    ROLE="${5:-client}"
    ADVERTISED_ROUTES_CSV="${6:-}"
else
    shift  # consume subcommand token
    if [[ "$SUBCMD" == "unenroll" ]]; then
        BRAIN_URL="${1:-}"
        # Auto-detect brain URL from stored file if not given
        if [[ -z "$BRAIN_URL" ]]; then
            for d in /etc/wireguard/wg0 /etc/wireguard/abslink; do
                [[ -f "$d/brain_url" ]] && BRAIN_URL=$(cat "$d/brain_url") && break
            done
        fi
        [[ -n "$BRAIN_URL" ]] || { echo "Usage: $0 unenroll [BRAIN_URL]"; exit 1; }
    elif [[ "$SUBCMD" == "update" ]]; then
        BRAIN_URL="${1:-}"
        [[ -n "$BRAIN_URL" ]] || { echo "Usage: $0 update <NEW_BRAIN_URL>"; exit 1; }
    elif [[ "$SUBCMD" == "rotate-secret" ]]; then
        BRAIN_URL="${1:-}"
        if [[ -z "$BRAIN_URL" ]]; then
            for d in /etc/wireguard/wg0 /etc/wireguard/abslink; do
                [[ -f "$d/brain_url" ]] && BRAIN_URL=$(cat "$d/brain_url") && break
            done
        fi
        [[ -n "$BRAIN_URL" ]] || { echo "Usage: $0 rotate-secret [BRAIN_URL]"; exit 1; }
    elif [[ "$SUBCMD" == "check" || "$SUBCMD" == "list-networks" ]]; then
        :  # no args needed
    elif [[ "$SUBCMD" == "attach" ]]; then
        ATTACH_NETWORK_ID="${1:-}"
        ATTACH_PAT="${2:-}"
        ATTACH_BRAIN_URL="${3:-}"
        ATTACH_ROLE="${4:-client}"
        ATTACH_NODE_NAME="${5:-$(hostname)}"
        ATTACH_ROUTES_CSV="${6:-}"
        [[ -n "$ATTACH_NETWORK_ID" && -n "$ATTACH_PAT" ]] \
            || { echo "Usage: $0 attach <NETWORK_ID> <PAT> [BRAIN_URL] [ROLE] [NAME] [ROUTES_CSV]"; exit 1; }
    elif [[ "$SUBCMD" == "detach" ]]; then
        DETACH_TARGET="${1:-}"
        DETACH_PAT="${2:-}"
        [[ -n "$DETACH_TARGET" && -n "$DETACH_PAT" ]] \
            || { echo "Usage: $0 detach <INTERFACE|NODE_ID|NETWORK_ID> <PAT>"; exit 1; }
    else
        # enroll subcommand
        TOKEN="${1:-}"
        BRAIN_URL="${2:-}"
        NODE_NAME="${3:-$(hostname)}"
        OS_TYPE="${4:-linux}"
        ROLE="${5:-client}"
        ADVERTISED_ROUTES_CSV="${6:-}"
    fi
fi

# ── CHECK ─────────────────────────────────────────────────────────────────────
# Diagnose common routing / forwarding misconfigurations for a host node.
# Reports PASS / FAIL for each check and prints a fix hint when it fails.
if [[ "$SUBCMD" == "check" ]]; then
    [[ -f "$NODE_ID_FILE" ]] || die "Not enrolled. Run '$0 enroll ...' first."

    ok_count=0
    fail_count=0
    pass() { echo "  [OK]   $*"; ok_count=$((ok_count + 1)); }
    fail() { echo "  [FAIL] $*"; fail_count=$((fail_count + 1)); }

    echo ""
    echo "wg0 host connectivity check"
    echo "─────────────────────────────────────────"

    # Tunnel up
    if ip link show "$WG_IFACE" >/dev/null 2>&1 && ip link show "$WG_IFACE" | grep -q "UP"; then
        pass "WireGuard interface ${WG_IFACE} is up"
    else
        fail "WireGuard interface ${WG_IFACE} is down. Run: wg-quick up ${WG_CONF}"
    fi

    # If we stored a phys_iface during enroll, use it; otherwise detect.
    phys=""
    [[ -f "${KEY_DIR}/phys_iface" ]] && phys=$(cat "${KEY_DIR}/phys_iface")
    [[ -z "$phys" ]] && phys=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')

    if [[ -n "$phys" ]]; then
        pass "Physical LAN interface: ${phys}"
    else
        fail "No physical LAN interface detected (no default route)."
    fi

    # ip_forward
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]]; then
        pass "IP forwarding enabled"
    else
        fail "IP forwarding DISABLED. Fix: sysctl -w net.ipv4.ip_forward=1"
    fi

    # rp_filter on wg0 + phys + all (must be 0 to allow forwarding)
    for iface in all "$WG_IFACE" "$phys"; do
        [[ -z "$iface" ]] && continue
        rpf=$(cat "/proc/sys/net/ipv4/conf/${iface}/rp_filter" 2>/dev/null || echo -1)
        if [[ "$rpf" == "0" ]]; then
            pass "rp_filter on ${iface} = 0 (permissive)"
        else
            fail "rp_filter on ${iface} = ${rpf}. Fix: sysctl -w net.ipv4.conf.${iface}.rp_filter=0"
        fi
    done

    # proxy_arp on wg0 (informational)
    pa=$(cat "/proc/sys/net/ipv4/conf/${WG_IFACE}/proxy_arp" 2>/dev/null || echo -1)
    if [[ "$pa" == "1" ]]; then
        pass "proxy_arp on ${WG_IFACE} = 1"
    else
        fail "proxy_arp on ${WG_IFACE} = ${pa}. Fix: echo 1 > /proc/sys/net/ipv4/conf/${WG_IFACE}/proxy_arp"
    fi

    # proxy_arp MUST NOT be on "all" (poisons the LAN)
    pa_all=$(cat /proc/sys/net/ipv4/conf/all/proxy_arp 2>/dev/null || echo 0)
    if [[ "$pa_all" == "0" ]]; then
        pass "proxy_arp on all = 0 (correct — does not poison LAN)"
    else
        fail "proxy_arp on all = 1. CRITICAL: this poisons the LAN. Fix: echo 0 > /proc/sys/net/ipv4/conf/all/proxy_arp"
    fi

    # iptables FORWARD rules for host role
    if [[ -n "$phys" ]]; then
        if iptables -C FORWARD -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; then
            pass "iptables FORWARD rule ${WG_IFACE} -> ${WG_IFACE} present (remote clients can hairpin through host)"
        else
            fail "Missing FORWARD rule ${WG_IFACE} -> ${WG_IFACE}. Fix: iptables -I FORWARD 1 -i ${WG_IFACE} -o ${WG_IFACE} -j ACCEPT"
        fi
        if iptables -C FORWARD -i "$WG_IFACE" -o "$phys" -j ACCEPT 2>/dev/null; then
            pass "iptables FORWARD rule ${WG_IFACE} -> ${phys} present"
        else
            fail "Missing FORWARD rule ${WG_IFACE} -> ${phys}. Fix: iptables -I FORWARD 1 -i ${WG_IFACE} -o ${phys} -j ACCEPT"
        fi
        if iptables -C FORWARD -i "$phys" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; then
            pass "iptables FORWARD rule ${phys} -> ${WG_IFACE} present"
        else
            fail "Missing FORWARD rule ${phys} -> ${WG_IFACE}. Fix: iptables -I FORWARD 1 -i ${phys} -o ${WG_IFACE} -j ACCEPT"
        fi

        # NAT MASQUERADE for each advertised route
        if [[ -f "${KEY_DIR}/overlay_ip" ]]; then
            # Check if at least one MASQUERADE rule exists for this physical iface
            if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-o ${phys}.*MASQUERADE"; then
                pass "NAT MASQUERADE rule present on ${phys}"
            else
                fail "No NAT MASQUERADE rule on ${phys}. Remote clients will not reach the LAN. Re-run: $0 enroll ..."
            fi
        fi

        # FORWARD policy warning
        fwd_policy=$(iptables -S FORWARD 2>/dev/null | head -1 | awk '{print $NF}')
        if [[ "$fwd_policy" == "DROP" ]]; then
            echo "  [WARN] FORWARD chain policy is DROP (usually Docker). Explicit ACCEPT rules above should handle it."
        fi
    fi

    echo "─────────────────────────────────────────"
    echo "  ${ok_count} passed, ${fail_count} failed"
    echo ""
    [[ $fail_count -eq 0 ]] && exit 0 || exit 1
fi

# ── ROTATE-SECRET ─────────────────────────────────────────────────────────────
# Device protocol v2: generate a new per-device secret, atomically overwrite
# the local file. Uses the current secret to authenticate the POST — for
# pre-v2 rows that don't have a secret file, the brain's grace-path accepts
# the unauthenticated call, generates the first hash, and transitions the
# row to strict auth going forward.
if [[ "$SUBCMD" == "rotate-secret" ]]; then
    BRAIN_URL="${BRAIN_URL%/}"
    [[ -f "$NODE_ID_FILE" ]] || die "No node_id found. This system does not appear to be enrolled."
    NODE_ID=$(cat "$NODE_ID_FILE")
    log "Rotating device secret for node ${NODE_ID} at ${BRAIN_URL}"

    CUR_SECRET=$(cat "$DEVICE_SECRET_FILE" 2>/dev/null || true)
    ROTATE_ARGS=( -sf -X POST -H "Content-Type: application/json" )
    [[ -n "$CUR_SECRET" ]] && ROTATE_ARGS+=( -H "X-Device-Secret: $CUR_SECRET" )
    RESP=$(curl "${ROTATE_ARGS[@]}" "${BRAIN_URL}/api/v1/nodes/${NODE_ID}/rotate-secret" -d '{}' 2>/dev/null || true)
    if [[ -z "$RESP" ]]; then
        warn "rotate-secret with current secret failed; retrying legacy recovery path"
        RESP=$(curl -sf -X POST -H "Content-Type: application/json" \
            "${BRAIN_URL}/api/v1/nodes/${NODE_ID}/rotate-secret" -d '{}' 2>/dev/null) \
            || die "rotate-secret request failed — brain unreachable or recovery path rejected."
    fi

    NEW_SECRET=$(echo "$RESP" | jq -r '.device_secret // empty')
    [[ -n "$NEW_SECRET" ]] || die "Brain returned no device_secret in rotate response: $RESP"

    # Atomic overwrite so a crash mid-rotate doesn't brick the node.
    TMP_SECRET=$(mktemp -p "$KEY_DIR" .device_secret.XXXXXX)
    printf '%s' "$NEW_SECRET" > "$TMP_SECRET"
    chmod 600 "$TMP_SECRET"
    mv -f "$TMP_SECRET" "$DEVICE_SECRET_FILE"

    log "Device secret rotated successfully. Future heartbeats will use the new secret."
    exit 0
fi

# ── LIST-NETWORKS ─────────────────────────────────────────────────────────────
# Show every active membership this installation holds. Reads each
# /etc/wireguard/<iface>/node_id file — primary wg0 plus any wgN added
# via `attach`.
if [[ "$SUBCMD" == "list-networks" ]]; then
    printf '%-10s %-38s %-20s %s\n' "IFACE" "NODE_ID" "OVERLAY_IP" "BRAIN_URL"
    printf '%-10s %-38s %-20s %s\n' "-----" "-------" "----------" "---------"
    shopt -s nullglob
    for dir in /etc/wireguard/wg* ; do
        [[ -d "$dir" ]] || continue
        iface=$(basename "$dir")
        nid=$(cat "${dir}/node_id" 2>/dev/null || true)
        oip=$(cat "${dir}/overlay_ip" 2>/dev/null || true)
        burl=$(cat "${dir}/brain_url" 2>/dev/null || true)
        [[ -z "$nid" ]] && continue
        printf '%-10s %-38s %-20s %s\n' "$iface" "${nid:-?}" "${oip:--}" "${burl:--}"
    done
    exit 0
fi

# ── ATTACH ────────────────────────────────────────────────────────────────────
# Attach this installation to an ADDITIONAL network as a second (or Nth)
# membership. The primary wg0 stays untouched. Requires:
#   - a user PAT (creates the attach request on behalf of the owner)
#   - the primary wg0 installation already enrolled (so we have a
#     device_id + device_secret to self-fulfill with)
#
# Flow (see docs/MULTI_NETWORK_INSTALLATION_PLAN.md §5 and §7):
#   1. Load local device_id + device_secret + brain_url from /etc/wireguard/wg0/
#   2. POST /api/v1/devices/:device_id/memberships     (Bearer: PAT)
#        → brain writes a 'pending' device_membership_requests row
#   3. Generate a fresh keypair for the new interface
#   4. POST /api/v2/installations/:device_id/memberships/:request_id/fulfill
#        (X-Device-Secret + Wg0-Protocol-Version: 2)
#        → returns node_id + overlay_ip + wg_config
#   5. Write /etc/wireguard/<iface>.conf with the returned config
#   6. wg-quick up <iface>  (systemd enables wg-quick@<iface> for survivability)
if [[ "$SUBCMD" == "attach" ]]; then
    [[ -f "$DEVICE_ID_FILE" ]] \
        || die "Primary wg0 isn't enrolled yet. Run '$0 enroll ...' first before attaching additional networks."
    DEVICE_ID=$(cat "$DEVICE_ID_FILE")
    DEVICE_SECRET=$(cat "$DEVICE_SECRET_FILE" 2>/dev/null || true)
    [[ -n "$DEVICE_SECRET" ]] || die "Missing device_secret at $DEVICE_SECRET_FILE — run '$0 rotate-secret' first."

    # Brain URL: argument wins, else whatever wg0 uses.
    if [[ -z "$ATTACH_BRAIN_URL" ]]; then
        ATTACH_BRAIN_URL=$(cat /etc/wireguard/wg0/brain_url 2>/dev/null || true)
    fi
    [[ -n "$ATTACH_BRAIN_URL" ]] || die "Could not determine brain URL. Pass it as the third positional argument."
    ATTACH_BRAIN_URL="${ATTACH_BRAIN_URL%/}"

    # Overlap guard (C bundle 2026-04-24): refuse to attach if any of
    # the advertised routes overlap with an existing tunnel iface's
    # installed_routes OR with a non-tunnel physical interface's live
    # subnets. Brain's preflight_device_attach can also catch this but
    # a local refusal with a clear message is faster for the user.
    if [[ -n "${ATTACH_ROUTES_CSV:-}" ]]; then
        collect_existing_tunnel_cidrs() {
            shopt -s nullglob
            for d in /etc/wireguard/wg* ; do
                [[ -d "$d" ]] || continue
                [[ -f "$d/installed_routes" ]] || continue
                cat "$d/installed_routes" 2>/dev/null
            done
        }
        collect_physical_iface_subnets() {
            ip -4 -o route show 2>/dev/null | awk '
                {
                    dev = ""
                    for (i=1; i<=NF; i++) if ($i == "dev") dev = $(i+1)
                    if (dev == "") next
                    if (dev ~ /^(wg|lo)/) next
                    print $1
                }
            '
        }
        existing_tun=$(collect_existing_tunnel_cidrs | sort -u)
        existing_phys=$(collect_physical_iface_subnets | sort -u)
        IFS=',' read -r -a _want <<< "$ATTACH_ROUTES_CSV"
        for _w in "${_want[@]}"; do
            _w=$(echo "$_w" | xargs)
            [[ -z "$_w" ]] && continue
            if echo "$existing_tun" | grep -qxF "$_w"; then
                die "attach refused: $_w already routed by an attached wgN. Detach it first or choose a non-overlapping subnet."
            fi
            if echo "$existing_phys" | grep -qxF "$_w"; then
                die "attach refused: $_w is already owned by a physical interface. Picking this subnet would hijack LAN traffic — choose a different overlay subnet."
            fi
        done
    fi

    # Pick the next free wg<N> interface name.
    next_iface=""
    for n in {1..63}; do
        candidate="wg${n}"
        if [[ ! -e "/etc/wireguard/${candidate}.conf" && ! -d "/etc/wireguard/${candidate}" ]]; then
            next_iface="$candidate"
            break
        fi
    done
    [[ -n "$next_iface" ]] || die "No free wg interface names between wg1 and wg63 — detach something first."
    ATTACH_DIR="/etc/wireguard/${next_iface}"
    mkdir -p "$ATTACH_DIR"
    chmod 700 "$ATTACH_DIR"

    log "Attaching network ${ATTACH_NETWORK_ID} on ${next_iface} (brain=${ATTACH_BRAIN_URL})..."

    # Fresh keypair for this interface (don't reuse wg0's keys).
    wg genkey | tee "${ATTACH_DIR}/private.key" | wg pubkey > "${ATTACH_DIR}/public.key"
    chmod 600 "${ATTACH_DIR}/private.key"
    ATTACH_PRIV=$(cat "${ATTACH_DIR}/private.key")
    ATTACH_PUB=$(cat "${ATTACH_DIR}/public.key")

    # Step 1: create the membership request.
    REQ_BODY=$(jq -cn \
        --arg network_id "$ATTACH_NETWORK_ID" \
        --arg desired_role "$ATTACH_ROLE" \
        --arg desired_name "$ATTACH_NODE_NAME" \
        '{network_id:$network_id, desired_role:$desired_role, desired_name:$desired_name}')
    CREATE_RESP=$(curl -sf -X POST \
        -H "Authorization: Bearer ${ATTACH_PAT}" \
        -H "Content-Type: application/json" \
        -d "$REQ_BODY" \
        "${ATTACH_BRAIN_URL}/api/v1/devices/${DEVICE_ID}/memberships") \
        || { rm -rf "$ATTACH_DIR"; die "Attach request failed. Check PAT + NETWORK_ID + that the brain sees this device advertising multi_membership_v1."; }

    # The endpoint returns the whole device, including pending_membership_requests[].
    # Find the one for our network_id with status=pending.
    REQ_ID=$(echo "$CREATE_RESP" | jq -r --arg nid "$ATTACH_NETWORK_ID" '
        (.pending_membership_requests // [])
        | map(select(.network_id == $nid and .status == "pending"))
        | sort_by(.created_at) | last | .id // empty')
    [[ -n "$REQ_ID" ]] || { rm -rf "$ATTACH_DIR"; die "Brain did not return a pending membership request id: $CREATE_RESP"; }

    # Step 2: fulfill as the device.
    ATTACH_PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    ATTACH_ENDPOINT=""
    [[ -n "$ATTACH_PUBLIC_IP" ]] && ATTACH_ENDPOINT="${ATTACH_PUBLIC_IP}:51820"
    if [[ -n "$ATTACH_ROUTES_CSV" ]]; then
        ATTACH_ROUTES_JSON=$(echo "$ATTACH_ROUTES_CSV" | jq -R 'split(",") | map(select(length > 0) | gsub("^ +| +$"; ""))')
    else
        ATTACH_ROUTES_JSON="[]"
    fi
    FULFILL_BODY=$(jq -cn \
        --arg public_key "$ATTACH_PUB" \
        --arg node_name "$ATTACH_NODE_NAME" \
        --arg os_type "linux" \
        --arg endpoint "$ATTACH_ENDPOINT" \
        --argjson advertised_routes "$ATTACH_ROUTES_JSON" \
        '{public_key:$public_key, node_name:$node_name, os_type:$os_type, endpoint:($endpoint|select(length>0)), advertised_routes:$advertised_routes}')

    FULFILL_RESP=$(curl -sf -X POST \
        -H "X-Device-Secret: ${DEVICE_SECRET}" \
        -H "Wg0-Protocol-Version: 2" \
        -H "Content-Type: application/json" \
        -d "$FULFILL_BODY" \
        "${ATTACH_BRAIN_URL}/api/v2/installations/${DEVICE_ID}/memberships/${REQ_ID}/fulfill") \
        || { rm -rf "$ATTACH_DIR"; die "Fulfillment failed. The pending request still exists brain-side — retry or delete it from the dashboard."; }

    ATTACH_NODE_ID=$(echo "$FULFILL_RESP" | jq -r '.node_id')
    ATTACH_OVERLAY=$(echo "$FULFILL_RESP" | jq -r '.overlay_ip')
    ATTACH_WG_CONFIG=$(echo "$FULFILL_RESP" | jq -r '.wg_config')
    [[ -n "$ATTACH_NODE_ID" && "$ATTACH_NODE_ID" != "null" ]] \
        || { rm -rf "$ATTACH_DIR"; die "Fulfillment response missing node_id: $FULFILL_RESP"; }

    # Persist per-membership state.
    echo "$ATTACH_NODE_ID"     > "${ATTACH_DIR}/node_id";     chmod 600 "${ATTACH_DIR}/node_id"
    echo "$ATTACH_NETWORK_ID"  > "${ATTACH_DIR}/network_id";  chmod 600 "${ATTACH_DIR}/network_id"
    echo "$ATTACH_BRAIN_URL"   > "${ATTACH_DIR}/brain_url";   chmod 600 "${ATTACH_DIR}/brain_url"
    echo "${ATTACH_OVERLAY%/*}" > "${ATTACH_DIR}/overlay_ip"; chmod 600 "${ATTACH_DIR}/overlay_ip"

    # Write the wg-quick conf with the local private key substituted in.
    ATTACH_CONF="/etc/wireguard/${next_iface}.conf"
    echo "$ATTACH_WG_CONFIG" \
        | sed "s|# PrivateKey = <CONNECTOR_FILLS_THIS_IN>|PrivateKey = ${ATTACH_PRIV}|" \
        > "$ATTACH_CONF"
    chmod 600 "$ATTACH_CONF"

    # Bring the tunnel up. Use systemd wg-quick@ for restart-survivability
    # when available; fall back to one-shot wg-quick up for non-systemd hosts.
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^wg-quick@.service'; then
        systemctl enable --now "wg-quick@${next_iface}" || warn "systemctl enable wg-quick@${next_iface} failed — falling back to wg-quick up"
    fi
    if ! ip link show "${next_iface}" >/dev/null 2>&1; then
        wg-quick up "$ATTACH_CONF" || die "wg-quick up ${ATTACH_CONF} failed."
    fi

    log "Attached! ${next_iface} → ${ATTACH_OVERLAY} (node_id=${ATTACH_NODE_ID})"
    log "The wg0-heartbeat timer will start reporting for ${next_iface} on its next tick (~30s)."
    exit 0
fi

# ── DETACH ────────────────────────────────────────────────────────────────────
# Remove one attached membership (wg1, wg2, ...). The primary wg0 stays.
# To detach wg0 use `unenroll` instead — it tears down the full installation.
if [[ "$SUBCMD" == "detach" ]]; then
    # DETACH_TARGET may be an interface name (wg1), a node_id (uuid), or a network_id (uuid).
    det_iface=""
    if [[ -d "/etc/wireguard/${DETACH_TARGET}" ]]; then
        det_iface="$DETACH_TARGET"
    else
        # Scan for matching node_id or network_id.
        shopt -s nullglob
        for dir in /etc/wireguard/wg* ; do
            [[ -d "$dir" ]] || continue
            it=$(basename "$dir")
            [[ "$it" == "wg0" ]] && continue  # wg0 is managed via unenroll
            if [[ "$(cat "${dir}/node_id" 2>/dev/null || true)" == "$DETACH_TARGET" ]] \
                || [[ "$(cat "${dir}/network_id" 2>/dev/null || true)" == "$DETACH_TARGET" ]]; then
                det_iface="$it"
                break
            fi
        done
    fi
    [[ -n "$det_iface" ]] || die "Could not resolve '${DETACH_TARGET}' to an attached membership. Run '$0 list-networks' to inspect state."
    [[ "$det_iface" == "wg0" ]] && die "wg0 is the primary installation. Use '$0 unenroll' to remove it."

    det_dir="/etc/wireguard/${det_iface}"
    det_node_id=$(cat "${det_dir}/node_id" 2>/dev/null || true)
    det_brain=$(cat "${det_dir}/brain_url" 2>/dev/null || cat /etc/wireguard/wg0/brain_url 2>/dev/null || true)
    det_device_id=$(cat "$DEVICE_ID_FILE" 2>/dev/null || true)

    # Brain-side delete (best effort).
    if [[ -n "$det_node_id" && -n "$det_brain" && -n "$det_device_id" ]]; then
        curl -sf -X DELETE \
            -H "Authorization: Bearer ${DETACH_PAT}" \
            "${det_brain%/}/api/v1/devices/${det_device_id}/memberships/${det_node_id}" \
            >/dev/null 2>&1 || warn "Brain-side detach failed; continuing with local teardown."
    fi

    # Explicit route flush BEFORE wg-quick down (C bundle 2026-04-24).
    # wg-quick down is supposed to clean up routes scoped to the
    # interface, but any failure (missing in PATH, already-down link,
    # stray route from a prior incarnation) would orphan them. Union
    # the tracked installed_routes with a kernel scan of routes
    # currently pointed at the iface, and delete each with an
    # iface-scoped ip route del. Safe no-op if wg-quick cleans up too.
    det_tracked_routes=""
    [[ -f "${det_dir}/installed_routes" ]] && det_tracked_routes=$(cat "${det_dir}/installed_routes")
    det_kernel_routes=""
    if ip link show "${det_iface}" >/dev/null 2>&1; then
        det_kernel_routes=$(ip -4 -o route show dev "${det_iface}" 2>/dev/null | awk '{print $1}' | sort -u)
    fi
    {
        echo "$det_tracked_routes"
        echo "$det_kernel_routes"
    } | sort -u | while read -r _cidr; do
        [[ -z "$_cidr" ]] && continue
        ip route del "$_cidr" dev "${det_iface}" 2>/dev/null || true
    done

    # Local teardown.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "wg-quick@${det_iface}" 2>/dev/null || true
    fi
    if ip link show "${det_iface}" >/dev/null 2>&1; then
        wg-quick down "/etc/wireguard/${det_iface}.conf" 2>/dev/null || true
    fi
    rm -f "/etc/wireguard/${det_iface}.conf"
    rm -rf "${det_dir}"

    log "Detached ${det_iface} (node_id=${det_node_id:-unknown})."
    exit 0
fi

# ── UPDATE ────────────────────────────────────────────────────────────────────
if [[ "$SUBCMD" == "update" ]]; then
    BRAIN_URL="${BRAIN_URL%/}"
    log "wg0 update — migrating to brain at ${BRAIN_URL}"

    # Detect current key dir (legacy or new)
    if [[ -d /etc/wireguard/abslink && ! -d /etc/wireguard/wg0 ]]; then
        log "Migrating key directory: /etc/wireguard/abslink → ${KEY_DIR}"
        mv /etc/wireguard/abslink "$KEY_DIR"
    fi

    NODE_ID_FILE="${KEY_DIR}/node_id"
    [[ -f "$NODE_ID_FILE" ]] || die "No node_id found. This system does not appear to be enrolled."
    NODE_ID=$(cat "$NODE_ID_FILE")
    log "Node ID: ${NODE_ID}"

    # Store brain URL
    echo "$BRAIN_URL" > "${KEY_DIR}/brain_url"
    chmod 600 "${KEY_DIR}/brain_url"

    # Propagate the new brain URL to any attached memberships too, so
    # `update` rehomes the whole installation (primary + attached)
    # atomically. Each attached dir (wg1/, wg2/, ...) keeps its own
    # brain_url file for the attached-heartbeat loop.
    shopt -s nullglob
    for att_dir in /etc/wireguard/wg* ; do
        [[ -d "$att_dir" ]] || continue
        [[ "$(basename "$att_dir")" == "${WG_IFACE}" ]] && continue
        [[ -f "$att_dir/brain_url" ]] || continue
        echo "$BRAIN_URL" > "$att_dir/brain_url"
        chmod 600 "$att_dir/brain_url"
    done

    # Recover persisted connector settings so the regenerated heartbeat keeps
    # the correct host/client role and advertised route set. Older installs
    # may not have the state files yet, so fall back to parsing the existing
    # generated heartbeat script.
    load_connector_state
    persist_connector_state
    log "Recovered connector state: role=${ROLE} advertised_routes=${ADVERTISED_ROUTES_CSV:-<none>}"

    # Remove legacy heartbeat script (we'll write a fresh one below)
    rm -f /usr/local/bin/abslink-heartbeat

    # Rewrite heartbeat script from current template — handles brain URL,
    # route logic, TX/RX reporting, all in one shot. No fragile sed patches.
    write_heartbeat_script
    log "Rewrote heartbeat script with latest template (brain=${BRAIN_URL})"

    if [[ "${ROLE}" == "host" && -n "${ADVERTISED_ROUTES_CSV:-}" ]]; then
        reapply_native_lan_host_forwarding_update
        log "Reapplied native-LAN host forwarding rules"
    fi

    # Migrate systemd unit names if needed
    if [[ -f /etc/systemd/system/abslink-heartbeat.timer ]]; then
        log "Migrating systemd units: abslink-heartbeat → wg0-heartbeat"
        systemctl disable --now abslink-heartbeat.timer 2>/dev/null || true
        # Rewrite with new name
        sed 's|abslink-heartbeat|wg0-heartbeat|g; s|abslink|wg0|g' \
            /etc/systemd/system/abslink-heartbeat.service > /etc/systemd/system/wg0-heartbeat.service
        sed 's|abslink-heartbeat|wg0-heartbeat|g; s|abslink|wg0|g' \
            /etc/systemd/system/abslink-heartbeat.timer > /etc/systemd/system/wg0-heartbeat.timer
        rm -f /etc/systemd/system/abslink-heartbeat.service /etc/systemd/system/abslink-heartbeat.timer
        systemctl daemon-reload
        systemctl enable --now wg0-heartbeat.timer
        log "Systemd units migrated and started"
    elif [[ -f /etc/systemd/system/wg0-heartbeat.timer ]]; then
        systemctl restart wg0-heartbeat.timer 2>/dev/null || true
        log "Heartbeat timer restarted"
    fi

    # Idempotently install/refresh the main heartbeat unit (pick up
    # new TimeoutStartSec + log redirection) and the heartbeat
    # watchdog. `enroll` writes both; `update` on an existing install
    # without the watchdog didn't — so add it here so the -b upgrade
    # converges cleanly.
    if command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
        cat > /etc/systemd/system/wg0-heartbeat.service <<EOF
[Unit]
Description=wg0 Heartbeat

[Service]
Type=oneshot
ExecStart=${HEARTBEAT_SCRIPT}
ExecStartPost=/bin/sh -c 'touch /var/log/wg0-heartbeat.log'
TimeoutStartSec=60
StandardOutput=append:/var/log/wg0-heartbeat.log
StandardError=append:/var/log/wg0-heartbeat.log
EOF

        cat > /etc/systemd/system/wg0-heartbeat-watchdog.service <<'EOF'
[Unit]
Description=wg0 Heartbeat Watchdog

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'LOG=/var/log/wg0-heartbeat.log; STALE=120; if [ ! -f "$LOG" ] || [ $(( $(date +%s) - $(stat -c %Y "$LOG" 2>/dev/null || echo 0) )) -gt "$STALE" ]; then systemctl start wg0-heartbeat.service; echo "[$(date -u +%H:%M:%SZ)] watchdog: kicked heartbeat (stale >${STALE}s)" >> /var/log/wg0-heartbeat-watchdog.log; fi'
TimeoutStartSec=30
EOF

        cat > /etc/systemd/system/wg0-heartbeat-watchdog.timer <<'EOF'
[Unit]
Description=wg0 Heartbeat Watchdog Timer

[Timer]
OnBootSec=120s
OnUnitActiveSec=120s

[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload
        systemctl enable --now wg0-heartbeat-watchdog.timer >/dev/null 2>&1 || true
        log "Heartbeat watchdog installed/refreshed"
    fi

    # Install/update wg0 CLI
    if curl -fsSL "https://wg0.io/wg0-status.sh" -o /usr/local/bin/wg0 2>/dev/null; then
        chmod +x /usr/local/bin/wg0
        log "Updated wg0 CLI tool"
    fi
    rm -f /usr/local/bin/abslink 2>/dev/null || true

    # Test heartbeat
    log "Running heartbeat to verify connectivity..."
    if WG0_HEARTBEAT_STRICT=1 bash "$HEARTBEAT_SCRIPT" 2>/dev/null; then
        log "Heartbeat succeeded — connected to ${BRAIN_URL}"
    else
        warn "Heartbeat failed — check that ${BRAIN_URL} is reachable"
    fi

    log ""
    log "Update complete."
    log "  Brain URL:  ${BRAIN_URL}"
    log "  Node ID:    ${NODE_ID}"
    log ""
    log "Run 'wg0 status' to verify tunnel health."
    exit 0
fi

# ── UNENROLL ──────────────────────────────────────────────────────────────────
if [[ "$SUBCMD" == "unenroll" ]]; then
    BRAIN_URL="${BRAIN_URL%/}"

    log "Starting unenroll from Brain at ${BRAIN_URL} ..."

    # 1. Read node_id — die if not enrolled
    if [[ ! -f "$NODE_ID_FILE" ]]; then
        die "No node_id found at ${NODE_ID_FILE}. This system does not appear to be enrolled."
    fi
    NODE_ID=$(cat "$NODE_ID_FILE")
    log "Node ID: ${NODE_ID}"

    # 2. Tell the Brain to forget this node (warn and continue if Brain unreachable).
    # Send X-Device-Secret if this node was enrolled under protocol v2;
    # older enrollments don't have a secret file and the brain's extractor
    # accepts the request without it (grace-period backward compat).
    log "Notifying Brain to remove node..."
    DEVICE_SECRET=$(cat "$DEVICE_SECRET_FILE" 2>/dev/null || true)
    UNENROLL_ARGS=( -sf -X DELETE )
    [[ -n "$DEVICE_SECRET" ]] && UNENROLL_ARGS+=( -H "X-Device-Secret: $DEVICE_SECRET" )
    if curl "${UNENROLL_ARGS[@]}" "${BRAIN_URL}/api/v1/nodes/${NODE_ID}/self" >/dev/null 2>&1; then
        log "Brain confirmed node removal."
    else
        log "WARNING: Brain request failed (Brain may be unreachable). Continuing local cleanup."
    fi

    # 3. Bring down WireGuard interface
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        log "Bringing down WireGuard interface ${WG_IFACE}..."
        wg-quick down "$WG_CONF" 2>/dev/null || wg-quick down "$WG_IFACE" 2>/dev/null || true
    else
        log "WireGuard interface ${WG_IFACE} is already down."
    fi

    # 3b. Remove host-mode iptables rules (no-op if never set).
    if [[ -f "${KEY_DIR}/phys_iface" || -f "${KEY_DIR}/wan_iface" || -f "${EGRESS_IFACES_FILE}" ]]; then
        phys=$(cat "${KEY_DIR}/phys_iface" 2>/dev/null || true)
        wan=$(cat "${KEY_DIR}/wan_iface" 2>/dev/null || true)
        mapfile -t saved_ifaces < "${EGRESS_IFACES_FILE}" 2>/dev/null || saved_ifaces=()
        log "Removing host forwarding rules for phys=${phys:-none} wan=${wan:-none} extra=$(printf '%s,' "${saved_ifaces[@]}" | sed 's/,$//')..."
        declare -A seen_ifaces=()
        for iface in "$phys" "$wan" "${saved_ifaces[@]}"; do
            [[ -z "$iface" ]] && continue
            [[ -n "${seen_ifaces[$iface]:-}" ]] && continue
            seen_ifaces["$iface"]=1
            while iptables -C FORWARD -i "$WG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null; do
                iptables -D FORWARD -i "$WG_IFACE" -o "$iface" -j ACCEPT
            done
            while iptables -C FORWARD -i "$iface" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; do
                iptables -D FORWARD -i "$iface" -o "$WG_IFACE" -j ACCEPT
            done
            if [[ -n "${ADVERTISED_ROUTES_CSV:-}" ]]; then
                IFS=',' read -ra MASQ_ROUTES <<< "$ADVERTISED_ROUTES_CSV"
                for route in "${MASQ_ROUTES[@]}"; do
                    route=$(echo "$route" | xargs)
                    [[ -z "$route" ]] && continue
                    while iptables -t nat -C POSTROUTING -s "$route" -o "$iface" -j MASQUERADE 2>/dev/null; do
                        iptables -t nat -D POSTROUTING -s "$route" -o "$iface" -j MASQUERADE
                    done
                done
            fi
        done
        while iptables -C FORWARD -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; do
            iptables -D FORWARD -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT
        done
        if [[ -f "$NAT_SOURCE_CIDRS_FILE" ]]; then
            while read -r target_iface source_cidr; do
                [[ -z "$target_iface" || -z "$source_cidr" ]] && continue
                while iptables -t nat -C POSTROUTING -s "$source_cidr" -o "$target_iface" -m comment --comment "wg0 source NAT" -j MASQUERADE 2>/dev/null; do
                    iptables -t nat -D POSTROUTING -s "$source_cidr" -o "$target_iface" -m comment --comment "wg0 source NAT" -j MASQUERADE 2>/dev/null || break
                done
            done < "$NAT_SOURCE_CIDRS_FILE"
            rm -f "$NAT_SOURCE_CIDRS_FILE" 2>/dev/null || true
        fi
        if [[ -f "$LAN_PUBLICATION_FILE" ]]; then
            while read -r pub_iface assigned_ip lan_ip host_state; do
                [[ -z "$pub_iface" || -z "$assigned_ip" || -z "$lan_ip" ]] && continue
                pub_host_ip="${host_state%:*}"
                [[ "$pub_host_ip" == "_" ]] && pub_host_ip=""
                pub_nat_mode="${host_state##*:}"
                while iptables -t nat -C PREROUTING -i "$pub_iface" -d "${assigned_ip}/32" -m comment --comment "wg0 lan publish" -j DNAT --to-destination "$lan_ip" 2>/dev/null; do
                    iptables -t nat -D PREROUTING -i "$pub_iface" -d "${assigned_ip}/32" -m comment --comment "wg0 lan publish" -j DNAT --to-destination "$lan_ip" 2>/dev/null || break
                done
                if [[ "$pub_nat_mode" == "snat" && -n "$pub_host_ip" ]]; then
                    while iptables -t nat -C POSTROUTING -o "$pub_iface" -d "${lan_ip}/32" -m comment --comment "wg0 lan publish" -j SNAT --to-source "$pub_host_ip" 2>/dev/null; do
                        iptables -t nat -D POSTROUTING -o "$pub_iface" -d "${lan_ip}/32" -m comment --comment "wg0 lan publish" -j SNAT --to-source "$pub_host_ip" 2>/dev/null || break
                    done
                else
                    while iptables -t nat -C POSTROUTING -o "$pub_iface" -d "${lan_ip}/32" -m comment --comment "wg0 lan publish" -j MASQUERADE 2>/dev/null; do
                        iptables -t nat -D POSTROUTING -o "$pub_iface" -d "${lan_ip}/32" -m comment --comment "wg0 lan publish" -j MASQUERADE 2>/dev/null || break
                    done
                fi
                while iptables -C FORWARD -i "$pub_iface" -o "$pub_iface" -d "${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null; do
                    iptables -D FORWARD -i "$pub_iface" -o "$pub_iface" -d "${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null || break
                done
                while iptables -C FORWARD -i "$pub_iface" -o "$pub_iface" -s "${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null; do
                    iptables -D FORWARD -i "$pub_iface" -o "$pub_iface" -s "${lan_ip}/32" -m comment --comment "wg0 lan publish" -j ACCEPT 2>/dev/null || break
                done
                ip addr del "${assigned_ip}/32" dev "$pub_iface" 2>/dev/null || true
            done < "$LAN_PUBLICATION_FILE"
            rm -f "$LAN_PUBLICATION_FILE" 2>/dev/null || true
        fi
    fi

    # 3c. Restore sysctl state we changed during setup_native_lan_host.
    #     If we don't have a saved snapshot (e.g. client-role unenroll),
    #     leave sysctls alone — don't assume defaults that might not be right
    #     for this host.
    if [[ -f "${KEY_DIR}/sysctl_state" ]]; then
        log "Restoring sysctl state..."
        # shellcheck disable=SC1091
        source "${KEY_DIR}/sysctl_state"
        # Restore each value only if we have a snapshot for it.
        [[ -n "${ip_forward:-}" ]] && sysctl -qw "net.ipv4.ip_forward=${ip_forward}" 2>/dev/null || true
        [[ -n "${rp_filter_all:-}" ]] && sysctl -qw "net.ipv4.conf.all.rp_filter=${rp_filter_all}" 2>/dev/null || true
        # rp_filter on wg0 — interface will be gone after wg-quick down, no-op then.
        [[ -n "${rp_filter_wg:-}" ]] && sysctl -qw "net.ipv4.conf.${WG_IFACE}.rp_filter=${rp_filter_wg}" 2>/dev/null || true
        # Restore physical interface rp_filter (use saved phys_iface var).
        if [[ -n "${phys_iface:-}" && -n "${rp_filter_phys:-}" ]]; then
            sysctl -qw "net.ipv4.conf.${phys_iface}.rp_filter=${rp_filter_phys}" 2>/dev/null || true
        fi
        if [[ -n "${wan_iface:-}" && -n "${rp_filter_wan:-}" ]]; then
            sysctl -qw "net.ipv4.conf.${wan_iface}.rp_filter=${rp_filter_wan}" 2>/dev/null || true
        fi
        log "sysctl state restored (ip_forward=${ip_forward:-?}, rp_filter.all=${rp_filter_all:-?})."
    fi

    # 4. Stop and disable systemd units
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now wg0-heartbeat-watchdog.timer 2>/dev/null || true
        systemctl disable --now wg0-heartbeat-watchdog.service 2>/dev/null || true
        systemctl disable --now wg0-heartbeat.timer  2>/dev/null || true
        systemctl disable --now wg0-heartbeat.service 2>/dev/null || true
    fi

    # 5. Remove systemd unit files and reload daemon
    if [[ -f /etc/systemd/system/wg0-heartbeat.timer || -f /etc/systemd/system/wg0-heartbeat.service \
       || -f /etc/systemd/system/wg0-heartbeat-watchdog.timer || -f /etc/systemd/system/wg0-heartbeat-watchdog.service ]]; then
        rm -f /etc/systemd/system/wg0-heartbeat.timer
        rm -f /etc/systemd/system/wg0-heartbeat.service
        rm -f /etc/systemd/system/wg0-heartbeat-watchdog.timer
        rm -f /etc/systemd/system/wg0-heartbeat-watchdog.service
        systemctl daemon-reload 2>/dev/null || true
        log "Removed systemd heartbeat units."
    fi

    # 6. Remove heartbeat script
    rm -f "$HEARTBEAT_SCRIPT"
    log "Removed heartbeat script."

    # 7. Remove WireGuard config
    rm -f "$WG_CONF"
    log "Removed WireGuard config ${WG_CONF}."

    # 8. Remove keys and node_id
    rm -rf "$KEY_DIR"
    log "Removed key directory ${KEY_DIR}."

    log "Unenroll complete. This node has been removed from wg0."
    exit 0
fi

# ── ENROLL ────────────────────────────────────────────────────────────────────
if [[ -z "${TOKEN:-}" || -z "${BRAIN_URL:-}" ]]; then
    echo "Usage:"
    echo "  $0 enroll <TOKEN> <BRAIN_URL> [NODE_NAME] [OS_TYPE] [ROLE] [ADVERTISED_ROUTES_CSV]"
    echo "  $0 unenroll <BRAIN_URL>"
    exit 1
fi

BRAIN_URL="${BRAIN_URL%/}"  # strip trailing slash

# ── Dependency check & auto-install ──────────────────────────────────────────
install_deps() {
    local missing=()
    for cmd in wg wg-quick curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    log "Missing: ${missing[*]}. Installing..."

    # Map command names to package names.
    local pkgs=()
    for cmd in "${missing[@]}"; do
        case "$cmd" in
            wg|wg-quick) pkgs+=("wireguard-tools") ;;
            *)           pkgs+=("$cmd") ;;
        esac
    done
    # Deduplicate.
    pkgs=($(printf '%s\n' "${pkgs[@]}" | sort -u))

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq "${pkgs[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${pkgs[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "${pkgs[@]}"
    else
        die "Cannot auto-install packages. Install manually: ${pkgs[*]}"
    fi

    # Verify everything is available now.
    for cmd in wg wg-quick curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' still not found after install attempt."
    done
    log "Dependencies installed."
}
install_deps

# ── Directory setup ───────────────────────────────────────────────────────────
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# ── Key generation ────────────────────────────────────────────────────────────
if [[ ! -f "$PRIV_KEY_FILE" ]]; then
    log "Generating WireGuard keypair..."
    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"
fi
PRIV_KEY=$(cat "$PRIV_KEY_FILE")
PUB_KEY=$(cat "$PUB_KEY_FILE")
INSTALLATION_ID=$(get_or_create_installation_id)
log "Public key: $PUB_KEY"

# ── Detect public endpoint ────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
ENDPOINT=""
[[ -n "$PUBLIC_IP" ]] && ENDPOINT="${PUBLIC_IP}:51820"

# ── Enrollment ────────────────────────────────────────────────────────────────
if [[ ! -f "$NODE_ID_FILE" ]]; then
    log "Enrolling node '${NODE_NAME}' (role=${ROLE}) with Brain at ${BRAIN_URL} ..."

    # Build JSON payload
    if [[ -n "$ADVERTISED_ROUTES_CSV" ]]; then
        # Convert "192.168.1.0/24,10.0.0.0/8" → ["192.168.1.0/24","10.0.0.0/8"]
        ROUTES_JSON=$(echo "$ADVERTISED_ROUTES_CSV" | jq -R 'split(",") | map(select(length > 0) | gsub("^ +| +$"; ""))')
    else
        ROUTES_JSON="[]"
    fi

    PAYLOAD=$(cat <<EOF
{
    "token": "${TOKEN}",
    "installation_id": "${INSTALLATION_ID}",
    "public_key": "${PUB_KEY}",
    "node_name": "${NODE_NAME}",
    "os_type": "${OS_TYPE}",
    "role": "${ROLE}",
    "advertised_routes": ${ROUTES_JSON},
    "endpoint": "${ENDPOINT}"
}
EOF
)

    ENROLL_RESPONSE=$(curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${BRAIN_URL}/api/v1/enroll/register") \
        || die "Enrollment failed. Check TOKEN and BRAIN_URL. Brain returned an error."

    DEVICE_ID=$(echo "$ENROLL_RESPONSE" | jq -r '.device_id // empty')
    NODE_ID=$(echo "$ENROLL_RESPONSE" | jq -r '.node_id')
    OVERLAY_IP=$(echo "$ENROLL_RESPONSE" | jq -r '.overlay_ip')
    WG_CONFIG=$(echo "$ENROLL_RESPONSE" | jq -r '.wg_config')
    # Device protocol v2 secret — returned ONCE in the enrollment
    # response. Store it at 0600 next to the private key; the heartbeat
    # script reads it and sends it as X-Device-Secret on every request.
    DEVICE_SECRET=$(echo "$ENROLL_RESPONSE" | jq -r '.device_secret // empty')

    # Clear any stale revoked marker from a prior node_id's deletion —
    # re-enrolling is the explicit recovery path out of the revoked
    # state (see heartbeat 404 handler).
    rm -f "${KEY_DIR}/revoked" 2>/dev/null || true
    echo "$NODE_ID" > "$NODE_ID_FILE"
    chmod 600 "$NODE_ID_FILE"
    if [[ -n "$DEVICE_ID" ]]; then
        printf '%s' "$DEVICE_ID" > "$DEVICE_ID_FILE"
        chmod 600 "$DEVICE_ID_FILE"
    fi
    echo "$BRAIN_URL" > "${KEY_DIR}/brain_url"
    chmod 600 "${KEY_DIR}/brain_url"
    if [[ -n "$DEVICE_SECRET" ]]; then
        printf '%s' "$DEVICE_SECRET" > "$DEVICE_SECRET_FILE"
        chmod 600 "$DEVICE_SECRET_FILE"
    fi
    persist_connector_state
    # Bare overlay IP (no /prefix) — used by the heartbeat's same-LAN
    # state machine to alias the overlay /32 on the physical interface.
    echo "${OVERLAY_IP%/*}" > "${KEY_DIR}/overlay_ip"
    chmod 600 "${KEY_DIR}/overlay_ip"

    # Write wg conf — substitute private key placeholder
    echo "$WG_CONFIG" \
        | sed "s|# PrivateKey = <CONNECTOR_FILLS_THIS_IN>|PrivateKey = ${PRIV_KEY}|" \
        > "$WG_CONF"
    chmod 600 "$WG_CONF"

    log "Enrolled! Overlay/Assigned IP: ${OVERLAY_IP} | Node ID: ${NODE_ID}"
fi

NODE_ID=$(cat "$NODE_ID_FILE")

# ── Bring up WireGuard ────────────────────────────────────────────────────────
if ! ip link show "$WG_IFACE" >/dev/null 2>&1; then
    log "Bringing up WireGuard interface ${WG_IFACE}..."
    wg-quick up "$WG_CONF" || die "Failed to bring up WireGuard. Check /var/log/syslog."
fi
log "Interface ${WG_IFACE} is up."

# ── Native-LAN host setup ────────────────────────────────────────────────────
#
# For a host enrollment with ADVERTISED_ROUTES, configure the Linux kernel
# and iptables to route WireGuard client traffic to/from the physical LAN.
#
# Issues we hit during initial deployment and now prevent automatically:
#
#   1. Host wg0 Address was /24 — hijacked the physical LAN subnet into the
#      tunnel. Brain now renders /32. Nothing to do here.
#
#   2. proxy_arp on "all" poisons the LAN (host answers ARP for the gateway).
#      Brain now only sets proxy_arp on wg0. Nothing to do here.
#
#   3. rp_filter=2 (default on many distros) silently drops forwarded packets
#      because the source IP doesn't match the incoming interface.
#      Fix: set rp_filter=0 on wg0, physical interface, and all.
#
#   4. iptables FORWARD chain has policy DROP (common when Docker is installed).
#      Fix: explicit ACCEPT rules for wg0 <-> physical interface.
#
#   5. LAN devices on the physical subnet don't know how to route to remote
#      WG client IPs (no proxy ARP on the physical interface, and installing
#      it for arbitrary /32s is fragile). Fix: SNAT/MASQUERADE the forwarded
#      traffic so return packets flow back via the host's own IP. Trade-off:
#      LAN devices see traffic as coming from the host, not the client. For
#      true "remote client appears on LAN with its own IP", a proxy ARP
#      responder per client IP is needed — that's the experimental macOS
#      helper work, not needed for MVP.
setup_native_lan_host() {
    # Only runs for hosts that advertise routes.
    [[ "$ROLE" == "host" ]] || return 0
    [[ -n "$ADVERTISED_ROUTES_CSV" ]] || return 0

    log "Configuring native-LAN host forwarding..."

    # Find the physical interface we should forward traffic through.
    #
    # On multi-homed hosts, the default route is often on a management NIC
    # while the advertised LAN is on a different data NIC. Pick the interface
    # that has a kernel route to the FIRST advertised CIDR — that's where
    # traffic must exit. Fall back to the default route only if we can't
    # find one. Last resort: scan interface addresses for the subnet.
    local phys_iface first_route probe_ip wan_iface
    first_route=$(first_valid_ipv4_cidr "$ADVERTISED_ROUTES_CSV" || true)
    if [[ -n "$first_route" ]]; then
        probe_ip=$(echo "$first_route" | cut -d/ -f1)
        phys_iface=$({ ip -4 route get "$probe_ip" 2>/dev/null || true; } | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    elif [[ -n "$ADVERTISED_ROUTES_CSV" ]]; then
        warn "ADVERTISED_ROUTES_CSV='${ADVERTISED_ROUTES_CSV}' contains no valid IPv4 CIDRs. Falling back to default-route detection."
    fi
    if [[ -z "$phys_iface" || "$phys_iface" == "$WG_IFACE" ]]; then
        phys_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    fi
    if [[ -z "$phys_iface" && -n "$first_route" ]]; then
        # Last resort: find an interface with an IP in the advertised subnet.
        phys_iface=$(ip -4 -o addr show | awk -v net="$first_route" '
            BEGIN { split(net, parts, "/"); prefix=parts[1]; sub(/\.[0-9]+$/, ".", prefix) }
            $4 ~ prefix { print $2; exit }
        ')
    fi
    if [[ -z "$phys_iface" || "$phys_iface" == "$WG_IFACE" ]]; then
        warn "Could not detect physical LAN interface. Skipping host forwarding setup."
        return 0
    fi
    log "Physical LAN interface detected: ${phys_iface} (route to ${first_route:-default})"
    echo "$phys_iface" > "${KEY_DIR}/phys_iface"
    chmod 600 "${KEY_DIR}/phys_iface"

    wan_iface=$(ip route show default 2>/dev/null | awk '/^default/ && $5 != "'"${WG_IFACE}"'" && $5 != "wg0-up" {print $5; exit}')
    if [[ -n "$wan_iface" ]]; then
        echo "$wan_iface" > "${KEY_DIR}/wan_iface"
        chmod 600 "${KEY_DIR}/wan_iface"
        log "Default WAN interface detected: ${wan_iface}"
    else
        rm -f "${KEY_DIR}/wan_iface" 2>/dev/null || true
        warn "Could not detect a default WAN interface for host internet exit."
    fi

    # Save the original sysctl values so unenroll can restore them.
    # Only write the state file on first setup; re-enrolls keep the
    # original snapshot so we remember the pristine pre-connector state.
    local state_file="${KEY_DIR}/sysctl_state"
    if [[ ! -f "$state_file" ]]; then
        {
            echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
            echo "rp_filter_all=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo 2)"
            echo "rp_filter_wg=$(cat /proc/sys/net/ipv4/conf/${WG_IFACE}/rp_filter 2>/dev/null || echo 2)"
            echo "rp_filter_phys=$(cat /proc/sys/net/ipv4/conf/${phys_iface}/rp_filter 2>/dev/null || echo 2)"
            echo "rp_filter_wan=$(cat /proc/sys/net/ipv4/conf/${wan_iface}/rp_filter 2>/dev/null || echo 2)"
            echo "phys_iface=${phys_iface}"
            echo "wan_iface=${wan_iface}"
        } > "$state_file"
        chmod 600 "$state_file"
    fi

    # Enable IP forwarding.
    sysctl -qw net.ipv4.ip_forward=1 || warn "Could not set ip_forward"

    # Relax reverse-path filtering so forwarded packets aren't silently
    # dropped when their source doesn't match the incoming interface.
    sysctl -qw net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
    sysctl -qw "net.ipv4.conf.${WG_IFACE}.rp_filter=0" 2>/dev/null || true
    sysctl -qw "net.ipv4.conf.${phys_iface}.rp_filter=0" 2>/dev/null || true
    if [[ -n "$wan_iface" && "$wan_iface" != "$phys_iface" ]]; then
        sysctl -qw "net.ipv4.conf.${wan_iface}.rp_filter=0" 2>/dev/null || true
    fi

    ensure_forward_iface() {
        local iface="$1"
        [[ -z "$iface" ]] && return 0
        if ! iptables -C FORWARD -i "$WG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 1 -i "$WG_IFACE" -o "$iface" -j ACCEPT
        fi
        if ! iptables -C FORWARD -i "$iface" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 1 -i "$iface" -o "$WG_IFACE" -j ACCEPT
        fi
    }

    ensure_forward_same_tunnel() {
        if ! iptables -C FORWARD -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 1 -i "$WG_IFACE" -o "$WG_IFACE" -j ACCEPT
        fi
    }

    ensure_nat_iface() {
        local iface="$1"
        local route
        [[ -z "$iface" ]] && return 0
        IFS=',' read -ra MASQ_ROUTES <<< "$ADVERTISED_ROUTES_CSV"
        for route in "${MASQ_ROUTES[@]}"; do
            route=$(echo "$route" | xargs)
            [[ -z "$route" ]] && continue
            if ! iptables -t nat -C POSTROUTING -s "$route" -o "$iface" -j MASQUERADE 2>/dev/null; then
                iptables -t nat -I POSTROUTING 1 -s "$route" -o "$iface" -j MASQUERADE
            fi
        done
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

        IFS=',' read -ra MASQ_ROUTES <<< "$ADVERTISED_ROUTES_CSV"
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
    chmod 600 "$EGRESS_IFACES_FILE" 2>/dev/null || true

    # iptables FORWARD: explicit ACCEPT between wg0 and the physical LAN
    # and, when different, the default WAN interface used for internet exit.
    for iface in "${EGRESS_IFACES[@]}"; do
        ensure_forward_iface "$iface"
    done
    ensure_forward_same_tunnel

    # SNAT: rewrite WG-sourced traffic going out the physical iface so the
    # LAN sees it coming from the host. Install one MASQUERADE rule per
    # advertised route. Scoping by source subnet keeps this from interfering
    # with unrelated traffic.
    for iface in "${EGRESS_IFACES[@]}"; do
        ensure_nat_iface "$iface"
    done

    log "Host forwarding configured on LAN=${phys_iface}${wan_iface:+ WAN=${wan_iface}} egress_ifaces=$(printf '%s,' "${EGRESS_IFACES[@]}" | sed 's/,$//')."
}

setup_native_lan_host

# ── Heartbeat script ──────────────────────────────────────────────────────────
write_heartbeat_script

# ── Install heartbeat — systemd or fallback loop ──────────────────────────────
if command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
    cat > /etc/systemd/system/wg0-heartbeat.service <<EOF
[Unit]
Description=wg0 Heartbeat

[Service]
Type=oneshot
ExecStart=${HEARTBEAT_SCRIPT}
ExecStartPost=/bin/sh -c 'touch /var/log/wg0-heartbeat.log'
TimeoutStartSec=60
StandardOutput=append:/var/log/wg0-heartbeat.log
StandardError=append:/var/log/wg0-heartbeat.log
EOF

    cat > /etc/systemd/system/wg0-heartbeat.timer <<EOF
[Unit]
Description=wg0 Heartbeat Timer
After=network-online.target

[Timer]
OnBootSec=10s
OnUnitActiveSec=${HEARTBEAT_INTERVAL}s

[Install]
WantedBy=timers.target
EOF

    # Watchdog: independent timer that kicks the heartbeat if the log hasn't
    # been written in >120s. Survives a broken heartbeat timer or a hung
    # previous run that blocked OnUnitActiveSec. Same pattern as macOS.
    cat > /etc/systemd/system/wg0-heartbeat-watchdog.service <<'EOF'
[Unit]
Description=wg0 Heartbeat Watchdog

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'LOG=/var/log/wg0-heartbeat.log; STALE=120; if [ ! -f "$LOG" ] || [ $(( $(date +%s) - $(stat -c %Y "$LOG" 2>/dev/null || echo 0) )) -gt "$STALE" ]; then systemctl start wg0-heartbeat.service; echo "[$(date -u +%H:%M:%SZ)] watchdog: kicked heartbeat (stale >${STALE}s)" >> /var/log/wg0-heartbeat-watchdog.log; fi'
TimeoutStartSec=30
EOF

    cat > /etc/systemd/system/wg0-heartbeat-watchdog.timer <<'EOF'
[Unit]
Description=wg0 Heartbeat Watchdog Timer

[Timer]
OnBootSec=120s
OnUnitActiveSec=120s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now wg0-heartbeat.timer
    systemctl enable --now wg0-heartbeat-watchdog.timer
    log "Heartbeat timer installed (systemd, every ${HEARTBEAT_INTERVAL}s)."
    log "Heartbeat watchdog installed (systemd, every 120s)."

else
    # Non-systemd fallback: background loop (OpenWRT, proprietary channel banks, etc.)
    log "systemd not found — starting background heartbeat loop (every ${HEARTBEAT_INTERVAL}s)..."
    while true; do
        sleep "$HEARTBEAT_INTERVAL"
        "$HEARTBEAT_SCRIPT" &>/dev/null || true
    done &
    disown
    log "Heartbeat loop started (PID $!)."
fi

# ── Install wg0 status CLI ────────────────────────────────────────────────
if curl -fsSL "${BRAIN_URL%/api*}/../wg0-status.sh" -o /usr/local/bin/wg0 2>/dev/null \
   || curl -fsSL "https://wg0.io/wg0-status.sh" -o /usr/local/bin/wg0 2>/dev/null; then
    chmod +x /usr/local/bin/wg0
    log "Installed: 'wg0 status' command"
fi

log ""
log "wg0 connector setup complete."
log "  WireGuard interface: ${WG_IFACE}"
log "  Node ID:             ${NODE_ID}"
log "  Config:              ${WG_CONF}"
log ""
log "Check tunnel status anytime: wg0 status"
