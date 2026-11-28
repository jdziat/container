# Docker → container migration

Complete command mapping. Verified against `container --help` and each group's `--help`.
When a flag matters, confirm with `container <command> --help` rather than assuming Docker's
spelling.

## Containers

| Docker | container | Notes |
|---|---|---|
| `docker run` | `container run` | |
| `docker create` | `container create` | |
| `docker start` | `container start` | |
| `docker stop` | `container stop` | |
| `docker kill` | `container kill` | |
| `docker rm` | `container delete` / `rm` | |
| `docker exec` | `container exec` | |
| `docker logs` | `container logs` | |
| `docker cp` | `container copy` / `cp` | `container:path` on either side |
| `docker export` | `container export` | |
| `docker inspect` | `container inspect` | also the way to find a container's IP |
| `docker stats` | `container stats` | |
| `docker ps` | `container list` / `ls` / `ps` | add `-a` for stopped containers |
| `docker container prune` | `container prune` | |
| `docker commit` | `container commit <id> <image>` | creates an image from the container's filesystem; a running container is snapshotted first |
| `docker restart` | `container restart` | |
| `docker wait` | `container wait` | prints one exit code per running container |
| `docker port` | `container port` | prints `<host address>:<host port>:<container port>/<proto>` |
| `docker attach` | `container attach` | streams logs from the current end and waits for exit; stdin to already-running init is not rebindable — use `exec -it` |
| `docker top` | — | `container exec <id> ps aux` |
| `docker rename` | `container rename` | Name≠Id: Id is UUID; `--name` / `rename` set Name |
| `docker pause`, `unpause` | `container pause` / `unpause` | per-container VM suspend/resume |
| `docker diff` | `container diff` | A/C/D vs image snapshot |
| `docker update` | `container update` | `--cpus`, `--memory`, `--restart` |

`--restart` on `run`/`create` accepts `no|on-failure[:max]|always|unless-stopped` (crash restart uses exponential backoff).
`--health-cmd` (plus `--health-interval`/`--health-timeout`/`--health-start-period`/`--health-retries`)
configures a guest probe loop that updates inspect `healthStatus`.
Full status: `docs/parity-matrix.md`.

## Images

| Docker | container |
|---|---|
| `docker build` | `container build` |
| `docker images` | `container images` / `container image list` / `ls` |
| `docker pull` | `container image pull` |
| `docker push` | `container image push` |
| `docker rmi` | `container image delete` / `rm` |
| `docker tag` | `container image tag` |
| `docker save` | `container image save` |
| `docker load` | `container image load` |
| `docker image inspect` | `container image inspect` |
| `docker image prune` | `container image prune` |
| `docker history` | `container image history` | |

`container image` has the alias `i`. Top-level `container images` lists images (same as
`image list`); it is not a plural parent that requires `images ls`.

`--net` is accepted as an alias for `--network` on `run` / `create`.

### Build notes

`container build` covers the BuildKit features people reach for most: `--platform`,
`--target`, `--build-arg`, `--secret`, `--no-cache`, `-f`, and `-o/--output` with
`type=oci|tar|local`.

Two differences worth knowing:

- `-t` is effectively required. The default tag is a freshly generated UUID, so a build
  without `-t` produces an image you then have to hunt for in `container image ls`.
- Builds execute in a builder container managed by `container builder`. It starts on demand,
  but when a build fails for no clear reason, check `container builder status`. Give it more
  room with `container builder start --cpus 8 --memory 16g`.

## Registries, volumes, networks

| Docker | container |
|---|---|
| `docker login` / `logout` | `container registry login` / `logout` |
| — | `container registry list` — shows current logins |
| `docker volume create` / `ls` / `rm` / `inspect` / `prune` | `container volume create` / `list` / `delete` / `inspect` / `prune` |
| `docker network create` / `ls` / `rm` / `inspect` / `prune` | `container network create` / `list` / `delete` / `inspect` / `prune` |
| `docker network connect` / `disconnect` | `container network connect` / `disconnect` | Running containers auto-restart on a stock build; live NIC hotplug exists only in `CONTAINER_VMM_CR=1` builds; `--restart` still accepted for compatibility |

## System

| Docker | container |
|---|---|
| `docker info` | `container system status` |
| `docker version` | `container system version` |
| `docker system df` | `container system df` |
| daemon logs | `container system logs` |
| `docker events` | `container events` | JSON lines for create/start/die/destroy |
| `docker system prune` | `container system prune` | `--all`, `--volumes`; individual prunes still exist |

Engine API bridge is **`done`** (curated support matrix including networks/volumes/`POST /build`).
Recipe B (`--socket /var/run/docker.sock` or `scripts/install-engine-sock.sh`) is the
**first-class** path for sock consumers; Recipe A (Application Support sock) remains the
default coexistence path. Docker CLI compatibility for the documented subset is **`done`** via `bin/docker` (unsupported verbs exit 2 with an alternative)
(shim from `scripts/docker`) plus top-level aliases (`images`, `pull`, `push`, `rmi`,
`login`, `logout`, `info`, `ps`, `--net`, `--hostname`). Routes outside
`docker-api-bridge support` return HTTP 501 by design. See `docs/parity-matrix.md` and
`docs/docker-job-catalog.md` (job freeze + socket recipes).

True residuals (not unfinished bridge work): `network connect` on a running container needs
connect/disconnect auto-restart (F4 interim); Compose `devices` is unrestricted by default (`CONTAINER_DEVICE_ALLOWLIST_ONLY=1` restores the allowlist); Swarm `wontfix`; `extends` and preferred NFS kernel are beyond-terminus Done;
preflight with `container compose doctor` before `up` on Desktop migrants; Compose
`domainname` is `done (interim)` (label only).

## Socket recipes (Engine clients)

Prefer coexistence: default Application Support sock + `DOCKER_HOST` or a Docker context.
Do not treat auto-symlink of `/var/run/docker.sock` as required for parity.

**Recipe A — Application Support:**

```bash
container-docker-api-bridge serve --socket ~/Library/Application\ Support/com.apple.container/docker-api-bridge.sock
export DOCKER_HOST=unix://$HOME/Library/Application\ Support/com.apple.container/docker-api-bridge.sock
```

**Recipe B — privileged `/var/run/docker.sock`:**

```bash
sudo ./scripts/install-engine-sock.sh
# or: sudo container-docker-api-bridge serve --socket /var/run/docker.sock
export DOCKER_HOST=unix:///var/run/docker.sock
```

**Recipe C — Docker context** (absolute `unix://` host; IDE runners need the same env/context):

```bash
SOCK="$HOME/Library/Application Support/com.apple.container/docker-api-bridge.sock"
docker context create container-bridge --docker "host=unix://${SOCK}"
docker context use container-bridge
```

**Testcontainers extras (document-only):** set `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` when
Ryuk must see a guest-visible sock path; optional `TESTCONTAINERS_HOST_OVERRIDE` for published
ports; `TESTCONTAINERS_RYUK_DISABLED=true` if privileged Ryuk is out of scope.

**Dev Containers extras (document-only):** set `DOCKER_HOST` / Docker context in
`containers.environment` (or the shell that launches the CLI). docker-outside-of-docker
defaults to host `/var/run/docker.sock` — use Recipe B or custom mounts to the Application
Support sock. This is not a zero-config Desktop claim.

Full write-up: `docs/docker-job-catalog.md#socket-recipes`.

## Replacing a compose file

Two paths:

1. **Plugin (preferred when installed):** `Sources/Plugins/ContainerCompose` installs as the
   `compose` plugin (`container compose up|down|ps|logs|exec|run|build|config`). It follows
   Docker Compose v2 single-engine shapes: project network + declared networks/volumes,
   long-form ports/volumes, `build:`, `env_file`, labels, file-based configs/secrets, and
   guest NFS (`type: nfs` / `driver: nfs`). Fail-closes on unknown keys. See
   `docs/compose-support-matrix.md` and `make compose-parity`.
2. **Shell script:** translate the file by hand with `container run` as below.

On the `default` network, use domain-qualified names after DNS setup. On a **custom**
network, bare names land in `/etc/hosts` (+ hosts-dns) and refresh on join/leave
([apple/container#1809](https://github.com/apple/container/issues/1809); matrix `done`).

Set up name resolution once when staying on `default` (all three steps — see SKILL.md):

```bash
# [dns] domain = "test" in ~/.config/container/config.toml
container system stop && container system start
sudo container system dns create test
```

Then translate the file. This compose file:

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: secret
  web:
    image: my-app:latest
    ports: ["8080:80"]
    environment:
      DATABASE_URL: postgres://postgres:secret@db:5432/postgres
    depends_on: [db]
```

becomes (custom network + bare name):

```bash
#!/bin/bash
set -euo pipefail

# One-shot stack up (not a destructive rerun). Tear down explicitly when needed:
#   container stop web db; container delete web db; container network delete appnet
if ! container network inspect appnet >/dev/null 2>&1; then
  container network create appnet
fi
# --name is the bare hostname written into peers' /etc/hosts; no alias= needed
container run -d --name db --network appnet \
  -e POSTGRES_PASSWORD=secret \
  --restart unless-stopped \
  postgres:16

# Wait for db readiness before creating web (compose plugin can do service_healthy instead).
# `container run -d` can return before inspect shows running; keep waiting on empty/stopped
# during startup. Only treat stopped as fatal after we have observed running once.
# Inspect encodes runtime status under status.state (ContainerStatus.state).
saw_running=0
ready=0
for _ in $(seq 1 60); do
  status="$(container inspect db 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); s=d[0].get("status",{}); print(s.get("state") or s.get("status") or "")' 2>/dev/null || true)"
  if [[ "${status}" == "running" ]]; then
    saw_running=1
  elif [[ "${saw_running}" -eq 1 && "${status}" == "stopped" ]]; then
    echo "db container is not running (status=${status})" >&2
    exit 1
  fi
  # Require two consecutive successes so a transient pg_isready blip does not pass.
  if container exec db pg_isready -q 2>/dev/null; then
    sleep 1
    if container exec db pg_isready -q 2>/dev/null; then
      ready=1
      break
    fi
  fi
  sleep 1
done
if [[ "${ready}" -ne 1 ]]; then
  echo "db not ready after 60s" >&2
  exit 1
fi

container run -d --name web --network appnet -p 8080:80 \
  -e DATABASE_URL=postgres://postgres:secret@db:5432/postgres \
  my-app:latest
```

Teardown:

```bash
container stop web db
container delete web db
container network delete appnet
```

Mapping notes:

- `depends_on` with `condition: service_healthy` is honored by the compose plugin; bare lists
  wait for start order only.
- On a custom network, bare service names resolve via `/etc/hosts` (refreshed on join/leave).
  On `default`, prefer `<name>.<domain>` (`db.test`).
- `ports:` → `-p`. Often unnecessary between containers, since each container has its own IP
  and is reachable without publishing. You need `-p` to reach a service from a host browser or
  a macOS-native tool.
- `volumes:` → `-v` / `--mount` for bind, named volume, tmpfs, or NFS. Named project volumes
  are created on `compose up`; NFS volumes become `--mount type=nfs,...` (guest client).
- `build:` → `container build` (also `compose build` / automatic on `compose up`).
- `restart:` → pass `--restart <policy>` on each `container run` (the compose plugin forwards
  `restart:` the same way). Policies: `no`, `on-failure[:max]`, `always`, `unless-stopped`.
- `healthcheck:` → translated to `--health-cmd*` by the compose plugin.
- NFS: `--mount type=nfs,source=<export>,destination=<path>,addr=<server>[,nfsvers=…]`
  matches Docker; see `docs/volumes.md#nfs-mounts`.

## Features with no Docker counterpart

- `container machine` — a full Linux environment with your home directory mapped in. See
  `container-machines.md`.
- `container run --publish-socket <host_path:container_path>` — publish a Unix socket to the
  host rather than a TCP port.
- `container run --ssh` — forward your SSH agent socket into the container.
- `container run --virtualization` — expose virtualization to the container for nested use.
- `container run --rosetta` — run x86-64 binaries on Apple silicon.
- `container system kernel` — manage the kernel containers boot with.
