#!/usr/bin/env bash
# wg0 — wg0 tunnel status CLI
# Works on Linux and macOS. Run as root or with sudo for WireGuard access.
#
# Usage:
#   wg0 status          Full status: tunnel, peers, heartbeat
#   wg0 status --json   Machine-readable JSON
#   wg0 peers           Peer list only with TX/RX
#   wg0 logs            Tail heartbeat log (last 40 lines)
#   wg0 version         Show connector info

set -euo pipefail

WG_IFACE="wg0"
# Support both new (/etc/wireguard/wg0) and legacy (/etc/wireguard/abslink) key dirs
if [[ -d /etc/wireguard/wg0 ]]; then
    KEY_DIR="/etc/wireguard/wg0"
elif [[ -d /etc/wireguard/abslink ]]; then
    KEY_DIR="/etc/wireguard/abslink"
else
    KEY_DIR="/etc/wireguard/wg0"
fi
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
NODE_ID_FILE="${KEY_DIR}/node_id"

# ── OS detection ──────────────────────────────────────────────────────────────
OS=$(uname -s)

# ── Helpers ───────────────────────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
red()   { printf '\033[31m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }
line()  { printf '━%.0s' $(seq 1 44); printf '\n'; }

fmt_bytes() {
    local b="$1"
    if   [[ "$b" -ge 1073741824 ]]; then printf "%.1f GiB" "$(echo "scale=1; $b/1073741824" | bc)"
    elif [[ "$b" -ge 1048576    ]]; then printf "%.1f MiB" "$(echo "scale=1; $b/1048576" | bc)"
    elif [[ "$b" -ge 1024       ]]; then printf "%.1f KiB" "$(echo "scale=1; $b/1024" | bc)"
    elif [[ "$b" -gt 0          ]]; then printf "%s B" "$b"
    else printf "—"
    fi
}

fmt_ago() {
    local s="$1"
    if   [[ "$s" -lt 60   ]]; then echo "${s}s ago"
    elif [[ "$s" -lt 3600 ]]; then echo "$((s/60))m ago"
    else echo "$((s/3600))h ago"
    fi
}

# ── Resolve WireGuard interface name ─────────────────────────────────────────
resolve_wg_iface() {
    if [[ "$OS" == "Darwin" ]]; then
        local name
        name=$(cat /var/run/wireguard/${WG_IFACE}.name 2>/dev/null \
            || sudo cat /var/run/wireguard/${WG_IFACE}.name 2>/dev/null) || true
        name=$(echo "$name" | tr -d '[:space:]')
        if [[ -n "$name" ]]; then
            echo "$name"
        else
            echo "$WG_IFACE"
        fi
    else
        echo "$WG_IFACE"
    fi
}

# ── Heartbeat status ──────────────────────────────────────────────────────────
# On macOS the heartbeat runs every 30s via a LaunchDaemon StartInterval job.
# `launchctl list` output format:
#     PID   EXIT  LABEL
#     -     0     io.wg0.heartbeat     ← scheduled, last run exit 0 (HEALTHY)
#     1234  0     io.wg0.heartbeat     ← currently executing
#     -     1     io.wg0.heartbeat     ← scheduled, last run exited non-zero
#
# A `-` PID plus exit 0 is normal idle state — the daemon is healthy.
hb_status() {
    if [[ "$OS" == "Darwin" ]]; then
        local line
        line=$(launchctl list 2>/dev/null | grep -E 'io\.wg0\.heartbeat|com\.abslink\.heartbeat' | head -1)
        if [[ -z "$line" ]]; then
            line=$(sudo launchctl list 2>/dev/null | grep -E 'io\.wg0\.heartbeat|com\.abslink\.heartbeat' | head -1)
        fi
        if [[ -z "$line" ]]; then
            echo "not loaded"; return
        fi
        local pid exit_code
        pid=$(echo "$line"   | awk '{print $1}')
        exit_code=$(echo "$line" | awk '{print $2}')
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            echo "running"
        elif [[ "$exit_code" == "0" ]]; then
            echo "idle (last run ok)"
        else
            echo "failing (exit $exit_code)"
        fi
    else
        systemctl is-active wg0-heartbeat.timer 2>/dev/null || echo "inactive"
    fi
}

hb_log_path() {
    echo "/var/log/wg0-heartbeat.log"
}

# ── WireGuard running check ───────────────────────────────────────────────────
wg_running() {
    local iface
    iface=$(resolve_wg_iface)
    wg show "$iface" >/dev/null 2>&1 || sudo wg show "$iface" >/dev/null 2>&1
}

# ── Gather all data ───────────────────────────────────────────────────────────
gather() {
    NODE_ID=$(cat "$NODE_ID_FILE" 2>/dev/null || sudo cat "$NODE_ID_FILE" 2>/dev/null || echo "not enrolled")
    OVERLAY_IP=$(grep -m1 '^Address' "$WG_CONF" 2>/dev/null || sudo grep -m1 '^Address' "$WG_CONF" 2>/dev/null)
    OVERLAY_IP=$(echo "$OVERLAY_IP" | awk '{print $3}')
    [[ -z "$OVERLAY_IP" ]] && OVERLAY_IP="—"
    WG_REAL=$(resolve_wg_iface)
    WG_OUT=$(wg show "$WG_REAL" 2>/dev/null || sudo wg show "$WG_REAL" 2>/dev/null || echo "")
    HB_STATUS=$(hb_status)
    LOG_PATH=$(hb_log_path)
    LAST_HB="—"
    if [[ -f "$LOG_PATH" ]]; then
        # Extract timestamp of last run from log (best-effort)
        LAST_HB=$(stat -f "%Sm" -t "%s" "$LOG_PATH" 2>/dev/null \
                  || stat -c "%Y" "$LOG_PATH" 2>/dev/null || echo "")
        if [[ -n "$LAST_HB" && "$LAST_HB" =~ ^[0-9]+$ ]]; then
            local now; now=$(date +%s)
            LAST_HB=$(fmt_ago $((now - LAST_HB)))
        else
            LAST_HB="—"
        fi
    fi

    # Parse peers from `wg show` output.
    #
    # The output layout is:
    #   interface: utunN
    #     public key: <iface pubkey>     ← NOT a peer, don't capture
    #     private key: (hidden)
    #     listening port: 51820
    #
    #   peer: <peer pubkey>              ← this is what starts a peer block
    #     endpoint: ...
    #     allowed ips: ...
    #     latest handshake: ...
    #     transfer: X B received, Y B sent
    #     persistent keepalive: every Ns
    PEERS=()
    local cur_key="" cur_ep="" cur_allowed="" cur_tx=0 cur_rx=0 cur_hs=""
    local in_peer=0
    while IFS= read -r wg_line; do
        case "$wg_line" in
            "peer: "*)
                # flush previous
                if [[ $in_peer -eq 1 && -n "$cur_key" ]]; then
                    PEERS+=("${cur_key}|${cur_ep}|${cur_allowed}|${cur_tx}|${cur_rx}|${cur_hs}")
                fi
                cur_key="${wg_line#peer: }"
                cur_ep=""; cur_allowed=""; cur_tx=0; cur_rx=0; cur_hs=""
                in_peer=1
                ;;
            "interface: "*)
                # New interface block → any in-progress peer flushes
                if [[ $in_peer -eq 1 && -n "$cur_key" ]]; then
                    PEERS+=("${cur_key}|${cur_ep}|${cur_allowed}|${cur_tx}|${cur_rx}|${cur_hs}")
                fi
                cur_key=""; in_peer=0
                ;;
            "  endpoint: "*)         [[ $in_peer -eq 1 ]] && cur_ep="${wg_line#*: }" ;;
            "  allowed ips: "*)      [[ $in_peer -eq 1 ]] && cur_allowed="${wg_line#*: }" ;;
            "  latest handshake: "*) [[ $in_peer -eq 1 ]] && cur_hs="${wg_line#*: }" ;;
            "  transfer: "*)
                if [[ $in_peer -eq 1 ]]; then
                    local tf="${wg_line#*: }"
                    cur_rx=$(echo "$tf" | sed 's/ received.*//' | awk '{print $1}' || echo 0)
                    cur_tx=$(echo "$tf" | sed 's/.*received, //' | sed 's/ sent.*//' | awk '{print $1}' || echo 0)
                fi
                ;;
        esac
    done <<< "$WG_OUT"
    # flush last peer
    if [[ $in_peer -eq 1 && -n "$cur_key" ]]; then
        PEERS+=("${cur_key}|${cur_ep}|${cur_allowed}|${cur_tx}|${cur_rx}|${cur_hs}")
    fi
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_status() {
    local json=false
    [[ "${1:-}" == "--json" ]] && json=true

    gather

    local wg_state
    if wg_running 2>/dev/null; then wg_state="running"; else wg_state="down"; fi

    local iface_display="$WG_IFACE"
    [[ "$OS" == "Darwin" && "$WG_REAL" != "$WG_IFACE" ]] && iface_display="${WG_IFACE} → ${WG_REAL}"

    if $json; then
        printf '{\n'
        printf '  "node_id": "%s",\n' "$NODE_ID"
        printf '  "overlay_ip": "%s",\n' "$OVERLAY_IP"
        printf '  "interface": "%s",\n' "$WG_REAL"
        printf '  "wireguard": "%s",\n' "$wg_state"
        printf '  "heartbeat": "%s",\n' "$HB_STATUS"
        printf '  "last_heartbeat": "%s",\n' "$LAST_HB"
        printf '  "peer_count": %d,\n' "${#PEERS[@]}"
        printf '  "peers": [\n'
        local i=0
        for p in "${PEERS[@]}"; do
            IFS='|' read -r pk ep al tx rx hs <<< "$p"
            [[ $i -gt 0 ]] && printf ',\n'
            printf '    {"public_key":"%s","endpoint":"%s","allowed_ips":"%s","tx":"%s","rx":"%s","handshake":"%s"}' \
                "$pk" "$ep" "$al" "$tx" "$rx" "$hs"
            ((i++)) || true
        done
        printf '\n  ]\n}\n'
        return
    fi

    printf '\n'
    bold "wg0 Status"; printf '\n'
    line
    printf '  %-12s %s\n' "Node ID"   "$NODE_ID"
    printf '  %-12s %s\n' "Tunnel IP" "$OVERLAY_IP"
    printf '  %-12s %s\n' "Interface" "$iface_display"
    if [[ "$wg_state" == "running" ]]; then
        printf '  %-12s %s\n' "WireGuard" "$(green running)"
    else
        printf '  %-12s %s\n' "WireGuard" "$(red down)"
        printf '  %s: ' "$(dim Restart)"
        if [[ "$OS" == "Darwin" ]]; then
            printf 'sudo rm -f /var/run/wireguard/wg0.* && sudo wg-quick up %s\n' "$WG_CONF"
        else
            printf 'sudo wg-quick up %s\n' "$WG_CONF"
        fi
    fi
    if [[ "$HB_STATUS" == "running" || "$HB_STATUS" == "active" ]]; then
        printf '  %-12s %s\n' "Heartbeat" "$(green running) (every 30s)"
    else
        printf '  %-12s %s\n' "Heartbeat" "$(red "$HB_STATUS")"
    fi
    printf '  %-12s %s\n' "Last beat" "$LAST_HB"
    printf '\n'

    printf '%s' "$(bold "Peers (${#PEERS[@]})")"; printf '\n'
    line
    if [[ ${#PEERS[@]} -eq 0 ]]; then
        printf '  %s\n' "$(dim 'No peers yet — heartbeat will sync them within 30s')"
    fi
    for p in "${PEERS[@]}"; do
        IFS='|' read -r pk ep al tx rx hs <<< "$p"
        printf '  %s\n' "$(bold "${pk:0:20}…")"
        printf '    %-10s %s\n' "Allowed"   "$al"
        printf '    %-10s %s\n' "Endpoint"  "${ep:-—}"
        printf '    %-10s TX %-14s RX %s\n' "Transfer" "$tx" "$rx"
        printf '    %-10s %s\n' "Handshake" "${hs:-never}"
        printf '\n'
    done
}

cmd_peers() {
    gather
    if [[ ${#PEERS[@]} -eq 0 ]]; then
        echo "No peers."; return
    fi
    printf '%-22s %-22s %-20s %s\n' "PUBLIC KEY" "ALLOWED IPS" "ENDPOINT" "TX / RX"
    for p in "${PEERS[@]}"; do
        IFS='|' read -r pk ep al tx rx hs <<< "$p"
        printf '%-22s %-22s %-20s %s / %s\n' "${pk:0:20}…" "${al:0:20}" "${ep:-—}" "$tx" "$rx"
    done
}

cmd_logs() {
    local log_path
    log_path=$(hb_log_path)
    if [[ -f "$log_path" ]]; then
        tail -40 "$log_path"
    else
        echo "No heartbeat log found at $log_path"
    fi
}

get_brain_url() {
    # Check stored brain_url file first, then grep from heartbeat script (new or legacy name)
    if [[ -f "${KEY_DIR}/brain_url" ]]; then
        cat "${KEY_DIR}/brain_url"
    else
        for hb in /usr/local/bin/wg0-heartbeat /usr/local/bin/abslink-heartbeat; do
            [[ -f "$hb" ]] && grep -o 'https\?://[^/"]*' "$hb" 2>/dev/null | head -1 && return
        done
        echo "—"
    fi
}

cmd_version() {
    echo "wg0 — tunnel status CLI"
    echo "Node ID: $(cat "$NODE_ID_FILE" 2>/dev/null || sudo cat "$NODE_ID_FILE" 2>/dev/null || echo 'not enrolled')"
    echo "Brain:   $(get_brain_url)"
    echo "OS:      $OS"
}

# ── Main ─────────────────────────────────────────────────────────────────────
SUBCMD="${1:-status}"
shift 2>/dev/null || true

case "$SUBCMD" in
    status)  cmd_status "${@}" ;;
    peers)   cmd_peers ;;
    logs)    cmd_logs ;;
    version) cmd_version ;;
    *)
        echo "Usage: wg0 {status [--json] | peers | logs | version}"
        exit 1
        ;;
esac
