# Pack C — expansion packs plan

_Date: 2026-11-21_  
_Status: shipped (R5) — C1 `t2-bridge-corpus` + C2 `t2-client-smoke`_  
_Parent:_ [2026-11-19-post-freeze-parity-productization.prd.md](2026-11-19-post-freeze-parity-productization.prd.md)  
_Sibling open track:_ [2026-11-21-beyond-terminus-goals.prd.md](2026-11-21-beyond-terminus-goals.prd.md) (L6 = gated Pack C growth)  
_Template:_ [expansion-pack-template.md](expansion-pack-template.md)  
_CTO:_ [cto-post-freeze-productization-2026-11-20.md](cto-post-freeze-productization-2026-11-20.md)

## Goal

Turn the two **defined** Pack C entries into a shippable sequence without reopening
job-catalog debt. Pack C stays **optional**: HTTP **501** outside the printed bridge
matrix remains success until a named pack lands with harness + claim sentence.

## Decision

| Choice | Call |
|--------|------|
| Ship order | **C1 first** (`bridge-client-corpus`), then **C2** (`testcontainers-devcontainers-smoke`) |
| Trigger to start C1 | Measured demand: ≥1 real client (or pinned open-source smoke) fails on a **specific** Engine route that is (a) implementable on the per-VM model and (b) not in Out of scope |
| Ship neither | Valid default until that trigger; keep template status `defined` |
| Forbidden reopen (this pack) | Unqualified full Engine OpenAPI fill; Swarm; zero-config Desktop discovery; hijack bit-identical to Moby; CR / hotplug / devices (parked elsewhere) |
| Beyond-terminus (not Pack C) | Active sibling IDs: L1–L4, L6, F2, F5. Parked: CR corpus / F6 / F3 devices / F4 hotplug. Do not smuggle parked work into a bridge corpus pack |

## Pack records (filled)

### C1 — `bridge-client-corpus`

| Field | Value |
|-------|--------|
| **Pack name** | `bridge-client-corpus` |
| **Status** | `shipped` (R5) — `make bridge-corpus-parity` / `scripts/parity/t2-bridge-corpus.sh` |
| **Clients or routes covered** | **Failing-client driven only.** Candidate routes come from a corpus of Engine calls that return 501 today and block a named client. Likely first wave (hypothesis, not pre-commit): `GET /containers/{id}/stats` (stream or one-shot), `POST /containers/{id}/rename`, `POST /containers/{id}/attach` (or attach-lite via logs), `GET /containers/{id}/top` — **cut to what the corpus proves**, never a wishlist. |
| **Harness** | New `scripts/parity/t2-bridge-corpus.sh` (or extend `t2-bridge-e2e.sh` with a `CORPUS=` manifest). Must: start bridge, assert each **shipped** route succeeds with a fixed request/response contract, assert ≥1 **still-outside** route still returns **501** with the stable curated-contract message. Wire optional target under `Makefile` (e.g. `make bridge-corpus-parity`). |
| **Allowed claim sentence** | “Curated Engine bridge now includes \<exact methods/paths\> for \<named client or corpus\>; routes outside `docker-api-bridge support` still return HTTP 501.” |
| **Still 501 / document-only** | Everything not listed in the updated printed matrix for that pack; Recipe A/B/C unchanged as the socket story. |
| **Out of scope** | In-core `/var/run/docker.sock`; Swarm; host `devices`; live NIC hotplug; hijack multiplex bit-identical to Moby; unqualified “full Engine API”. |

### C2 — `testcontainers-devcontainers-smoke`

| Field | Value |
|-------|--------|
| **Pack name** | `testcontainers-devcontainers-smoke` |
| **Status** | `shipped` (R5) — `make t2-client-smoke` |
| **Clients or routes covered** | Documented Recipe A/B/C plus catalog “Testcontainers extras” / “Dev Containers extras” promoted from document-only to **harnessed smoke** — not new Engine surface unless C1 already shipped those routes. |
| **Harness** | New `scripts/parity/t2-client-smoke.sh`: (1) Recipe A: bridge on Application Support sock + `DOCKER_HOST` + one Testcontainers-shaped create/start/exec/delete via Engine API; (2) optional Recipe B skip unless `PARITY_PRIVILEGED_SOCK=1`; (3) assert outside-matrix route still 501. Prefer a **pinned** minimal Java/Go Testcontainers sample or pure curl corpus that mirrors TC’s first calls — avoid flaky upstream suite as the gate. |
| **Allowed claim sentence** | “Testcontainers / Dev Containers can use the curated bridge via Recipe A (or optional Recipe B); this is a smoke claim for documented recipes, not zero-config Desktop discovery.” |
| **Still 501 / document-only** | Any Engine path not on the printed matrix; IDE auto-discovery of `/var/run/docker.sock` without Recipe B. |
| **Out of scope** | Same freeze non-goals as C1; claiming “works with all Testcontainers modules.” |

## Workstream sequence

### Phase 0 — Demand capture (no code claim)

1. Keep a short **501 corpus log** (doc or `scripts/parity/bridge-corpus/README.md`): client name, method/path, date, blocker severity.
2. Do **not** widen the matrix from hunches. One row = one observed failure.
3. Exit Phase 0 when ≥1 route clears the Decision trigger.

### Phase 1 — Ship C1 (bridge-client-corpus)

| Step | Work | Gate |
|------|------|------|
| 1.1 | Freeze corpus manifest (YAML/JSON): routes + sample bodies + expected status | Reviewed against Out of scope |
| 1.2 | Implement only those routes in `DockerAPIBridge` (practical subsets OK; document subset bounds in matrix notes) | Unit or focused bridge tests |
| 1.3 | Update `supportMatrix` string + README table + `docs/parity-matrix.md` Engine bridge row notes **in the same change** | Diff shows matrix ↔ code match |
| 1.4 | Land `t2-bridge-corpus.sh`; keep existing `t2-bridge-e2e.sh` green | Both scripts exit 0 |
| 1.5 | Fill template status → `shipped`; add claim sentence to catalog / terminus one-pager | Forbidden-language grep clean |
| 1.6 | Optional CTO one-liner stamp under `docs/plans/` | Stamp cites harness + claim |

### Phase 2 — Ship C2 (TC/DC smoke) — optional

| Step | Work | Gate |
|------|------|------|
| 2.1 | Pick minimal client path (curl-shaped TC bootstrap **or** one pinned module) | Runs on Recipe A without privileged sock |
| 2.2 | `t2-client-smoke.sh` + Makefile target | Exit 0 on CI-capable Mac gate (or documented local-only) |
| 2.3 | Promote catalog “document-only” extras to “smoke harnessed” with the C2 claim sentence | No zero-config Desktop language |
| 2.4 | Template status → `shipped` for C2 | Same merge checklist as template |

### Phase 3 — Stop

- No C3. Further routes = **new** named pack records under the same template, or defer.
- Do not start a living “OpenAPI remaining” list.

## Merge checklist (every pack)

Copied from the template; all required:

- [ ] Pack name + filled record merged
- [ ] Printed support matrix / bridge README updated in the **same** change if routes ship
- [ ] Harness green (CI or documented local gate)
- [ ] Claim sentence reviewed against achievement forbidden language
- [ ] Job-catalog freeze text unchanged (no “parity incomplete”)

## Explicit non-goals (repeat)

- Live NIC hotplug (N2)
- In-core apiserver `/var/run/docker.sock` (E3)
- Swarm / `deploy` / `extends` / host `devices`
- Unqualified full Engine OpenAPI
- CR as default VMM or “CR is Docker parity”
- Auto-symlink to `/var/run/docker.sock` as the supported default

## Success measures

- Support can point at a **named** pack + harness when asked “does X client work?”
- 501 rate for corpus clients drops only for listed routes; outside routes stay loud 501
- No new unbounded Engine backlog without a pack name

## Open questions (narrow)

1. **C1 first route set:** leave empty until Phase 0 log has entries — do not pre-seed stats/rename/attach without a failing client.
2. **C2 CI posture:** local-only Mac gate vs required CI job (prefer local/documented until flakiness known).
3. **Whether C2 can ship without C1:** yes, if TC/DC only needs Recipe honesty + existing matrix; no new routes without C1 (or a combined pack record).

## Immediate next actions

1. Add `scripts/parity/bridge-corpus/README.md` (501 demand log format) — Phase 0 only.
2. When first real blocker lands, open C1 implementation under `/eg-new-feature` with this plan as the PRD pointer.
3. Until then, Pack C stays **defined, none shipped** (current CTO stamp).
