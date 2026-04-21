# wg0 Connector

The wg0 connector turns any Linux, macOS, or Windows machine into a node on a wg0 network. It enrolls with the brain, brings up WireGuard, runs a heartbeat, and self-configures routing/forwarding/NAT for host roles.

- **`connector.sh`** — Linux
- **`connector-macos.sh`** — macOS
- **`connector-windows.ps1`** — Windows (client-only)
- **`docker/`** — Docker image for containerized deployment
- **`wg0-status.sh`** / **`wg0-status.ps1`** — the `wg0` status CLI (installed to `/usr/local/bin/wg0` on enroll)

All scripts are served from `https://wg0.io/` for quick installs.

---

## Quick start

Get an enrollment token from the dashboard (`+ Add Device` on a network), then:

```bash
# Linux client
curl -fsSL https://wg0.io/connector.sh -o connector.sh && chmod +x connector.sh
sudo ./connector.sh enroll <TOKEN> https://connect.wg0.io

# Linux host (native-LAN gateway)
sudo ./connector.sh enroll <TOKEN> https://connect.wg0.io $(hostname -s) linux host 10.0.0.0/24

# macOS
curl -fsSL https://wg0.io/connector-macos.sh -o connector-macos.sh && chmod +x connector-macos.sh
sudo ./connector-macos.sh enroll <TOKEN> https://connect.wg0.io

# Docker host
docker run -d --name wg0 --restart unless-stopped \
  --network host --privileged \
  -v wg0-data:/etc/wireguard \
  -e ENROLLMENT_TOKEN=<TOKEN> \
  -e BRAIN_URL=https://connect.wg0.io \
  -e ROLE=host -e ADVERTISED_ROUTES=10.0.0.0/24 \
  wg0-connector:latest
```

---

## `connector.sh` commands

### `enroll <TOKEN> <BRAIN_URL> [NODE_NAME] [OS_TYPE] [ROLE] [ADVERTISED_ROUTES_CSV]`

Enrolls this machine as a node. Idempotent — safe to re-run.

| Arg | Default | Description |
|---|---|---|
| `TOKEN` | required | Enrollment token from the dashboard |
| `BRAIN_URL` | required | e.g. `https://connect.wg0.io` |
| `NODE_NAME` | `$(hostname)` | Display name in the dashboard |
| `OS_TYPE` | `linux` | `linux`, `macos`, `windows`, etc. |
| `ROLE` | `client` | `client` or `host` |
| `ADVERTISED_ROUTES_CSV` | empty | Comma-separated CIDRs for host role (e.g. `10.0.0.0/24`) |

What it does:
1. Auto-installs `wireguard-tools`, `curl`, `jq` if missing (apt/yum/dnf/apk/pacman)
2. Generates a WireGuard keypair
3. Calls `POST /api/v1/enroll/register` with the token
4. Writes `/etc/wireguard/wg0.conf`, credentials under `/etc/wireguard/wg0/`
5. Brings up `wg0` via `wg-quick`
6. Installs a systemd timer (or fallback loop) to run the heartbeat every 30s
7. **For host role with `ADVERTISED_ROUTES`**: configures forwarding, rp_filter, iptables FORWARD, and NAT MASQUERADE so remote clients can reach the physical LAN

### `unenroll [BRAIN_URL]`

Fully removes the node. Auto-detects `BRAIN_URL` from stored state if omitted.

1. Calls `DELETE /api/v1/nodes/<id>/self` (best-effort — continues if brain is unreachable)
2. Brings down `wg0`
3. Removes host-mode iptables rules (FORWARD + NAT MASQUERADE)
4. Stops and removes systemd heartbeat units
5. Deletes `/etc/wireguard/wg0.conf`, all keys, node_id, device_secret, brain_url

Idempotent — safe to re-run after a partial failure.

### `check`

Health-checks a host node's forwarding configuration. Reports `PASS` / `FAIL` for each check with a specific fix command when something is wrong.

Checks:
- WireGuard interface `wg0` is up
- Physical LAN interface detected
- `net.ipv4.ip_forward = 1`
- `rp_filter = 0` on `wg0`, physical iface, and `all`
- `proxy_arp = 1` on `wg0`
- **`proxy_arp = 0` on `all`** (critical — 1 poisons the LAN)
- `iptables FORWARD` rules for `wg0 ↔ physical` present
- `iptables NAT MASQUERADE` rule on physical iface
- FORWARD chain policy (warns if `DROP`, which is common with Docker)

Exit code `0` if all pass, `1` if any fail. Easy to wire into monitoring.

```bash
sudo ./connector.sh check
```

### `update <BRAIN_URL>`

Migrates an existing enrollment to a new brain URL (or legacy `abslink` → `wg0` paths). Rewrites the heartbeat script from the current template, migrates systemd units, updates the `wg0` CLI tool.

### `rotate-secret [BRAIN_URL]`

Rotates the device secret (device protocol v2). Calls `POST /api/v1/nodes/<id>/rotate-secret` and atomically overwrites `/etc/wireguard/wg0/device_secret`.

---

## `wg0` status CLI

Installed to `/usr/local/bin/wg0` by the connector. Works on Linux and macOS.

| Command | Description |
|---|---|
| `wg0 status` | Full status — tunnel state, peers, heartbeat timing |
| `wg0 status --json` | Machine-readable JSON for scripts |
| `wg0 peers` | Just the peer list with TX/RX bytes |
| `wg0 logs` | Tail the last 40 lines of heartbeat log |
| `wg0 version` | Connector + tunnel version info |

---

## Host-mode networking (native-LAN placement)

When a host enrolls with `ROLE=host` and `ADVERTISED_ROUTES`, the connector configures the machine to route remote WireGuard clients onto the physical LAN. The brain renders a config that:

- Uses `Address = <ip>/32` on `wg0` (NOT `/24` — that hijacks the LAN)
- Enables `proxy_arp` only on `wg0` (NEVER on `all` — that poisons the LAN)
- Does not add subnet routes (the physical NIC already has them)

The connector then applies the runtime configuration:

- `net.ipv4.ip_forward=1`
- `rp_filter=0` on `wg0`, physical iface, and `all` — so forwarded packets aren't silently dropped
- `iptables -I FORWARD -i wg0 -o wg0 -j ACCEPT` — so remote clients in the same native network can traverse the host to reach each other
- `iptables -I FORWARD -i wg0 -o <phys> -j ACCEPT` (bidirectional)
- `iptables -t nat -I POSTROUTING -s <cidr> -o <phys> -j MASQUERADE` — so return traffic flows back to the host's IP (which LAN devices already know)

**Trade-off**: LAN devices see traffic from the host's IP, not the remote client's IP. For "true native LAN placement" where clients appear on the LAN with their own IPs, a per-client proxy-ARP responder is needed (experimental — see the macOS host helper).

### Lessons learned (why each step is necessary)

These are the traps we hit during initial deployment and which the connector now prevents:

1. **`Address = <ip>/24` on wg0** → kernel creates a second route for the whole subnet through wg0 → all LAN traffic goes into the tunnel → host loses connectivity to its own gateway. **Fix**: `/32` only.
2. **`proxy_arp` on `all`** → host answers ARP for every IP on every interface, including the LAN gateway → entire LAN poisoned, every device on it loses internet. **Fix**: only on `wg0`.
3. **`ip route add <subnet> dev wg0`** → same subnet hijack as (1). **Fix**: don't add.
4. **`rp_filter=2`** (default on many distros) → kernel drops forwarded packets because source doesn't match incoming interface. **Fix**: `0`.
5. **`iptables FORWARD` policy `DROP`** (Docker installs this) → silently drops everything not matched by a Docker rule. **Fix**: explicit ACCEPT rules for `wg0 ↔ phys`.
6. **No `wg0 -> wg0` FORWARD rule** → native remote clients can reach the host but not each other through it. **Fix**: explicit `iptables -I FORWARD -i wg0 -o wg0 -j ACCEPT`.
7. **No NAT** → return traffic from LAN devices has nowhere to go. **Fix**: `MASQUERADE` on the physical iface.

All seven are verified by `connector.sh check`.

---

## Files and paths

```
/etc/wireguard/wg0.conf              # WireGuard config
/etc/wireguard/wg0/
    node_id                          # UUID from enrollment
    device_secret                    # protocol v2 secret (0600)
    private.key                      # WireGuard private key (0600)
    public.key                       # WireGuard public key
    config_version                   # last-seen brain config version
    brain_url                        # stored for heartbeat
    overlay_ip                       # assigned tunnel IP
    phys_iface                       # physical LAN iface (host role only)
    installed_routes                 # state file for host route cleanup
    route_all_state                  # split-tunnel tracking
    upstream_exit_state              # BYO exit tracking

/usr/local/bin/wg0                   # status CLI
/usr/local/bin/wg0-heartbeat         # heartbeat runner

# Linux (systemd)
/etc/systemd/system/wg0-heartbeat.service
/etc/systemd/system/wg0-heartbeat.timer

# macOS (launchd)
/Library/LaunchDaemons/io.wg0.heartbeat.plist
/Library/LaunchDaemons/io.wg0.wireguard.plist

# Logs
/var/log/wg0-heartbeat.log
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Remote client can ping host wg0 IP but nothing else on LAN | rp_filter or missing FORWARD rule | `sudo ./connector.sh check` |
| Host can't reach its own gateway after enroll | Subnet hijack (bad config) | Re-enroll — brain now renders `/32` |
| Whole LAN loses internet after enroll | `proxy_arp` on `all` (old bug) | Unenroll, update connector, re-enroll |
| `ping: Required key not available` | Subnet hijack + no matching peer | Re-enroll with updated brain |
| `wg0 status` shows "heartbeat idle" with no last-run | Timer not installed or failed | `systemctl status wg0-heartbeat.timer` (Linux) / `launchctl list | grep wg0` (macOS) |
| FORWARD chain `policy DROP` warning | Docker installed its own rules | Harmless — explicit ACCEPT rules take precedence |

For machine-readable diagnostics: `wg0 status --json` and `connector.sh check` (exit code).
