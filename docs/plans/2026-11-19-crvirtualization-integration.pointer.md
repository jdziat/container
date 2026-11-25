# Pointer: CRVirtualization integration

Canonical PRD lives in the sibling cleanroom repo:

[`../../virtualization.framework/docs/plans/2026-11-19-container-cr-integration.prd.md`](../../../virtualization.framework/docs/plans/2026-11-19-container-cr-integration.prd.md)

## Quick use

```bash
# Vendor + build CR adapter (from virtualization.framework):
../virtualization.framework/scripts/vendor-containerization.sh
cd ../virtualization.framework && swift build --product CRContainerization

# Build container runtime with CR gate:
cd ../container
CONTAINER_VMM_CR=1 swift build --product container-runtime-linux
# Install/sign with: CONTAINER_VMM_CR=1 make …  (uses signing/container-runtime-linux-cr.entitlements)

# Install writes vmm-backend=cr (F6). Override to Apple Virtualization:
export CONTAINER_VMM_BACKEND=vz
# Smokes / carrier:
#   ../virtualization.framework/scripts/container-cr-smoke.sh
#   ../virtualization.framework/scripts/cr-initfs-boot-smoke.sh
#   ../virtualization.framework/scripts/container-cr-alpine-e2e.sh
#   ../virtualization.framework/scripts/container-cr-compose-e2e.sh
#   ../virtualization.framework/scripts/container-cr-docker-catalog-e2e.sh
```

**F6:** CR is the **default** VMM (`resolveVMMBackend` → `cr`; install sidecar `vmm-backend=cr`). Fall back to system Virtualization with `CONTAINER_VMM_BACKEND=vz`. Runtime must be built with `CONTAINER_VMM_CR=1` for CR to load; otherwise the factory falls back to VZ with a warning. See `virtualization.framework/docs/plans/2026-11-20-cr-docker-job-catalog-carrier.prd.md`.
