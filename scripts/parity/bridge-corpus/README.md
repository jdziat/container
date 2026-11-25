# Bridge client corpus (Pack C1) — 501 demand log

Demand-driven log for Engine routes that return **HTTP 501** on the curated
`docker-api-bridge` and block a named client. Pack C stays optional: 501 outside
the printed support matrix remains success until a named pack lands with harness
+ claim sentence.

See [docs/plans/2026-11-21-pack-c-expansions.plan.md](../../../docs/plans/2026-11-21-pack-c-expansions.plan.md).

## Log format

One row = one observed (or hypothesized) failure. Append; do not widen the
printed matrix from hunches alone.

| Field | Meaning |
|-------|---------|
| **date** | ISO date of observation (or hypothesis seed date) |
| **client** | Named client / smoke / corpus id |
| **method** | HTTP method |
| **path** | Engine path (version prefix optional; use canonical without `/v1.xx`) |
| **severity** | `blocker` / `degraded` / `nice-to-have` |
| **status** | `observed` (real failure) / `hypothesis` (candidate only) / `shipped` |
| **notes** | Short why; link issue if any |

### Template (copy a row)

```text
| YYYY-MM-DD | <client> | METHOD | /path | blocker|degraded|nice-to-have | observed|hypothesis|shipped | <notes> |
```

## Demand log

| date | client | method | path | severity | status | notes |
|------|--------|--------|------|----------|--------|-------|
| 2026-11-21 | hypothesized-corpus | GET | `/containers/{id}/stats` | nice-to-have | hypothesis | One-shot JSON subset candidate; streaming not assumed. Aspirational until observed client failure. |
| 2026-11-21 | hypothesized-corpus | POST | `/containers/{id}/rename` | nice-to-have | hypothesis | `?name=` rename candidate. Aspirational until observed client failure. |
| 2026-11-21 | hypothesized-corpus | GET | `/containers/{id}/top` | nice-to-have | hypothesis | Guest `ps` Titles/Processes subset candidate. Aspirational until observed client failure. |

Machine-readable aspirational freeze: [manifest.json](manifest.json).
Harness once routes ship: [../t2-bridge-corpus.sh](../t2-bridge-corpus.sh).

## Rules

1. Prefer real client evidence (`observed`) before claiming Pack C1 shipped.
2. Hypotheses may seed implementation under an explicit C1 start; keep them marked
   `hypothesis` in this log until a named client proves demand (or pack status moves).
3. Outside-matrix routes must keep returning **501** with the stable curated-contract message.
4. Out of scope: Swarm, in-core `/var/run/docker.sock`, hijack bit-identical to Moby,
   unqualified full Engine OpenAPI.
