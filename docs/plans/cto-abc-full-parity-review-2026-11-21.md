# CTO review — ABC full reopen / full parity plan

_Date: 2026-11-21_  
_Persona:_ CTO (adversarial)  
_Against:_ [ABC full reopen plan](file:///Users/jdziat/.cursor/plans/ABC%20full%20reopen-5af59a95.plan.md),
[beyond-terminus PRD](2026-11-21-beyond-terminus-goals.prd.md),
[full-parity push](file:///Users/jdziat/Code/virtualization.framework/docs/plans/2026-11-20-full-parity-push.plan.md) (closed Waves 1–3),
current trees `container` + `virtualization.framework`.

## 1. Verdict

**GO-WITH-CONDITIONS (B+)** for the ABC claim sentence as an **implemented product track**,
not as “full Desktop / full Engine / Apple VF bit-identical.”

Forbidden claims remain clean. Several plan IDs that were **documented Done** but
**missing or inverted in source** were repaired in this session (see §3). Residuals in
§4 are explicit and must not be marketed as Done.

## 2. Claim sentence under review

> Ship Wave A CR teardown quality, convert every beyond-terminus loud edge and frozen
> `wontfix` into harnessed product goals (including Swarm control-plane, host devices,
> live NIC hotplug, in-core Engine sock, and CR-as-default), and complete cleanroom VF
> debts (macOS install stages 6–7, zero API stubs, true MMIO blk hotplug) — without
> claiming bit-identical Docker Desktop or unqualified full Engine OpenAPI.

**Assessment:** Substantively met for the **allowed** interpretation (harnessed subsets +
cleanroom CRAUX2 / MMIO / stub burn-down). Not met if read as Docker Swarm orchestration,
VZ live NIC hotplug, Apple IPSW/aux, or Immich density green.

## 3. Evidence checked this review

| ID | Required | Evidence | Status |
|----|----------|----------|--------|
| Wave A | CR stop + 08 down without force-kill | Cooperative STOP + prior 08 downs ≤30s; 03 down 2s this session | **Met** (prior + spot) |
| B1 L1 | NFS preferred kernel | `make l1-nfs-default` → `L1_NFS_DEFAULT_OK` | **Met** |
| B1 C05 | builder fixture in CR default | `05-build-envfile` in `COMPOSE_FIXTURES` | **Met** (script) |
| B1 C06 | `06-nfs` on CR | Opt-in `COMPOSE_ENABLE_NFS=1` only; not run this session | **Partial** |
| B2 Pack C1 | bridge corpus | `t2-bridge-corpus.sh` PASS (stats/rename/top + 501) | **Met** |
| B2 Pack C2 | TC/DC smoke | Defined / not shipping | **Held** (allowed) |
| B3 L2 | virtiofs **default** | Strategy lock + `usesBlockBackend` → `return false`; `make l2-shared-volumes` OK; 08 DB volume pinned `backend: block` | **Met** (restored) |
| B3 C09 | nextcloud in CR default | In `COMPOSE_FIXTURES` | **Met** (script; full e2e not re-run) |
| B3 C10 | immich green | Explicit opt-in skip | **Residual** |
| B4 L3 | network-scoped aliases | `make l3-network-scoped-aliases` OK | **Met** |
| B5 F4 | true NIC hotplug | CR `addNetDevice` + HotplugNetTests 4/4; `preferCRNetHotplug` default-on; VZ/disconnect restart | **Met (CR)** / **Residual (VZ)** |
| B6 F2/F1 | extends + deploy | Prior harnesses; doctor copy updated | **Met** (prior) |
| B6 F1b | Swarm subset | Was **501** / make target removed → restored `SwarmControlPlane` + `make swarm-smoke-parity`; smoke PASS | **Met** (repaired) |
| B7 F3 | devices allowlist | Parser allowlist existed; Compose still `wontfix` → wired `devices` → `--device` + local allowlist | **Met** (repaired; install compose plugin) |
| B8 F5 | in-core sock | `CONTAINER_INCORE_DOCKER_SOCK=1` opt-in / fail-soft | **Interim** |
| B8 F6 | CR default | `resolveVMMBackend` → `cr`; install `vmm-backend=cr` | **Met** |
| C1 T8 | install+boot | MacInstallProbe `bootDebt=false` / CRAUX2; not Apple IPSW | **Met (cleanroom)** |
| C2 T10 | 0 stubs | checklist hand 117 / stub 0 | **Met** |
| C3 | MMIO blk hotplug | `HotplugBlockTests` + bus API; **no** container `hotplug(_ block)` callers | **Partial** |

## 4. Conditions / residuals (must stay loud)

1. **C06** — stamp green only after `COMPOSE_ENABLE_NFS=1` CR e2e on an NFS-capable kernel.
2. **C10 Immich** — remains opt-in; do not claim corpus `01–10` complete.
3. **VZ live NIC hotplug** — still restart; claim CR-only for F4 Done.
4. **F5** — opt-in only; separate stamp before default `/var/run/docker.sock`.
5. **C3 container callers** — MMIO blk hotplug is VMM-proven; container Sources still have no blk-hotplug call sites (fail-closed scan remains valid).
6. **Pack C2** — not shipping.
7. **Language** — no “full Swarm,” “full Desktop,” “Apple IPSW,” or “unqualified OpenAPI.”

## 5. Forbidden-claim scan

| Claim | Result |
|-------|--------|
| Full Docker Desktop | **Clean** |
| Unqualified full Engine OpenAPI | **Clean** (501 outside matrix) |
| Bit-identical Apple VF / IPSW | **Clean** (CRAUX2 honesty) |
| Swarm as full orchestration | **Clean** if marketed as F1b subset only |
| “Parity incomplete” SKU reopen | **Clean** (beyond-terminus / ABC named track) |

## 6. Allowed claim sentences (now)

- Job-catalog Docker parity (ex-Swarm orchestration) on CR carrier + VZ fallback.
- L2: default named volumes share via virtiofs; `--opt backend=block` exclusive.
- F3: Compose/`run --device` allowlist-only.
- F4: CR `network connect` prefers virtio-net hotplug; VZ/disconnect restart.
- F1b: Engine bridge Swarm **control-plane subset** harnessed (`make swarm-smoke-parity`).
- F5: in-core sock **opt-in** (`CONTAINER_INCORE_DOCKER_SOCK=1`).
- F6: CR is default VMM (`CONTAINER_VMM_BACKEND=vz` selects Apple VF).
- T8/T10: cleanroom CRAUX2 + 0 API stubs (not Apple private layouts).

## 7. Decision

**Ship the ABC track under GO-WITH-CONDITIONS.** Close the living “full parity plan”
implementation loop once §4 residuals are either (a) harness-greened or (b) explicitly
parked with terminus language that matches the tree. Do **not** widen Pack C or claim
Immich/VZ-hotplug/F5-default without a new CTO stamp.
