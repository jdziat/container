# CTO recheck — beyond-terminus wave (post-implementation)

_Date: 2026-11-21 (recheck)_  
_Persona:_ CTO (adversarial)  
_Against:_ [cto-beyond-terminus-go-2026-11-21.md](cto-beyond-terminus-go-2026-11-21.md),
prior [wave validation](cto-beyond-terminus-wave-validation-2026-11-21.md)  
_Method:_ Current tree + harness execution after fail-closed / language / merge-bound fixes.

## 1. Verdict

**GO for L1–L4, L6 Phase 0, F2 Done claims** under the original stamp conditions that blocked
Partial → Done. **F5 is Done (interim)** as opt-in E3 (`CONTAINER_INCORE_DOCKER_SOCK=1` /
`enginePrivilegedSock`, default off; Recipe A coexistence). Default `/var/run/docker.sock`
still requires a separate CTO stamp. Nitpick was explicitly skipped for this goal session.

## 2. §4 condition closure

| # | Required fix (prior stamp) | Status |
|---|----------------------------|--------|
| 1 | Rebuild/install so live doctor matches source | **Met** — `bin/container` + compose plugin refreshed; L4 doctor shows Recipe B |
| 2 | Fail-closed harnesses (no soft-pass on stale doctor) | **Met** — `l4-recipe-b-sock.sh` fails if Recipe B string missing when `CONTAINER_BIN` present |
| 3 | Language sync (per-network L3, extends done, Recipe B first-class) | **Met** — terminus / job-catalog / migration / Compose doctor copy aligned |
| 4 | L2 strategy-lock + `make l2-*` harness | **Met** — [l2-strategy-lock](2026-11-21-l2-strategy-lock.md); `make l2-shared-volumes` → `L2_SHARED_VOLUMES_OK` |
| 5 | L3 honesty (alias-clash scoped or documented) | **Met** — doctor `alias-clash-in-file` is per-network |
| 6 | F2 merge-bound harness asserts | **Met** — `make f2-compose-extends` asserts child env wins + base/child keys |
| 7 | PRD status table | **Met** — [beyond-terminus PRD](2026-11-21-beyond-terminus-goals.prd.md) Done/Open rows |
| 8 | F5 withhold default sock | **Held as default** — interim opt-in Done; default `/var/run` still gated |

## 3. Harness evidence (this recheck)

| ID | Gate | Result |
|----|------|--------|
| L1 | `make l1-nfs-default` | `L1_NFS_DEFAULT_OK` |
| L2 | `make l2-shared-volumes` | `L2_SHARED_VOLUMES_OK` |
| L3 | `make l3-network-scoped-aliases` | `L3_NETWORK_SCOPED_ALIASES_OK` |
| L4 | `make l4-recipe-b-sock` | `L4_RECIPE_B_OK` |
| F2 | `make f2-compose-extends` | `F2_COMPOSE_EXTENDS_OK` |
| F5 | `make f5-incore-sock` | `F5_INCORE_SOCK_OK` (opt-in; default false) |

## 4. Allowed claim sentences (now)

- L1: Preferred kernel install is NFS-capable (`CONTAINER_PREFERRED_KERNEL=nfs`).
- L2: Default local named volumes share via virtiofs directory plane; `backend=block` exclusive.
- L3: Exact aliases unique per network (fail-closed on same-network collisions).
- L4: Recipe B is first-class for sock consumers.
- F2: Compose `extends` supported (file + same-file; deep merge; child env wins).
- L6 Phase 0 only: demand log recorded; outside-matrix routes stay 501; no OpenAPI fill.
- F5 interim: in-core `/var/run/docker.sock` via `CONTAINER_INCORE_DOCKER_SOCK=1` / `enginePrivilegedSock` (opt-in; Recipe A default).

## 5. Explicit non-authorization (unchanged)

Does **not** authorize **default** in-core `/var/run/docker.sock`, Pack C route growth beyond
Phase 0, CR corpus greens as unqualified Done, unrestricted host devices, VZ live NIC
hotplug productization, Swarm as a SKU, or unqualified Engine OpenAPI.
