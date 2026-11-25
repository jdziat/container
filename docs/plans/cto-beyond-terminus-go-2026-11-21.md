# CTO stamp — beyond-terminus goals (GO to implement)

_Date: 2026-11-21_  
_Scope:_ Active IDs **L1, L2, L3, L4, L6, F2, F5** only  
_Inputs:_ [2026-11-21-beyond-terminus-goals.prd.md](2026-11-21-beyond-terminus-goals.prd.md), [parity-terminus-support.md](../parity-terminus-support.md), [2026-11-21-pack-c-expansions.plan.md](2026-11-21-pack-c-expansions.plan.md), [cto-post-freeze-productization-2026-11-20.md](cto-post-freeze-productization-2026-11-20.md)

## 1. Verdict

**GO-WITH-CONDITIONS**

The track is a **new** product track, not “parity incomplete.” Permanent non-goals and parked IDs are explicit enough to implement against. Implementation may start **Wave 1 (L1 only)** once the conditions below are met. This stamp does **not** authorize F5 ship, Pack C route growth without demand evidence, or any parked CR/hotplug/device work in this repo.

Parent SKU claim remains historically accurate: **job-catalog full Docker parity (ex-Swarm)**.

## 2. Ordered conditions

1. **Wave 1 = L1 only** in the L1 change set. Later waves may follow in sequence, not smuggled into L1.
2. **Fail-closed harness before green claim** for every active ID.
3. **L1 done claim must pick one path.** Ship sentence names exactly one user-visible default. CR `06-nfs` is not L1 evidence.
4. **L2 strategy lock before Wave 3 code.**
5. **L6 / Pack C: Phase 0 demand log** before any new bridge route.
6. **F5 remains separately CTO-gated** (opt-in; Recipe A default until F5 ship stamp).
7. **Release / doctor / terminus language review** on every Done PR.
8. **Parked IDs stay parked.**

## 3. Forbidden reopen

Full Engine OpenAPI; Swarm; bit-identical Desktop; CR corpus greens; CR-as-default; host devices; live NIC hotplug; Moby-identical hijack; “parity incomplete”; smuggling F2/F5 into Pack C.

## 4. Per-ID ship criteria

See persona evaluation in session; summary:

| ID | Done evidence |
|----|---------------|
| L1 | Named default NFS install path; harness; doctor/docs match; no CR `06` as evidence |
| L2 | Strategy written; multi-writer fixture green on VZ; doctor updated; mechanism-named claim |
| L3 | Cross-network alias OK; same-network clash fail-closed; harness + AliasPolicy tests |
| L4 | Recipe B first-class; doctor aligned; sock-consumer fixture via Recipe B |
| L6 | Demand log + matrix + corpus harness + still-501 assertion |
| F2 | `extends` harness red→green; merge bounds documented |
| F5 | Separate CTO ship stamp; opt-in sock; coexistence story |

## 5. Ship order

Wave 0 docs → Wave 1 L1 → Wave 2 L4 (+ Pack C Phase 0) → Wave 3 L2 → Wave 4 L3 → Wave 5 F2 → Wave 6 F5 (new stamp).

## L1 path chosen (this stamp amendment)

**Path (b):** install path is default-on — `CONTAINER_PREFERRED_KERNEL` defaults to `nfs`; `container system kernel set --recommended` and `system start` missing-kernel install follow that preference (invoke `install-recommended-kernel` / `install-nfs-kernel`). Set `CONTAINER_PREFERRED_KERNEL=kata` for the historic Kata tarball. Claim sentence:

> “Default preferred kernel install is the NFS-capable Containerization kernel (`CONTAINER_PREFERRED_KERNEL=nfs`); Kata remains available via `CONTAINER_PREFERRED_KERNEL=kata`.”

Harness: `make l1-nfs-default` → `L1_NFS_DEFAULT_OK`.
