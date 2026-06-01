# SoftEther VPN Client (Docker)

A lightweight Docker image for running [SoftEther VPN Client](https://www.softether.org/) with automatic connection, DHCP, route pinning, and configurable default gateway behaviour.

## Features

- Connects to any SoftEther VPN server (L2TP/IPsec, OpenVPN, SSTP, etc.)
- Automatically obtains an IP via DHCP on the virtual interface
- Pins the VPN server’s IP route to the original uplink – the control connection stays up even when the default route changes
- **Health check** with failure tolerance (does not reconnect on a single ping loss)
- **Optional default route forcing** – only if `SE_DEFAULTROUTE` is set
- Works in host and bridge network modes
- Сlear and understandable log
  
## Quick Start

Create a `docker-compose.yml`:

```yaml
services:
  softether:
    image: arembez/softether-client:latest
    container_name: softether
    privileged: true
    cap_add:
      - NET_ADMIN
    environment:
      - SE_SERVER=vpn.example.com:443
      - SE_HUB=VPNHUB
      - SE_NICNAME=myvpn
      - SE_USERNAME=myuser
      - SE_PASSWORD=mypass
      - SE_DEFAULTROUTE=1          # optional – force all traffic through VPN
    restart: unless-stopped
```

Then start:

```bash
docker compose up -d
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SE_SERVER` | yes | – | VPN server address (host:port, e.g. `vpn.example.com:443`) |
| `SE_HUB` | yes | – | Hub name on the VPN server |
| `SE_NICNAME` | yes | – | Virtual network adapter name (used internally) |
| `SE_USERNAME` | yes | – | VPN authentication username |
| `SE_PASSWORD` | yes | – | VPN authentication password |
| `SE_DEFAULTROUTE` | no | (unset) | If set to any non‑empty value, forces all traffic through the VPN (default route) |
| `PING_INTERVAL` | no | `10` | Health check interval (seconds) |
| `PING_TIMEOUT` | no | `3` | Ping timeout for gateway checks (seconds) |
| `RECONNECT_DELAY` | no | `5` | Delay before reconnecting after failure (seconds) |
| `MAX_CONNECT_WAIT` | no | `60` | Maximum time to wait for VPN connection establishment (seconds) |
| `INITIAL_STABILIZE_TIMEOUT` | no | `180` | Timeout for initial tunnel stabilisation (seconds) |
| `INITIAL_STABILIZE_INTERVAL` | no | `10` | Interval between stabilisation checks (seconds) |
| `HEALTHCHECK_FAILURES` | no | `6` | Number of consecutive health check failures before full reconnect |

## How It Works

1. The SoftEther VPN client starts and creates a virtual network adapter.
2. A VPN account is configured using the provided credentials.
3. The script detects the current default route (uplink) and resolves the VPN server IP.
4. The VPN server IP is pinned to the uplink interface – this prevents the control connection from breaking when the default route changes.
5. The VPN connection is established and an IP is obtained via DHCP.
6. If `SE_DEFAULTROUTE` is set, the default route is replaced with the VPN gateway.
7. A health check runs every `PING_INTERVAL` seconds, pinging the VPN gateway.
   - A single missed ping does **not** trigger a reconnect.
   - Only after `HEALTHCHECK_FAILURES` consecutive failures does the script reconnect.
8. The `udhcpc` output is completely silenced when DHCP succeeds – no clutter in the logs.

## Logging

The container logs show the connection progress and any errors. Successful DHCP assignment appears as:

```
[2026-06-01 08:03:04] [INFO] Requesting DHCP lease
[2026-06-01 08:03:08] [INFO] DHCP assigned IP: 192.168.30.15/24
```

## Building from Source

```bash
git clone https://github.com/arembez/softether-client
cd softether-client
docker build -t softether-client .
```

## License

MIT License
```

---

## DockerHub Description

```markdown
# SoftEther VPN Client

A production‑ready Docker image for the SoftEther VPN Client. Automatically connects to any SoftEther VPN server, obtains an IP via DHCP, and optionally forces all traffic through the tunnel.

**Key features:**

- 🔌 Works with any SoftEther VPN server (L2TP/IPsec, OpenVPN, SSTP, etc.)
- 🧠 Intelligent route pinning – keeps control connection alive even when default route changes
- 🩺 Tolerant health check – reconnects only after multiple consecutive failures
- 🚦 Optional default route enforcement – set `SE_DEFAULTROUTE=1` to route all traffic through VPN
- 🔇 Silent DHCP – no `udhcpc` or `mv: can't rename` log spam
- 🐳 Runs with `NET_ADMIN` capability (no need for full `privileged` mode)

**Quick run:**

```bash
docker run -d --cap-add=NET_ADMIN \
  -e SE_SERVER=vpn.example.com:443 \
  -e SE_HUB=VPNHUB \
  -e SE_NICNAME=myvpn \
  -e SE_USERNAME=myuser \
  -e SE_PASSWORD=mypass \
  -e SE_DEFAULTROUTE=1 \
  arembez/softether-client:latest
```

See the [GitHub repository](https://github.com/arembez/softether-client) for full documentation and docker-compose examples.
