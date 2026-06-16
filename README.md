# SoftEther VPN Client Deployment

A lightweight Docker image for running SoftEther VPN Client with automatic connection management, DHCP provisioning, route preservation, health monitoring, and self-healing recovery.

## Features

* Connects to any SoftEther VPN server
* Automatic DHCP configuration for the virtual VPN interface
* VPN server route pinning to preserve the control channel
* Optional VPN default route enforcement
* Policy-based routing to preserve original uplink connectivity
* Stateful VPN lifecycle management
* Route-aware health monitoring
* Automatic local recovery before reconnecting
* Persistent state reporting via `/run/vpn.state`
* Configurable logging levels (`INFO` / `DEBUG`)
* Works in both bridge and host networking modes

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

| Variable                     | Required | Default | Description                                                     |
| ---------------------------- | -------- | ------- | --------------------------------------------------------------- |
| `SE_SERVER`                  | yes      | –       | VPN server address (`host:port`)                                |
| `SE_HUB`                     | yes      | –       | VPN hub name                                                    |
| `SE_NICNAME`                 | yes      | –       | Virtual adapter name                                            |
| `SE_USERNAME`                | yes      | –       | VPN username                                                    |
| `SE_PASSWORD`                | yes      | –       | VPN password                                                    |
| `SE_DEFAULTROUTE`            | no       | unset   | Force default route through VPN                                 |
| `LOG_LEVEL`                  | no       | `INFO`  | Log verbosity (`INFO` or `DEBUG`)                               |
| `PING_INTERVAL`              | no       | `10`    | Health check interval (seconds)                                 |
| `PING_TIMEOUT`               | no       | `3`     | Gateway ping timeout (seconds)                                  |
| `RECONNECT_DELAY`            | no       | `5`     | Delay before reconnect attempts                                 |
| `MAX_CONNECT_WAIT`           | no       | `60`    | VPN connection timeout                                          |
| `INITIAL_STABILIZE_TIMEOUT`  | no       | `180`   | Tunnel stabilization timeout                                    |
| `INITIAL_STABILIZE_INTERVAL` | no       | `10`    | Tunnel stabilization check interval                             |
| `HEALTH_FAILURE_THRESHOLD`   | no       | `3`     | Consecutive health check failures before entering recovery mode |

## State Machine

The client operates as a finite-state machine:

* `CONNECT` – establish VPN session
* `STABILIZE` – acquire DHCP configuration and validate tunnel readiness
* `HEALTHY` – normal operation and continuous health monitoring
* `DEGRADED` – attempt local recovery
* `RECONNECT` – reconnect after unrecoverable failure

Current state is written to:

```text
/run/vpn.state
```

## Health Monitoring

Health checks validate:

* VPN session status
* Presence of the VPN interface
* Assigned VPN IP address
* VPN gateway reachability
* VPN default route integrity (when `SE_DEFAULTROUTE` is enabled)

A single failure does not trigger recovery.

After `HEALTH_FAILURE_THRESHOLD` consecutive failures:

1. The client enters the `DEGRADED` state.
2. Local recovery is attempted:

   * restore pinned VPN server route;
   * restore VPN default route if missing;
   * renew DHCP configuration if required.
3. Only if recovery fails does the client reconnect the VPN session.

This approach avoids unnecessary reconnects caused by temporary routing issues.

## Routing Behaviour

When `SE_DEFAULTROUTE` is enabled:

* VPN traffic becomes the default route.
* The VPN server route remains pinned to the original uplink.
* Policy routing preserves direct access from the container to the original gateway.
* Missing VPN routes can be restored automatically without reconnecting.

## Logging

Default logging level:

```bash
LOG_LEVEL=INFO
```

Verbose diagnostics:

```bash
LOG_LEVEL=DEBUG
```