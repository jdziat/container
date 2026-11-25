# L2 strategy lock — shared named volumes

_Date: 2026-11-21_  
_Status:_ locked

## Choice

**Default local named volumes use a shared host-directory virtiofs plane.** Multiple
containers may mount the same volume RW. Exclusive virtio-blk remains available via
`--opt backend=block` (single-writer).

## Rejected alternatives (this wave)

- Guest NFS for all named volumes (kept for explicit `type: nfs` only)
- Co-locate multi-writer services in one VM (Compose workaround, not the volume plane)

## Claim sentence

> “Default local named volumes share via the virtiofs directory plane on VZ; block-image volumes (`--opt backend=block`) stay exclusive.”

## Evidence

- `VolumesService` directory vs block backends
- `Filesystem.isSharedVirtiofsVolume` / `ContainersService.validateExclusiveNamedVolumes`
- `docs/volumes.md` named-volume sharing section
- Doctor `[named-volume-single-writer]` is informational for the default plane
