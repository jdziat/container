# Docker job catalog (ex-Swarm)

> **Under re-verification (2026-11-25).** The "achieved" and "shipped" statements below
> were produced by harnesses that mostly `grep` source text and that no CI job ran. An audit
> against the built binaries found real gaps and several claims the code could not back; see
> [plans/2026-11-24-parity-remediation.plan.md](plans/2026-11-24-parity-remediation.plan.md).
> Behavioral evidence now lives in `make parity-behavioral`
> (`scripts/parity/cli-surface.sh`, `t2-docker-corpus.sh`, `t2-bridge-*.sh`). Where this page and
> [parity-matrix.md](parity-matrix.md) disagree, the matrix is current.

This page defines the target **job catalog** for `container` on Mac (it is no longer a parity claim; see the banner):
a finished **job catalog**, not bit-identical Engine or Docker Desktop density.

**Status: withdrawn (2026-11-25).** The 2026-11-19 "achieved" declaration is not supported by
behavioral evidence and must not be quoted. The jobs below remain the target; see the banner above.

Scoreboard detail lives in [parity-matrix.md](parity-matrix.md). Compose keys:
[compose-support-matrix.md](compose-support-matrix.md). Strategy PRD:
[plans/2026-11-19-job-catalog-docker-parity.prd.md](plans/2026-11-19-job-catalog-docker-parity.prd.md).
CTO language bounds:
[plans/cto-full-parity-dns-engine-cli-2026-11-18.md](plans/cto-full-parity-dns-engine-cli-2026-11-18.md).
Achievement stamp:
[plans/cto-job-catalog-parity-achieved-2026-11-19.md](plans/cto-job-catalog-parity-achieved-2026-11-19.md).
After freeze (productization packs, not catalog reopen):
[plans/2026-11-19-post-freeze-parity-productization.prd.md](plans/2026-11-19-post-freeze-parity-productization.prd.md).
CTO productization stamp:
[plans/cto-post-freeze-productization-2026-11-20.md](plans/cto-post-freeze-productization-2026-11-20.md).
Expansion Pack C gate:
[plans/expansion-pack-template.md](plans/expansion-pack-template.md).
Support terminus (SKU + CR carrier + packs + loud edges):
[parity-terminus-support.md](parity-terminus-support.md).

## Freeze rule

After the jobs below are green under their harnesses and docs match the matrix:

- Further Engine routes are **opt-in expansions** with harness evidence — not implied debt.
- HTTP **501** outside `docker-api-bridge support` is **success** (product surface).
- Structural `wontfix` / `done (interim)` rows stay loud edges, not unfinished catalog debt.
- Swarm and a Moby-in-VM second lane remain **out of scope**.
  Host devices are unrestricted by default (allowlist opt-in) and in-core
  `/var/run/docker.sock` is on by default (opt-out `CONTAINER_INCORE_DOCKER_SOCK=0`). Live NIC hotplug
  exists only in `CONTAINER_VMM_CR=1` builds.

## Jobs

| ID | User outcome | Matrix rows | Harness | Loud edge |
|----|--------------|-------------|---------|-----------|
| J1 | Core single-container loop (pull, run, list, exec, delete) | Lifecycle / images `done` | `scripts/parity/t0-core-loop.sh` | — |
| J2 | Multi-service stack with bare-name DNS on a custom network | Network DNS `done`; Compose plugin `done` | `scripts/parity/t1-stack-smoke.sh` (`PARITY_STRICT_DNS=1` for nslookup); `make compose-parity` / `scripts/parity/t3-compose-corpus.sh` | Compose `devices` unrestricted by default (allowlist opt-in); Swarm `wontfix`; `deploy` dialect subset + `extends` `done`; `domainname` done |
| J3 | `docker …` day loop via shim | Docker-style CLI `done` for the documented subset | `scripts/parity/t2-docker-shim.sh` | Not flag-identical Desktop; Swarm verbs `wontfix` |
| J4 | Curated Engine API over plugin sock | Engine bridge + sock rows `done` | `scripts/parity/t2-bridge-e2e.sh` | Outside printed support matrix → 501 by design; create/exec practical subsets |

Harnesses need Apple silicon, macOS 26, and `container system start`.

## Socket recipes

Default socket stays under Application Support so other engines can coexist. Prefer
`DOCKER_HOST` or a Docker context. Do **not** require an auto-symlink to
`/var/run/docker.sock` for catalog completion. Always use an absolute `unix://` URL;
GUI/IDE processes often do not inherit interactive shell exports.

### Recipe A — Application Support + `DOCKER_HOST`

```bash
container-docker-api-bridge serve --socket ~/Library/Application\ Support/com.apple.container/docker-api-bridge.sock
export DOCKER_HOST=unix://$HOME/Library/Application\ Support/com.apple.container/docker-api-bridge.sock
```

### Recipe B — first-class privileged `/var/run/docker.sock` (sock consumers)

Preferred install path (F5):

```bash
sudo ./scripts/install-engine-sock.sh
# or packaged: sudo install-container-engine-sock
export DOCKER_HOST=unix:///var/run/docker.sock
```

Equivalent manual / env forms:

```bash
sudo container-docker-api-bridge serve --socket /var/run/docker.sock
# or:
sudo container-docker-api-bridge serve --privileged-sock
# or:
CONTAINER_ENGINE_SOCK=/var/run/docker.sock sudo -E container-docker-api-bridge serve
export DOCKER_HOST=unix:///var/run/docker.sock
```

Requires bind permission; socket mode `0600`. Prefer this when a tool or Compose
service hardcodes `/var/run/docker.sock` (Traefik-shaped mounts, docker-outside-of-docker).

**In-core default (R3):** apiserver spawns the bridge with `--privileged-sock` by default
(`enginePrivilegedSock = true`). Set `CONTAINER_INCORE_DOCKER_SOCK=0` or
`enginePrivilegedSock = false` to opt out. When enabled, apiserver spawns the
bridge with `--privileged-sock`. Requires privileges to bind `/var/run`; bind failure
is logged and the process continues with the Application Support sock.

### Recipe C — Docker context

```bash
SOCK="$HOME/Library/Application Support/com.apple.container/docker-api-bridge.sock"
docker context create container-bridge --docker "host=unix://${SOCK}"
docker context use container-bridge
```

A manual `ln -sf … /var/run/docker.sock` can break other Docker servers on the same Mac;
prefer the in-core default or Recipe B install script.

### Testcontainers extras (document-only)

- `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` when Ryuk must mount a path visible inside its guest
- Optional `TESTCONTAINERS_HOST_OVERRIDE` when published-port discovery needs the Mac/VM address
- `TESTCONTAINERS_RYUK_DISABLED=true` when privileged Ryuk is out of scope

These are recipes, not a claim that zero-config Desktop discovery always works.

### Dev Containers extras (document-only)

- Set `DOCKER_HOST` or Docker context via `containers.environment` / launch shell
- docker-outside-of-docker often expects host `/var/run/docker.sock` — use Recipe B or custom
  mounts to the Application Support sock

### Density note

Per-container VMs and partial Virtualization memory ballooning mean dense memory-heavy
stacks may need occasional restarts to reclaim host RAM. That is an architecture limit, not
a missing CLI verb. See [technical-overview.md](technical-overview.md).

## Loud edges (same story everywhere)

| Edge | Behavior | Status |
|------|----------|--------|
| Route outside `docker-api-bridge support` | HTTP 501 JSON pointing at `support` | By design |
| `network connect` / `disconnect` while running | CR: virtio-net hotplug when available (`CONTAINER_NET_HOTPLUG=1` or CR backend); VZ / disconnect: auto-restart | `done (deepened)` |
| Compose `devices` | Unrestricted char/block (opt-out `CONTAINER_DEVICE_ALLOWLIST_ONLY=1`) | `done` |
| Swarm / `deploy` / pods / Quadlet | Not offered | `wontfix` |
| Exact DNS aliases | Unique **per network** (L3); same alias on different networks is OK; same-network clash fails at create / doctor WARN | Loud edge (resolved dialect) |
| Named volume RW multi-attach | Single-writer block device per VM | Loud edge |
| Guest NFS without NFS kernel | Fail closed; `make install-nfs-kernel` | Pack A alternate |
| Compose loud-edge preflight | `container compose doctor` (optional `--strict`) | Pack B |

## Declaration checklist

Evidence recorded **2026-11-19** (this tree). Re-run before a release if binaries or matrices change.

- [x] J1: `scripts/parity/t0-core-loop.sh` exits 0
- [x] J2: `PARITY_STRICT_DNS=1 scripts/parity/t1-stack-smoke.sh` and `make compose-parity` exit 0 (incl. `06-nfs`)
- [x] J3: `scripts/parity/t2-docker-shim.sh` exits 0
- [x] J4: `scripts/parity/t2-bridge-e2e.sh` exits 0
- [x] Honesty: bridge README, `skills/container/SKILL.md`, and `skills/container/references/docker-migration.md` agree with this catalog and [parity-matrix.md](parity-matrix.md) on CLI / bridge / DNS / `/build` (no “build out of scope” or “bridge interim” drift)
- [x] Recipe links: this page’s Recipe A/B/C appear in the bridge README and migration skill
- [x] Probe an outside-matrix Engine route → HTTP 501 with stable JSON (e.g. `POST /containers/{id}/attach` → 501 + curated-contract message; Swarm is not supported and also returns 501)
- [x] Running `container network connect` without `--restart` uses CR hotplug when available; else auto-restarts (F4 deepened)
- [x] Compose `devices` unrestricted (R2; allowlist opt-out)

Optional client smokes (Testcontainers / Dev Containers) remain optional until a separate scoped claim promotes them beyond document-only recipes.
