# Source of Truth

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering

This adapts the priority order and contradiction-handling discipline already
established by `docs/platform-manual/README.md` (now archived — see
[../99-archive/historical-implementation/platform-manual/](../99-archive/historical-implementation/platform-manual/))
to the full `docs/` structure.

## Canonical sources, by concern

| Concern | Canonical source |
|---|---|
| Product intent, vision, users | [01-product/](../01-product/) |
| Requirements | [02-requirements/](../02-requirements/) |
| UX / product design | [03-ux-and-design/](../03-ux-and-design/) |
| Frozen conceptual data architecture | `docs/DDS/analytics-platform-future-state-architecture.md` (kept at this path — see below) |
| Product-facing / application architecture | [04-architecture/](../04-architecture/) |
| Applications (EMS Web App, Admin Portal, Analytics API) | [05-applications/](../05-applications/) |
| Platform/infrastructure (telemetry, database, Grafana, MQTT) | [06-platform/](../06-platform/) |
| Feature/domain documentation | [07-features/](../07-features/) |
| Verification/validation | [08-verification/](../08-verification/) |
| Release/deployment | [09-release-and-deployment/](../09-release-and-deployment/) |
| Operations | [10-operations/](../10-operations/) |
| Governance/decisions | [00-governance/](.) |
| Historical material | [99-archive/](../99-archive/) |
| **Exact schema, exact query, exact config value** | The repository itself: `postgres/ddl/`, `postgres/migrations/`, `grafana/`, `compose.yaml`, `.github/workflows/` — **never** a Markdown file, including this one |
| **Current runtime state** (row counts, live telemetry, commissioning status) | The live staging/production database, queried read-only — never a static document |

## Why `docs/DDS/` stays where it is

`docs/DDS/analytics-platform-future-state-architecture.md` is declared
CONCEPTUALLY FROZEN by its own header and is referenced **by exact path** from
migration file comments and `postgres/restructure_manifest.csv` entries (e.g.
migration 223's header cites it directly). Moving it would silently break
those references for no documentation benefit. It and its companion
`analytics-platform-future-state-architecture-implementation-roadmap.md`
remain at `docs/DDS/`, treated as canonical inputs that
[04-architecture/](../04-architecture/) summarizes and links to, never
duplicates. The DDS's own red-team review and stress-test documents — described
by the DDS itself as an "evidentiary record" whose conclusions are already
folded into the frozen document — are archived at
[../99-archive/historical-decisions/](../99-archive/historical-decisions/).

## Priority order when evidence conflicts (highest first)

1. Live database / live application behavior, when explicitly verified.
2. Current repository implementation (code, schema, migrations, config).
3. Current deployment/configuration files.
4. Current canonical documentation (the numbered directories above).
5. `docs/99-archive/` — historical documents and investigations.
6. Historical assumptions / superseded notes.

## Recording a contradiction

Never silently reconcile a contradiction between sources. Record it inline,
adapting this format:

```
CURRENT IMPLEMENTATION: <what's actually true now, with evidence>
HISTORICAL / DOCUMENTED EXPECTATION: <what an older source claimed>
CHANGE: <what happened between the two, if known>
VERIFICATION: <how/when this was checked, and by what method>
```

Mark historical findings `HISTORICAL`, `SUPERSEDED`, `RESOLVED`, `DRIFT`, or
`UNKNOWN` rather than deleting them. `docs/99-archive/` is evidence, never an
automatic source of truth — reconcile it against current repo/staging/
production state before treating anything in it as current.

## Known unresolved conflicts carried into this reorganization

- **Hierarchy framing differs slightly between the frozen DDS and the
  product documentation set.** The DDS models `Organization → Site →
  Building → Floor → Space` as the physical tree, with `Asset` as a
  separate, non-nested hierarchy (§A.1, §B.2 of the frozen architecture).
  The product documentation and the Product Owner Workshop consistently
  simplify this to a single customer-facing chain, `Organisation/Portfolio →
  Site → Space → Asset` (e.g. workshop Q4, Q69). This is very likely an
  intentional simplification for the customer-facing vocabulary layer (the
  DDS's Building/Floor levels are folded into "Space" for the customer), not
  a genuine architectural disagreement — but no source explicitly states
  that reconciliation. See
  [decisions/ADR-002-hierarchy-model.md](decisions/ADR-002-hierarchy-model.md).
- **Two Grafana panels on `site-overview.json` use different "demand"
  aggregation semantics**, neither of which is the platform's dedicated
  demand-calculation engine (`analytics.demand_intervals`/`demand_state`) —
  tracked as a known issue, not resolved by this reorganization. See
  [06-platform/grafana/README.md](../06-platform/grafana/README.md).
