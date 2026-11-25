# Docker and Podman parity matrix

This is the one place where `container` documents how its commands line up with Docker and Podman. It measures **workflow parity**: whether a job you do with Docker or Podman on a Mac can be finished with `container`.

An expanded parity track covers Docker CLI drop-in ([#79](https://github.com/apple/container/issues/79); `bin/docker` shim + aliases), a curated Engine API bridge ([#66](https://github.com/apple/container/issues/66)), and lifecycle/network commands that were previously `wontfix`. Treat each row's status literally. Swarm / Podman-only surfaces remain `wontfix`.

When a command is missing or behaves differently, this page says so. If a row is `wontfix`, `container` does not claim parity for it.

For flag-level detail, see the [command reference](command-reference.md). For a short mapping aimed at agents and scripts, see `skills/container/references/docker-migration.md`.

## Status values

| Status | Meaning |
|--------|---------|
| `done` | A `container` command does the same job. Check `--help` for flag differences. |
| `done (interim)` | Shipped for the scoped job with a documented limitation in the same row (for example hosts injection pending full network DNS). This is a shipped status, not transitional: a scoped GO may include it. It is not a claim of the long-term end state. |
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
| `run` | `container run` | `done` | Common flags match: `-d`, `--rm`, `--name`, `-e`, `-p`, `-v`, `-m`, `-c`, `-it`, `--add-host`, `--sysctl`, `--stop-signal`, `--cap-add/--cap-drop`, `--device`. Docker flags the per-VM model cannot honor are **accepted with one warning** and have no effect: `--privileged`, `--security-opt`, `--pids-limit`, `--expose`, `--pid`, `--ipc`, `--log-driver`, `--gpus`. Not accepted: `--mac-address` (use `--network ...,mac=`). |
| `create` | `container create` | `done` | |
| `start` | `container start` | `done` | `start -a` on an already-running container streams logs and waits for exit (see `attach`). |
| `stop` | `container stop` | `done` | |
| `kill` | `container kill` | `done` | |
| `rm` | `container delete` / `container rm` | `done` | |
| `ps` | `container list` / `container ls` / `container ps` | `done` | `-a`, `-q`, `--format json\|table\|yaml\|toml` or a Go template (`'{{.Names}}\t{{.Status}}'`), and `--filter` (`status=` incl. Docker's `exited`, `name=`, `id=`, `label=`, `ancestor=`). Evidence: `scripts/parity/t2-docker-corpus.sh`. |
| `exec` | `container exec` | `done` | |
| `logs` | `container logs` | `done` | `-f`, `-n` / `--tail N`. `--since` / `--until` are not supported. Evidence: `t2-docker-corpus.sh`. |
| `cp` | `container copy` / `container cp` | `done` | |
| `export` | `container export` | `done` | |
| `inspect` | `container inspect` | `done` | `-f` / `--format` accepts a Go template (`'{{.Name}}'`, `'{{json .}}'`). Also the way to find a container's IP address. |
| `stats` | `container stats` | `done` | `--format` takes `json`/`table`/`yaml`/`toml` or a Docker-style Go template (`{{.Name}}`, `{{.CPUPerc}}`, `{{.MemUsage}}`, `{{.MemPerc}}`, `{{.NetIO}}`, `{{.BlockIO}}`, `{{.PIDs}}`); `--no-stream` supported. |
| `commit` | `container commit` | `done` | Creates an image from a container's filesystem. See [`container commit`](command-reference.md#container-commit). |
| `container prune` | `container prune` | `done` | |
| `restart` | `container restart` | `done` | Stops, then starts again. |
| `wait` | `container wait` | `done` | Prints the exit code of each running container, one per line. Only running containers can be waited on. |
| `port` | `container port` | `done` | Prints published ports as `<host address>:<host port>:<container port>/<proto>`. |
| `attach` | `container attach` | `done` | Streams logs from the current end and waits for exit; stdin to already-running init is not rebindable (use `exec -it`). |
| `top` | `container exec <id> ps aux` | `alias` | |
| `rename` | `container rename` | `done` | Docker-style Name≠Id: create always assigns a UUID Id; `--name` sets Name; `rename` changes Name. Commands resolve Id or Name. |
| `run --restart`, `create --restart` | `container run/create --restart` | `done` | Policies: `no`, `on-failure[:max]`, `always`, `unless-stopped`. Crash restart uses exponential backoff (250ms…60s); intentional `stop` sets a manual-stop marker for `unless-stopped`. |
| `run --health-cmd` and `HEALTHCHECK` | `container run/create --health-cmd` | `done` | Create-time contract + guest probe loop updates `healthStatus` (`starting`/`healthy`/`unhealthy`). Compose translates `healthcheck:` and waits on `depends_on: condition: service_healthy`. |
| `pause`, `unpause` | `container pause` / `unpause` | `done` | Suspends/resumes the per-container VM via Virtualization pause/resume. |
| `diff` | `container diff` | `done` | Compares the container rootfs EXT4 inventory to the image snapshot (A/C/D by path size+mtime). |
| `update` | `container update` | `done` | `--cpus`, `--memory`, `--restart`; resource changes apply on next start; restart policy is immediate. |

## Images

| Docker / Podman | `container` | Status | Notes and links |
|-----------------|-------------|--------|-----------------|
| `build` | `container build` | `done` | Supports `--platform`, `--target`, `--build-arg`, `--secret`, `--no-cache`, `-f`, and `-o`. Pass `-t`. |
| `images` | `container image list` / `container images` | `done` | Top-level `images` lists images (same as `image list`). |
| `pull` | `container image pull` | `done` | |
| `push` | `container image push` | `done` | |
| `rmi` | `container image delete` | `done` | |
| `tag` | `container image tag` | `done` | |
| `save`, `load` | `container image save`, `container image load` | `done` | |
| `image inspect` | `container image inspect` | `done` | |
| `image prune` | `container image prune` | `done` | |
| `history` | `container image history` | `done` | Prints OCI config history (newest first); `--format`, `--human` / `--no-human`. |

## Networks, volumes, registries, and system

| Docker / Podman | `container` | Status | Notes and links |
|-----------------|-------------|--------|-----------------|
| `network create`, `ls`, `rm`, `inspect`, `prune` | `container network create`, `list`, `delete`, `inspect`, `prune` | `done` | Requires macOS 26. |
| `network connect`, `disconnect` | `container network connect` / `disconnect` | `done (interim)` | Updates attachments in config; stopped containers apply on next start. Live NIC hotplug (no restart) exists only in builds made with `CONTAINER_VMM_CR=1`, which links the CRVirtualization fork of containerization (VZ spare-NIC slots and CR virtio-net hotplug). The stock build has no hotplug and restarts the container. |
| Bare service name on a custom network (`ping db`) | guest `/etc/hosts` + in-guest hosts-dns | `done` | Peers (and bare `alias=`) are written into `/etc/hosts` at bootstrap and refreshed on join/leave. Init is wrapped with `libexec/container/helpers/hosts-dns` so `nslookup` and getaddrinfo both resolve peers on UDP/53 (`127.0.0.1`), forwarding other queries to the gateway. Evidence: `PARITY_STRICT_DNS=1 scripts/parity/t1-stack-smoke.sh`. Domain-qualified names on `default` still work via `container system dns create`. |
| `volume create`, `ls`, `rm`, `inspect`, `prune` | `container volume create`, `list`, `delete`, `inspect`, `prune` | `done` | |
| `--mount type=nfs` / Compose `type: nfs` / `driver: nfs` | Guest NFS (`Filesystem.FSType.nfs` → guest `mount -t nfs`) | `done` | Docker-shaped mounts; runtime rewrites `addr=`+export → `server:/export` and defaults `nolock`. Validated e2e against in-guest `nfsd` (`scripts/parity/nfs-guest-server.sh`) on the Containerization NFS-enabled kernel (`vmlinux-arm64` / `6.18.5-cz-*`). See [volumes.md](volumes.md#nfs-mounts). |
| `login`, `logout` | `container registry login`, `logout` | `done` | |
| `info` | `container system status` | `done` | |
| `version` | `container system version` | `done` | |
| `system df` | `container system df` | `done` | |
| `system prune` | `container system prune` | `done` | Also keeps the four individual prunes. Flags: `--all` (unused images), `--volumes`. |
| `events` | `container events` | `done` | Streams JSON lines for create/start/die/destroy/rename/pause/unpause/update/connect/disconnect from the API-server event bus. |

## Compose, Engine API, and ecosystem tools

| Docker / Podman | `container` | Status | Notes and links |
|-----------------|-------------|--------|-----------------|
| `compose up`, `down`, `ps`, `logs`, `exec`, `run`, `build`, `config` | `container compose` plugin (`Sources/Plugins/ContainerCompose`) | `done` | Docker Compose v2–shaped single-engine subset; fail closed on unknown keys. Long-form ports/volumes, project volumes/networks, `build:`, `env_file`, labels, file configs/secrets, guest NFS; `devices` unrestricted by default (allowlist opt-in). Corpus: `make compose-parity` / `scripts/parity/t3-compose-corpus.sh`. Key matrix: [compose-support-matrix.md](compose-support-matrix.md). |
| Docker Engine API on `/var/run/docker.sock` | `docker-api-bridge` plugin | `done` | In-core bind is **on by default** (`enginePrivilegedSock = true`); opt out with `CONTAINER_INCORE_DOCKER_SOCK=0`. Bind failure is logged and the Application Support socket remains. Recipe B (`scripts/install-engine-sock.sh`, `--privileged-sock`) still applies when the in-core bind cannot get privileges. ([#66](https://github.com/apple/container/issues/66), [#1925](https://github.com/apple/container/issues/1925)) |
| Docker Engine API bridge for Testcontainers, Dev Containers, and similar | `docker-api-bridge` plugin | `done` | Curated Unix-socket Engine surface printed by `docker-api-bridge support`. Exec **streams stdout/stderr** in Docker's multiplexed frame format (no stdin/hijack). `/logs` returns the container's own output only, framed (non-TTY) or raw (TTY), with `tail=`. `/events` streams live events from now (or `since=`). `/containers/create` honors `NetworkMode` (named networks + aliases), `Dns`, `ExtraHosts`, `Sysctls`, `CapAdd/CapDrop`, `Devices`, `Tmpfs`, `ShmSize`, `Init`, `ReadonlyRootfs`, and **rejects with 400, naming the key,** any other non-default `HostConfig` value rather than ignoring it. Also `restart`, `tag`, and label-scoped `prune`. `images/{name}/push` and routes outside the matrix return 501. **Data-loss warning:** `POST /containers|volumes|networks/prune` with no `filters` removes *every* unused resource on the system (Docker's semantics). Pass `filters={"label":["k=v"]}` to scope it; any other filter key is a 400 so a typo cannot silently widen the prune. Evidence: `t2-bridge-streams.sh`, `t2-bridge-hostconfig.sh`, `t2-bridge-lifecycle.sh`. |
| Docker CLI drop-in compatibility | `bin/docker` shim + `container` aliases | `done` | `scripts/docker` installed as `bin/docker` (#79) maps `docker ...` to `container ...`: `info`, `version`, `rm`, `ps`, `top`, `images`, `rmi`, `tag`, `save`, `load`, `history`, `builder`, `compose`, plus `container`/`image` namespaces. Verbs with no equivalent (`search`, `import`, `context`, `buildx`, `swarm`, `service`, `stack`, `node`, `secret`, `config`) exit 2 with the nearest alternative. Real `docker` one-liners (47+ checks) run in `scripts/parity/t2-docker-corpus.sh`. |
| Docker Swarm | - | `wontfix` | Not supported. The bridge returns 501 for `/swarm/*` and `/services/*` and the `docker` shim exits 2 for `swarm`, `service`, `stack`, `node`, `secret`, `config`. (An in-memory stub that returned fake join tokens was removed 2026-11-25.) Compose `deploy` is `done (interim)` (`replicas` <= 3, `restart_policy.condition`); see [compose-support-matrix.md](compose-support-matrix.md). |

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
| T1 | Multi-service stack: network, named containers, name resolution | `scripts/parity/t1-stack-smoke.sh` | Available. Hosts injection + hosts-dns; `PARITY_STRICT_DNS=1` requires `nslookup` (not only getent). |
| T2 | Ecosystem tools through Docker API bridge + `docker` shim | `t2-docker-corpus.sh`, `t2-bridge-streams.sh`, `t2-bridge-hostconfig.sh`, `t2-bridge-lifecycle.sh` (behavioral; `make parity-behavioral`) | `done`: bridge create/exec/pause/unpause/changes/stats/top/rename/networks/volumes/images; shim pull/images/run/ps/exec/rm. |
| T3 | Lifecycle sugar: `restart`, `wait`, `port`, `attach` | CLI commands | `restart`/`wait`/`port`/`attach` done. |
| T3-compose | Compose corpus (up/down/config) + optional NFS | `scripts/parity/t3-compose-corpus.sh` / `make compose-parity` | Available. Set `COMPOSE_NFS_SERVER` + `COMPOSE_NFS_EXPORT` for fixture `06-nfs`. |
| T4 | Podman-shaped features | — | Not a goal. Use `machine` and `cluster`. |

## Keeping this page honest

- **Static checks are not evidence.** `scripts/parity/{f3,f4,f5,c3,l1,l2,l3,l4}*.sh` and their `make` targets only `grep` source or docs for symbols and comments. They pass when the build is broken. Do not cite them as proof a row is `done`; only `make parity-behavioral` and the unit tests are evidence.

- A row moves to `done` only when the command ships and is covered by a test or harness step.
- Docs and skills must not describe a `wontfix` row as supported. “Drop-in Docker” means the `bin/docker` shim + matrix `done` CLI/Engine rows, not Swarm or flag-identical Docker Desktop.
- If a command's status here disagrees with `docs/command-reference.md`, fix the disagreement in the same change.
- **Superseded 2026-11-25:** the 2026-11-19 "job-catalog parity achieved" stamp rested on source-grep harnesses that no CI job ran, and is withdrawn. The claim this page supports is narrower: a Docker-style CLI and a curated Engine API subset for common single-host workflows, with behavior evidenced by `make parity-behavioral`. See [the remediation plan](plans/2026-11-24-parity-remediation.plan.md). Do not say "parity achieved".
