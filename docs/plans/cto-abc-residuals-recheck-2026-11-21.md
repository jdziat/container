# CTO recheck — ABC residuals (post-resume)

_Date: 2026-11-21 (resume)_  
_Against:_ [cto-abc-full-parity-review-2026-11-21.md](cto-abc-full-parity-review-2026-11-21.md) §4  
_Persona:_ CTO (adversarial)

## 1. Verdict

**GO held (B+ → B+/A- engineering).** Residual §4 items closed or honestly narrowed:

| # | Residual | Now |
|---|----------|-----|
| 1 | C06 NFS | **Partial→Met (manual)** CR guest NFS `nfs-parity-ok`; compose e2e re-seed still flaky (EHOSTUNREACH after drain) — keep `COMPOSE_ENABLE_NFS=1` opt-in until e2e stable |
| 2 | C10 Immich | **Held** opt-in / parked |
| 3 | VZ NIC hotplug | **Held** (CR-only F4) |
| 4 | F5 default sock | **Held** opt-in; `make f5-incore-sock` gate |
| 5 | C3 container callers | **Met** — `RuntimeService.hotplugBlock` → `cr.hotplug(`; tests inverted |
| 6 | Pack C2 | **Held** not shipping |
| — | (new) virtiofs symlink LOOKUP | **Met** — hosts-dns / bind children under share-root symlinks |

## 2. Regression fixed this resume

Share-root virtiofs symlinks (L2 materialize) stored resolved host dirs in the FUSE
node table; child LOOKUP then failed `contained()` (ENOENT) → alpine `hosts-dns`
breakage. Fix: allowlist first-level symlink targets for out-of-share child paths.
Evidence: `testLookupThroughShareRootSymlink` + alpine `cr-ok`.

## 3. Allowed additions

- C3: Runtime XPC `hotplugBlock` is the container caller for CR blk hotplug.
- C06: claim **CR NFS mount works** (manual harness); do **not** claim default compose
  corpus includes green `06-nfs` until e2e drain/re-seed is stable.

## 4. Still forbidden

Full Desktop / unqualified OpenAPI / Apple IPSW / Swarm orchestration / Immich default.
