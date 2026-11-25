# PRD: Beyond-terminus goals (ex-OpenAPI, ex-Swarm)

_Date: 2026-11-21_  
_Status: implementing (CTO GO-WITH-CONDITIONS)_  
CTO: [cto-beyond-terminus-go-2026-11-21.md](cto-beyond-terminus-go-2026-11-21.md),
[wave validation](cto-beyond-terminus-wave-validation-2026-11-21.md),
[wave recheck](cto-beyond-terminus-wave-recheck-2026-11-21.md).

## Permanent non-goals

- Full Engine OpenAPI; Swarm; bit-identical Desktop

## Reopened (2026-11-21) — see [reopen-supported-surfaces](2026-11-21-reopen-supported-surfaces.prd.md)

- R1 VZ live NIC hotplug · R2 unrestricted devices · R3 sock default-on · R4 Immich · R5 Pack C2 · R6 GUI

## Active inventory

| ID | Status | Evidence |
|----|--------|----------|
| L1 | **Done** | `make l1-nfs-default` → `L1_NFS_DEFAULT_OK` |
| L2 | **Done (deepened)** | virtiofs default (strategy lock); block via `--opt backend=block`; FUSE writes + CR alpine deepen-ok |
| L3 | **Done** | `make l3-network-scoped-aliases` + unit tests |
| L4 | **Done** | `make l4-recipe-b-sock` → `L4_RECIPE_B_OK` |
| L6 / R5 | **Done (Pack C shipped)** | C1 `make bridge-corpus-parity`; C2 `make t2-client-smoke`; [pack-c plan](2026-11-21-pack-c-expansions.plan.md) shipped |
| F2 | **Done** | `make f2-compose-extends` → `F2_COMPOSE_EXTENDS_OK` |
| F1b | **Done (interim)** | Swarm control-plane subset + `make swarm-smoke-parity` |
| F3 / R2 | **Done (unrestricted)** | Allowlist opt-out (`CONTAINER_DEVICE_ALLOWLIST_ONLY=1`); char→virtiofs / block→virtio-blk; `make f3-devices-unrestricted` |
| F4 / R1 | **Done (CR+VZ)** | Live `F4_VZ_NET_HOTPLUG_LIVE_OK` on vz+cr; `make f4-vz-net-hotplug` / `f4-vz-net-hotplug-live` |
| F5 / R3 | **Done (default on)** | `enginePrivilegedSock` default true; opt-out `CONTAINER_INCORE_DOCKER_SOCK=0`; `make f5-incore-sock` |
| F6 | **Done** | `resolveVMMBackend` default `cr`; sidecar `vmm-backend=cr` |
| C3 | **Done** | `RuntimeService.hotplugBlock` → `CRVirtualMachineInstance.hotplug`; `make c3-blk-hotplug` |
| C06 / R4 | **Done** | Immich HTTP 200 (`COMPOSE_ENABLE_IMMICH=1` default); CR compose e2e HTTP gate |
| R6 | **Done** | `make r6-container-gui` → `R6_CONTAINER_GUI_OK` |

## Claim sentences (shipped)

- L1: Preferred kernel install is NFS-capable (`CONTAINER_PREFERRED_KERNEL=nfs`).
- L2: Default named volumes share via virtiofs directory plane; `--opt backend=block` exclusive; writable (FUSE CREATE/WRITE…).
- L3: Exact aliases unique per network (fail-closed on same-network collisions).
- L4: Recipe B supported for sock consumers.
- F2: Compose `extends` supported (file + same-file; deep merge).
- F4/R1: Running `network connect` prefers live NIC hotplug on CR and VZ (spare slots); restart fallback on failure.
- F5/R3: In-core `/var/run/docker.sock` **default on**; opt-out via `CONTAINER_INCORE_DOCKER_SOCK=0`.
- R6: First-party `container-gui` lists/stops/deletes containers (+ optional CR framebuffer host).
- R4: Immich compose fixture `10-immich` green with HTTP 200 (default-on via `COMPOSE_ENABLE_IMMICH=1`).
- R5: Pack C1 bridge corpus + Pack C2 Testcontainers-shaped smoke shipped.
