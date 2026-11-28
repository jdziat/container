# Docker API Bridge Plugin

This plugin is the **out-of-core** path for Docker Engine API clients (Testcontainers, Dev Containers, Wrangler).

## Non-goals

- Not a full Engine API implementation
- Recipe A Application Support sock remains available alongside in-core `/var/run/docker.sock`
- In-core `/var/run/docker.sock` is **default on** (R3; `enginePrivilegedSock` / apiserver
  `--privileged-sock`). Opt out with `CONTAINER_INCORE_DOCKER_SOCK=0`

## Status

**Done** as a curated Engine bridge: the printed support matrix is the complete contract
([docs/parity-matrix.md](../../../docs/parity-matrix.md),
[docs/docker-job-catalog.md](../../../docs/docker-job-catalog.md)).
Create and exec are **practical subsets** (not bit-identical Engine shapes). Routes outside
the matrix return **HTTP 501** by design — that is the product surface, not unfinished work.

Print the matrix with:

```bash
container-docker-api-bridge support
```

## Socket recipes

Default socket stays under Application Support so other Docker engines can coexist. Prefer
`DOCKER_HOST` or a Docker context over owning `/var/run/docker.sock`. Full recipes (including
Testcontainers / Dev Containers extras): [docs/docker-job-catalog.md](../../../docs/docker-job-catalog.md#socket-recipes).

**Recipe A — Application Support + `DOCKER_HOST`:**

```bash
container-docker-api-bridge serve --socket ~/Library/Application\ Support/com.apple.container/docker-api-bridge.sock
export DOCKER_HOST=unix://$HOME/Library/Application\ Support/com.apple.container/docker-api-bridge.sock
```

Use an absolute `unix://` URL. Quote paths with spaces. GUI/IDE runners often do not inherit
shell exports — set the same value in the IDE environment or use Recipe C.

**Recipe B — first-class privileged `/var/run/docker.sock` (sock consumers):**

```bash
sudo ./scripts/install-engine-sock.sh
# equivalents:
sudo container-docker-api-bridge serve --socket /var/run/docker.sock
sudo container-docker-api-bridge serve --privileged-sock
CONTAINER_ENGINE_SOCK=/var/run/docker.sock sudo -E container-docker-api-bridge serve
export DOCKER_HOST=unix:///var/run/docker.sock
```

Requires permission to bind that path; the socket is mode `0600` (owner-only). Prefer this
when a tool hardcodes `/var/run/docker.sock`; still not the default Application Support story.

**In-core default (R3):** `container system start` spawns this bridge with `--privileged-sock` by
default (`enginePrivilegedSock = true`). Opt out with `CONTAINER_INCORE_DOCKER_SOCK=0`. Spawned from
apiserver. Fail soft if `/var/run` bind fails.

**Recipe C — Docker context:**

```bash
SOCK="$HOME/Library/Application Support/com.apple.container/docker-api-bridge.sock"
docker context create container-bridge --docker "host=unix://${SOCK}"
docker context use container-bridge
```

Do **not** auto-symlink to `/var/run/docker.sock` for “parity done”; a manual symlink can
break other engines on the same Mac.

## Supported routes

| Method | Path | Notes |
|--------|------|-------|
| GET/HEAD | `/_ping` | Health |
| GET | `/version`, `/info` | Static identity |
| GET | `/containers/json` | List |
| POST | `/containers/create` | Subset: Image, Cmd/Entrypoint, Env, Hostname/Name, WorkingDir, Labels, HostConfig Memory/NanoCpus/PortBindings/Binds/RestartPolicy/AutoRemove |
| GET | `/containers/{id}/json` | Inspect (includes health when configured) |
| GET | `/containers/{id}/logs` | Stdio log file |
| GET | `/containers/{id}/changes` | Diff vs image snapshot |
| GET | `/containers/{id}/stats` | One-shot JSON subset (no stream) |
| GET | `/containers/{id}/top` | Guest `ps` Titles/Processes; optional `ps_args` |
| POST | `/containers/{id}/start` | Bootstrap + start |
| POST | `/containers/{id}/stop` | Stop |
| POST | `/containers/{id}/kill` | SIGKILL |
| POST | `/containers/{id}/wait` | Wait for exit |
| POST | `/containers/{id}/pause` | Pause |
| POST | `/containers/{id}/unpause` | Unpause |
| POST | `/containers/{id}/rename` | Query `name=`; Id unchanged |
| POST | `/containers/{id}/exec` | ExecCreate subset (Cmd/Env/Tty/WorkingDir/User) |
| DELETE | `/containers/{id}` | Force delete |
| POST | `/exec/{id}/start` | Runs process; no hijack multiplex stream yet |
| GET | `/exec/{id}/json` | Exec inspect (Running/ExitCode) |
| GET | `/images/json` | Local images |
| POST | `/images/create` | Pull (`fromImage` query) |
| DELETE | `/images/{name}` | Delete |
| POST | `/build` | Curated: tar context + `t=` tag; streams JSON lines |
| GET | `/events` | Chunked JSON event stream |
| GET | `/networks`, `/networks/{id}` | List / inspect |
| POST | `/networks/create` | Create (nat / vmnet) |
| DELETE | `/networks/{id}` | Delete |
| GET | `/volumes`, `/volumes/{name}` | List / inspect |
| POST | `/volumes/create` | Create |
| DELETE | `/volumes/{name}` | Delete |

All other routes return **HTTP 501** with a stable JSON `message` pointing at
`docker-api-bridge support`. Widening the matrix is opt-in scoped work with harness evidence,
not implied debt.

For a broader Engine surface today, see [Socktainer](https://podman-desktop.io/blog/apple-container-extension).
