# Docker API Bridge Plugin (Packet 6)

This plugin is the **out-of-core** path for Docker Engine API clients (Testcontainers, Dev Containers, Wrangler).

## Non-goals

- Not part of `container-apiserver`
- Not a full Engine API implementation
- Does not bind `/var/run/docker.sock` inside the Apple API server

## Status

Curated subset over a Unix socket. Print the matrix with:

```bash
container-docker-api-bridge support
```

Serve:

```bash
container-docker-api-bridge serve --socket ~/Library/Application\ Support/com.apple.container/docker-api-bridge.sock
export DOCKER_HOST=unix://$HOME/Library/Application\ Support/com.apple.container/docker-api-bridge.sock
```

## Supported routes

| Method | Path | Notes |
|--------|------|-------|
| GET/HEAD | `/_ping` | Health |
| GET | `/version`, `/info` | Static identity |
| GET | `/containers/json` | List |
| GET | `/containers/{id}/json` | Inspect (includes health when configured) |
| GET | `/containers/{id}/logs` | Stdio log file |
| POST | `/containers/{id}/start` | Bootstrap + start |
| POST | `/containers/{id}/stop` | Stop |
| POST | `/containers/{id}/kill` | SIGKILL |
| POST | `/containers/{id}/wait` | Wait for exit |
| DELETE | `/containers/{id}` | Force delete |
| GET | `/images/json` | Local images |

All other routes return **HTTP 501** with a stable JSON `message`. Create/build/exec/events/networks/volumes remain CLI or community-bridge territory for now.

For a broader Engine surface today, see [Socktainer](https://podman-desktop.io/blog/apple-container-extension).
