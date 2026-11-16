# Docker and Podman parity matrix

This is the one place where `container` documents how its commands line up with Docker and Podman. It measures **workflow parity**: whether a job you do with Docker or Podman on a Mac can be finished with `container`. It is not a promise of a Docker-compatible CLI or API. Docker's flags are not copied one for one ([apple/container#79](https://github.com/apple/container/issues/79)), and the Docker Engine API is not part of core ([apple/container#66](https://github.com/apple/container/issues/66)).

When a command is missing or behaves differently, this page says so. If a row is `wontfix`, `container` does not claim parity for it.

For flag-level detail, see the [command reference](command-reference.md). For a short mapping aimed at agents and scripts, see `skills/container/references/docker-migration.md`.

## Status values

| Status | Meaning |
|--------|---------|
| `done` | A `container` command does the same job. Check `--help` for flag differences. |
| `alias` | No dedicated command, but a documented one-liner or composition does the job. |
| `plugin` | Not in core by design. Provided or expected through the plugin architecture. |
| `wontfix` | Not planned in core. Includes features deferred until there is a design that fits the per-container VM model. |
| `blocked` | Wanted, but waiting on a design decision or an upstream dependency. The blocker is linked. |
| `in-progress` | Code is being added and has not shipped. Treat as unavailable until it is `done`. |
| `planned` | Scheduled in the parity plan, with no code yet. Treat as unavailable. |

`in-progress` and `planned` are transitional. A tier cannot be declared at parity while any row it depends on has one of these values.

## Container lifecycle

| Docker / Podman | `container` | Status | Notes and links |
|-----------------|-------------|--------|-----------------|
| `run` | `container run` | `done` | Common flags match: `-d`, `--rm`, `--name`, `-e`, `-p`, `-v`, `-m`, `-c`, `-it`. |
| `create` | `container create` | `done` | |
| `start` | `container start` | `done` | `start -a` on an already-running container streams logs and waits for exit (see `attach`). |
| `stop` | `container stop` | `done` | |
| `kill` | `container kill` | `done` | |
| `rm` | `container delete` / `container rm` | `done` | |
| `ps` | `container list` / `container ls` | `done` | Add `--all` for stopped containers. |
| `exec` | `container exec` | `done` | |
| `logs` | `container logs` | `done` | |
| `cp` | `container copy` / `container cp` | `done` | |
| `export` | `container export` | `done` | |
| `inspect` | `container inspect` | `done` | Also the way to find a container's IP address. |
| `stats` | `container stats` | `done` | |
| `commit` | `container commit` | `done` | Creates an image from a container's filesystem. See [`container commit`](command-reference.md#container-commit). |
| `container prune` | `container prune` | `done` | |
| `restart` | `container restart` | `done` | Stops, then starts again. |
| `wait` | `container wait` | `done` | Prints the exit code of each running container, one per line. Only running containers can be waited on. |
| `port` | `container port` | `done` | Prints published ports as `<host address>:<host port>:<container port>/<proto>`. |
| `attach` | `container attach` | `done` | Streams logs from the current end and waits for exit; stdin to already-running init is not rebindable (use `exec -it`). |
| `top` | `container exec <id> ps aux` | `alias` | |
| `rename` | — | `planned` | Optional. |
| `run --restart`, `create --restart` | `container run/create --restart` | `done` | Policies: `no`, `on-failure[:max]`, `always`, `unless-stopped`. Crash restart uses exponential backoff (250ms…60s); intentional `stop` sets a manual-stop marker for `unless-stopped`. |
| `run --health-cmd` and `HEALTHCHECK` | `container run/create --health-cmd` | `done` | Create-time contract + guest probe loop updates `healthStatus` (`starting`/`healthy`/`unhealthy`). Compose translates `healthcheck:` and waits on `depends_on: condition: service_healthy`. |
| `pause`, `unpause` | — | `wontfix` | Deferred until there is a design that fits the per-container VM model. |
| `diff` | — | `wontfix` | Deferred, same reason. |
| `update` | — | `wontfix` | |

## Images

| Docker / Podman | `container` | Status | Notes and links |
|-----------------|-------------|--------|-----------------|
| `build` | `container build` | `done` | Supports `--platform`, `--target`, `--build-arg`, `--secret`, `--no-cache`, `-f`, and `-o`. Pass `-t`. |
| `images` | `container image list` | `done` | |
| `pull` | `container image pull` | `done` | |
| `push` | `container image push` | `done` | |
| `rmi` | `container image delete` | `done` | |
| `tag` | `container image tag` | `done` | |
| `save`, `load` | `container image save`, `container image load` | `done` | |
| `image inspect` | `container image inspect` | `done` | |
| `image prune` | `container image prune` | `done` | |
| `history` | — | `wontfix` | |

## Networks, volumes, registries, and system

| Docker / Podman | `container` | Status | Notes and links |
|-----------------|-------------|--------|-----------------|
| `network create`, `ls`, `rm`, `inspect`, `prune` | `container network create`, `list`, `delete`, `inspect`, `prune` | `done` | Requires macOS 26. |
| `network connect`, `disconnect` | — | `wontfix` | Set `--network` when you run the container. |
| Bare service name on a custom network (`ping db`) | guest `/etc/hosts` injection | `done` (interim) | Peers on a shared custom network are written into `/etc/hosts` at bootstrap and refreshed on join/leave. Full network-scoped DNS (#1809) remains the long-term path. Domain-qualified names on `default` still work via `container system dns create`. |
| `volume create`, `ls`, `rm`, `inspect`, `prune` | `container volume create`, `list`, `delete`, `inspect`, `prune` | `done` | |
| `login`, `logout` | `container registry login`, `logout` | `done` | |
| `info` | `container system status` | `done` | |
| `version` | `container system version` | `done` | |
| `system df` | `container system df` | `done` | |
| `system prune` | `container prune`, `container image prune`, `container volume prune`, `container network prune` | `alias` | There is no single command. Run the four prunes. |
| `events` | — | `wontfix` | Deferred. Not needed for multi-service stacks. |

## Compose, Engine API, and ecosystem tools

| Docker / Podman | `container` | Status | Notes and links |
|-----------------|-------------|--------|-----------------|
| `compose up`, `down`, `logs` | `container compose` plugin (`Sources/Plugins/ContainerCompose`) | `plugin` | Curated subset; unsupported keys fail closed before run. Install under `libexec/container-plugins/compose`. Community alternatives remain: [#1846](https://github.com/apple/container/issues/1846), [discussion #194](https://github.com/apple/container/discussions/194). |
| Docker Engine API on `/var/run/docker.sock` | — | `wontfix` | Not in core: [#66](https://github.com/apple/container/issues/66). |
| Docker Engine API bridge for Testcontainers, Dev Containers, and similar | `docker-api-bridge` plugin | `plugin` | Curated Unix-socket subset (`/_ping`, containers list/inspect/logs/start/stop/kill/wait/delete, images list); create/build/exec return 501. Use Socktainer for a fuller Engine surface: [#1925](https://github.com/apple/container/issues/1925). |
| Docker CLI flag-for-flag compatibility | — | `wontfix` | [#79](https://github.com/apple/container/issues/79). |
| Docker Swarm | — | `wontfix` | |

## Podman

| Podman | `container` | Status | Notes and links |
|--------|-------------|--------|-----------------|
| `machine init`, `start`, `ls`, `stop`, `rm` | `container machine create`, `run`, `list`, `stop`, `delete` | `done` | A full Linux environment with your home directory mapped in. See [container machines](container-machine.md). |
| `generate kube`, `play kube` | `container cluster` | `alias` | Covers the local Kubernetes job, not the Podman command surface. See [cluster](cluster.md). |
| `pod` | — | `wontfix` | Use `container machine` or `container cluster`. Pod-like grouping is only reconsidered if the other rows leave a measured gap. |
| Quadlet (systemd units) | — | `wontfix` | |
| Podman-specific CLI flags | — | `wontfix` | |

## Parity tiers and harness

The scripts under `scripts/parity/` check the claims above against a running system. They need Apple silicon, macOS 26, and `container system start`.

| Tier | Meaning | Harness | Status |
|------|---------|---------|--------|
| T0 | Core single-container loop: pull, run, list, exec, delete | `scripts/parity/t0-core-loop.sh` | Available |
| T1 | Multi-service stack: network, named containers, name resolution | `scripts/parity/t1-stack-smoke.sh` | Available. Interim hosts injection covers compose-ordered peers; set `PARITY_STRICT_DNS=1` for hard failures. |
| T2 | Ecosystem tools through an external Docker API bridge | plugin subset | Curated Engine API subset on a Unix socket (`Sources/Plugins/DockerAPIBridge`); create/build/exec still 501. |
| T3 | Lifecycle sugar: `restart`, `wait`, `port`, `attach` | CLI commands | `restart`/`wait`/`port`/`attach` done. |
| T4 | Podman-shaped features | — | Not a goal. Use `machine` and `cluster`. |

## Keeping this page honest

- A row moves to `done` only when the command ships and is covered by a test or harness step.
- Docs and skills must not describe a `wontfix` row as supported. Do not use "drop-in Docker" language for them.
- If a command's status here disagrees with `docs/command-reference.md`, fix the disagreement in the same change.
