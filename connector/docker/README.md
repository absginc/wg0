# wg0 Docker Connector

Run a wg0 WireGuard node inside a Docker container. Enrolls automatically,
maintains the tunnel, and heartbeats to the control plane. Alpine-based,
under 40 MB.

## Quick start

```bash
docker run -d \
  --name wg0 \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  -e ENROLLMENT_TOKEN="<your-token>" \
  -e BRAIN_URL="https://connect.wg0.io" \
  ghcr.io/absginc/wg0-connector:latest
```

Get your enrollment token from the **+ Add Device** button in the
[wg0 dashboard](https://login.wg0.io).

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ENROLLMENT_TOKEN` | Yes | | Enrollment token from the dashboard |
| `BRAIN_URL` | Yes | | Brain API URL (usually `https://connect.wg0.io`) |
| `NODE_NAME` | No | container hostname | Display name in the dashboard |
| `ROLE` | No | `client` | Node role: `client` or `host` |
| `ADVERTISED_ROUTES` | No | | Comma-separated CIDRs to advertise (host mode) |
| `HEARTBEAT_INTERVAL` | No | `30` | Seconds between heartbeats |

## Requirements

The container needs:
- `NET_ADMIN` capability (for WireGuard interface management)
- Access to `/dev/net/tun` (TUN device for the tunnel)

## Persistent enrollment

Mount a volume to preserve keys and enrollment across container restarts.
Without a volume, every restart creates a new device in the dashboard.

```bash
docker run -d \
  --name wg0 \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  -v wg0-data:/etc/wireguard \
  -e ENROLLMENT_TOKEN="<your-token>" \
  -e BRAIN_URL="https://connect.wg0.io" \
  ghcr.io/absginc/wg0-connector:latest
```

## Docker Compose

```yaml
services:
  wg0:
    image: ghcr.io/absginc/wg0-connector:latest
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    environment:
      ENROLLMENT_TOKEN: "${WG0_TOKEN}"
      BRAIN_URL: "https://connect.wg0.io"
      NODE_NAME: "docker-node"
    volumes:
      - wg0-data:/etc/wireguard
    restart: unless-stopped

volumes:
  wg0-data:
```

## Kubernetes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: wg0
spec:
  containers:
    - name: wg0
      image: ghcr.io/absginc/wg0-connector:latest
      securityContext:
        capabilities:
          add: [NET_ADMIN]
      env:
        - name: ENROLLMENT_TOKEN
          valueFrom:
            secretKeyRef:
              name: wg0-secrets
              key: enrollment-token
        - name: BRAIN_URL
          value: "https://connect.wg0.io"
      volumeMounts:
        - name: tun
          mountPath: /dev/net/tun
        - name: wg-data
          mountPath: /etc/wireguard
  volumes:
    - name: tun
      hostPath:
        path: /dev/net/tun
    - name: wg-data
      emptyDir: {}
```

## Building locally

```bash
cd connector/docker
docker build -t wg0-connector .
```

## How it works

1. On first start, generates a WireGuard keypair
2. Enrolls with the brain using your token
3. Writes the WireGuard config and brings up the `wg0` interface
4. Runs a heartbeat loop every 30 seconds:
   - Reports tunnel stats (tx/rx bytes, peer handshakes)
   - Receives peer config updates from the brain
   - Applies changes via `wg syncconf` (no tunnel restart)
5. On `docker stop`, gracefully tears down the tunnel

## Multi-network: one container per network

The Docker connector is single-interface by design — each container
holds exactly one `wg0` tunnel. If you want the same host attached to
multiple wg0 networks (e.g. your `home` network plus a shared `msp-lab`
network), **run a separate container per network**:

```bash
# Network 1 — home
docker run -d --name wg0-home \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v wg0-data-home:/etc/wireguard \
  -e ENROLLMENT_TOKEN=<TOKEN_FOR_HOME> \
  -e BRAIN_URL=https://connect.wg0.io \
  -e NODE_NAME=docker-home \
  wg0-connector:latest

# Network 2 — msp-lab (different volume, different token,
# different container name)
docker run -d --name wg0-lab \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v wg0-data-lab:/etc/wireguard \
  -e ENROLLMENT_TOKEN=<TOKEN_FOR_LAB> \
  -e BRAIN_URL=https://connect.wg0.io \
  -e NODE_NAME=docker-lab \
  wg0-connector:latest
```

Each container enrolls as its own managed device — they do NOT share
an `installation_id`, so from the brain's perspective they appear as
two independent nodes (which they are, from a network-isolation
standpoint). If you need a SINGLE device identity holding multiple
memberships in one place, use the Linux shell connector
(`connector.sh attach ...`) or the native Windows/macOS app — both
drive the `/api/v1/devices/:id/memberships` attach flow. See
[docs/CONNECTOR_MULTINETWORK_ROADMAP.md](../../docs/CONNECTOR_MULTINETWORK_ROADMAP.md).

## Logs

```bash
docker logs wg0
```

Output looks like:
```
[wg0 14:32:01Z] Generating WireGuard keypair...
[wg0 14:32:01Z] Enrolling 'docker-node' (role=client) with https://connect.wg0.io...
[wg0 14:32:02Z] Enrolled! Overlay IP: 10.64.0.5/24 | Node ID: a1b2c3d4-...
[wg0 14:32:02Z] Bringing up WireGuard interface wg0...
[wg0 14:32:02Z] Interface wg0 is up.
[wg0 14:32:02Z] Starting heartbeat loop (every 30s)...
```
