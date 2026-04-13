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
WG_IFACE="wg0"
WG_CONF="/etc/wireguard/wg0.conf"
KEY_DIR="/etc/wireguard/wg0"
PRIV_KEY_FILE="${KEY_DIR}/private.key"
PUB_KEY_FILE="${KEY_DIR}/public.key"
NODE_ID_FILE="${KEY_DIR}/node_id"
DEVICE_SECRET_FILE="${KEY_DIR}/device_secret"
CONFIG_VERSION_FILE="${KEY_DIR}/config_version"
NODE_NAME="${NODE_NAME:-$(hostname)}"
ROLE="${ROLE:-client}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"

log() { echo "[wg0 $(date -u +%H:%M:%SZ)] $*"; }
die() { log "FATAL: $*" >&2; exit 1; }

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
        --arg public_key "$PUB_KEY" \
        --arg node_name "$NODE_NAME" \
        --arg os_type "linux-docker" \
        --arg role "$ROLE" \
        --arg endpoint "$ENDPOINT" \
        --argjson advertised_routes "$ROUTES_JSON" \
        '{token:$token, public_key:$public_key, node_name:$node_name,
          os_type:$os_type, role:$role, endpoint:$endpoint,
          advertised_routes:$advertised_routes}')

    ENROLL_RESPONSE=$(curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${BRAIN_URL}/api/v1/enroll/register") \
        || die "Enrollment failed. Check ENROLLMENT_TOKEN and BRAIN_URL."

    NODE_ID=$(echo "$ENROLL_RESPONSE" | jq -r '.node_id')
    OVERLAY_IP=$(echo "$ENROLL_RESPONSE" | jq -r '.overlay_ip')
    WG_CONFIG=$(echo "$ENROLL_RESPONSE" | jq -r '.wg_config')
    DEVICE_SECRET=$(echo "$ENROLL_RESPONSE" | jq -r '.device_secret // empty')

    echo "$NODE_ID" > "$NODE_ID_FILE" && chmod 600 "$NODE_ID_FILE"
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

# ── Bring up WireGuard ───────────────────────────────────────────────────────
log "Bringing up WireGuard interface ${WG_IFACE}..."
wg-quick up "$WG_CONF" || die "Failed to bring up WireGuard."
log "Interface ${WG_IFACE} is up."

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

    # ── Send heartbeat ──
    HB_BODY=$(jq -cn \
        --arg endpoint "$ENDPOINT" \
        --argjson tx_bytes "$TX_BYTES" \
        --argjson rx_bytes "$RX_BYTES" \
        --argjson peers "$PEERS_JSON" \
        '{endpoint:$endpoint, tx_bytes:$tx_bytes, rx_bytes:$rx_bytes,
          peers:$peers, route_all_active:false, upstream_exit_health:null}')

    CURL_ARGS=( -sf -X POST -H "Content-Type: application/json" )
    [[ -n "$DEVICE_SECRET" ]] && CURL_ARGS+=( -H "X-Device-Secret: $DEVICE_SECRET" )

    RESPONSE=$(curl "${CURL_ARGS[@]}" \
        -d "$HB_BODY" \
        "${BRAIN_URL}/api/v1/nodes/${NODE_ID}/heartbeat" 2>/dev/null) || continue

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
                wg syncconf ${WG_IFACE} <(wg-quick strip "$WG_CONF") 2>/dev/null || true
                echo "$REMOTE_CV" > "$CONFIG_VERSION_FILE"
                log "Config updated to version ${REMOTE_CV}."
            fi
        fi
    fi

    # ── Apply peer map updates ──
    echo "$RESPONSE" | jq -c '.peers[]' 2>/dev/null | while read -r peer; do
        PUBKEY=$(echo "$peer" | jq -r '.public_key')
        ALLOWED=$(echo "$peer" | jq -r '.allowed_ips')
        EP=$(echo "$peer" | jq -r '.endpoint // empty')

        if [[ -n "$EP" ]]; then
            wg set ${WG_IFACE} peer "$PUBKEY" allowed-ips "$ALLOWED" endpoint "$EP" persistent-keepalive 25
        else
            wg set ${WG_IFACE} peer "$PUBKEY" allowed-ips "$ALLOWED" persistent-keepalive 25
        fi

        # Install system routes for each allowed CIDR.
        echo "$ALLOWED" | tr ',' '\n' | tr -d ' ' | while read -r cidr; do
            [[ -z "$cidr" || "$cidr" == "0.0.0.0/0" ]] && continue
            ip route replace "$cidr" dev ${WG_IFACE} 2>/dev/null || true
        done
    done

    # ── Remove stale WireGuard peers ──
    RESPONSE_PUBKEYS=$(echo "$RESPONSE" | jq -r '.peers[].public_key' 2>/dev/null | sort -u)
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
