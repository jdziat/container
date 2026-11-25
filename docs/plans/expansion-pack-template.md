# Expansion pack template (Pack C gate)

Use this template for any **post-freeze** Engine bridge route growth or
Testcontainers / Dev Containers implement claim. Packs are **optional** and are
**not** job-catalog debt. Outside the printed `docker-api-bridge support` matrix,
HTTP **501 remains success** until a pack lands with harness evidence.

Reference: [2026-11-19-post-freeze-parity-productization.prd.md](2026-11-19-post-freeze-parity-productization.prd.md),
[docs/docker-job-catalog.md](../docker-job-catalog.md),
[cto-job-catalog-parity-achieved-2026-11-19.md](cto-job-catalog-parity-achieved-2026-11-19.md).

## Pack record

| Field | Value |
|-------|--------|
| **Pack name** | e.g. `bridge-stats-rename` or `testcontainers-smoke` |
| **Status** | `defined` / `shipping` / `shipped` |
| **Clients or routes covered** | Exact Engine paths or client jobs |
| **Harness** | Script / test command that must exit 0 |
| **Allowed claim sentence** | One CTO-safe sentence (no “full Engine API”, no zero-config Desktop) |
| **Still 501 / document-only** | What remains outside this pack |
| **Out of scope** | Must include: in-core `/var/run/docker.sock`, Swarm, host `devices`, live NIC hotplug, unqualified OpenAPI fill |

## Gate checklist (merge blocker)

- [ ] Pack name + this filled record merged under `docs/plans/` or catalog
- [ ] Printed support matrix / bridge README updated in the **same** change if routes ship
- [ ] Harness green in CI or documented local gate
- [ ] Claim sentence reviewed against achievement forbidden language
- [ ] Job-catalog freeze text unchanged (no “parity incomplete” reopen)

## Defined packs (none shipped yet)

| Pack name | Priority note | Status |
|-----------|---------------|--------|
| `bridge-client-corpus` | Grow printed routes from failing-client corpus only | defined |
| `testcontainers-devcontainers-smoke` | Promote Recipe A/B/C extras beyond document-only | defined |

**Decision (2026-11-20):** define both; **ship neither** until demand + harness. Bridge corpus is the preferred first ship if one is chosen later.

**Shipping plan (2026-11-21):** [2026-11-21-pack-c-expansions.plan.md](2026-11-21-pack-c-expansions.plan.md) — C1 before C2; Phase 0 501 demand log; no route wishlist without a failing client.
