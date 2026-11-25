# CTO validation stamp — beyond-terminus wave (adversarial)

_Date: 2026-11-21_  
_Persona:_ CTO (adversarial)  
_Against:_ [cto-beyond-terminus-go-2026-11-21.md](cto-beyond-terminus-go-2026-11-21.md)  
_Method:_ Current tree read + harness execution (`make l1-nfs-default`, `l3-network-scoped-aliases`, `l4-recipe-b-sock`, `f2-compose-extends`). Installed `bin/container` dated 2026-11-20 was probed for doctor alignment.

## 1. Verdict

**GO-WITH-CONDITIONS**

L1 and L6 Phase 0 meet Done evidence on the tree. L2–L4 and F2 are **implemented in source** but are **not** Done under stamp conditions 2 and 7 (fail-closed harness / doctor+terminus language). F5 is correctly **not** Done. Parked IDs remain parked; no unauthorized OpenAPI fill, Swarm, CR-corpus green claim, devices, or hotplug ship.

Do **not** close the wave or publish Done sentences for L2/L3/L4/F2 until the required fixes below land. Do **not** treat soft-green harnesses that skip or excuse a stale doctor binary as Done proof.

## 2. Per-ID status

| ID | Status | Evidence (tree) | Gap vs Done criteria |
|----|--------|-----------------|----------------------|
| **L1** | **Done** | `CONTAINER_PREFERRED_KERNEL` defaults to `nfs` in `install-recommended-kernel.sh` and `KernelSet.preferredKernelPreference`; `KernelSet --recommended` / `SystemStart` call `installPreferredNFSKernel`; `make l1-nfs-default` → `L1_NFS_DEFAULT_OK`; [volumes.md](../volumes.md) NFS section names the preferred path; CR `06-nfs` not used as L1 evidence | Live `bin/container` doctor still emits pre-L1 NFS copy — rebuild before release notes; not a L1 code miss |
| **L2** | **Partial** | Directory/virtiofs default in `VolumesService`; `Filesystem.isSharedVirtiofsVolume`; `ContainersService.validateExclusiveNamedVolumes` allows shared RW; doctor source INFO `[named-volume-single-writer]`; mechanism-named claim in volumes.md / resource-usage.md | No L2 strategy-lock artifact; no `make l2-*` fail-closed harness; VZ multi-writer fixture not gated as L2 Done evidence; PRD still “Open / strategy lock before code”; live doctor still WARN “single-writer block device” |
| **L3** | **Partial** | `AttachmentNameValidator` per-network uniqueness; `NetworkMatchSelector.offer` always continues (`return false`); unit tests (`hostnameOnDifferentNetworks`, `aliasReuseAcrossNetworks`, …) + `AliasPolicy` tests; `make l3-network-scoped-aliases` → `L3_NETWORK_SCOPED_ALIASES_OK` | Terminus loud-edge row still “Exact hostname aliases **globally unique**”; stale comment in Compose (`globally unique`); doctor `alias-clash-in-file` still file-global while copy says per-network; live doctor still “globally unique”; PRD “In progress” |
| **L4** | **Partial** | Recipe B first-class in bridge README + job-catalog; Compose doctor source → Recipe B; `scripts/parity/l4-recipe-b-sock.sh` + `make l4-recipe-b-sock`; bridge `_ping` on `…/docker.sock` shape OK | Harness **soft-passes** when doctor binary lacks “Recipe B” (`doctor binary lacks Recipe B string… source contract OK`) — violates fail-closed-before-green; migration skill still calls Recipe B “optional”; PRD “In progress” |
| **F2** | **Partial** | `resolveExtends` / `deepMergeComposeService` / `parseExtendsSpec` in ContainerCompose; merge bounds in [compose-support-matrix.md](../compose-support-matrix.md) (`extends` = `done`); `make f2-compose-extends` → `F2_COMPOSE_EXTENDS_OK` | [docker-job-catalog.md](../docker-job-catalog.md) J2 still lists `extends` `wontfix`; migration skill still `extends` `wontfix`; harness does not assert merge semantics (only “not unsupported”); PRD “Open” |
| **L6** | **Done (Phase 0 only)** | [2026-11-21-pack-c-phase0-demand.md](2026-11-21-pack-c-phase0-demand.md); corpus harness + still-501 in `t2-bridge-corpus.sh`; explicit “no new bridge routes / not an OpenAPI fill” | Route growth still gated; do not claim Pack C “supported” |
| **F5** | **Not Done / Open** | No separate F5 ship stamp; Recipe A remains default coexistence story; in-core sock still out of scope in bridge README | Correctly ungated; **must not** be claimed Done in this wave |
| **Parked** | **Held** | PRD parked table intact (CR corpus C03/C05/C06/C09/C10, F6, F3 devices, F4/L5 hotplug); `devices` `wontfix`; connect still restart-as-API; Swarm / unqualified OpenAPI stay out; no CR-as-default | Keep parked; terminus still lists F1/F1b as active beyond-terminus IDs — do not smuggle Swarm into this wave |

## 3. Forbidden language check

| Check | Result |
|-------|--------|
| “parity incomplete” reopen | **Clean** in wave plans / terminus framing |
| Unqualified full Engine OpenAPI / OpenAPI fill claimed | **Clean** (L6 Phase 0 forbids fill) |
| Swarm claimed done / reopened as SKU | **Clean** (still out); F1b “named subset” remains a separate track, not this wave |
| F5 / in-core `/var/run/docker.sock` claimed done | **Clean** |
| CR corpus greens / CR-as-default as this-wave Done | **Clean** (still parked / opt-in) |
| Host devices / live NIC hotplug as done | **Clean** |
| Stale dialect contradicting shipped IDs | **FAIL** — terminus L3 row + live doctor + Compose comment still “globally unique”; job-catalog/migration still `extends` `wontfix` while matrix says `done`; live doctor still single-writer WARN for L2 |

## 4. Required fixes (before Done stamps on Partial IDs)

1. **Rebuild and install** Compose plugin / `bin/container` so live `compose doctor` matches source for `[nfs-kernel]`, `[named-volume-single-writer]` INFO, `[alias-clash-in-file]` / `[vm-lifecycle]` per-network copy, and `[docker-sock]` → Recipe B.
2. **Fail-closed harnesses:** if `CONTAINER_BIN` exists, require the live doctor strings; remove soft-pass paths that print OK when the binary is stale (`l4-recipe-b-sock.sh` today).
3. **Language sync (condition 7):**
   - Update [parity-terminus-support.md](../parity-terminus-support.md) L3 edge to per-network uniqueness (not globally unique).
   - Drop stale “globally unique” comment in `ContainerCompose` (~service-alias publish).
   - Update job-catalog J2 loud edge and `skills/container/references/docker-migration.md`: `extends` is `done` (keep devices / Swarm out); Recipe B = first-class sock-consumer path, not merely “optional.”
4. **L2 Done gate:** write the strategy-lock sentence (directory/virtiofs default; `backend=block` exclusive); add `make l2-*` harness (or pin an existing VZ multi-writer fixture as the L2 gate) before claiming Done.
5. **L3 honesty:** either scope `alias-clash-in-file` by network or document that file-global WARN is conservative preflight above the runtime per-network rule.
6. **F2 Done gate:** assert merge bounds in harness (child env wins / list concat), not only “accepted.”
7. **PRD status table:** align [2026-11-21-beyond-terminus-goals.prd.md](2026-11-21-beyond-terminus-goals.prd.md) with this stamp (L1 Done; L6 Phase 0 Done; others Partial/Open; F5 Open).
8. **F5:** no Done claim without a **separate** CTO ship stamp.

## 5. Allowed claim sentences (after fixes)

- **L1 (allowed now):** “Default preferred kernel install is the NFS-capable Containerization kernel (`CONTAINER_PREFERRED_KERNEL=nfs`); Kata remains available via `CONTAINER_PREFERRED_KERNEL=kata`.”
- **L6 (allowed now, Phase 0 only):** “Pack C Phase 0 demand log recorded; outside-matrix routes remain HTTP 501; no OpenAPI fill.”
- **L2/L3/L4/F2:** withhold Done sentences until §4 closes.
- **F5:** withhold entirely.

## 6. Explicit non-authorization (unchanged)

This stamp does **not** authorize F5 ship, Pack C route growth beyond Phase 0 evidence, CR corpus greens, CR-as-default, host devices, live NIC hotplug, Swarm, or unqualified Engine OpenAPI.
