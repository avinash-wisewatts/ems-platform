# 04 — Architecture

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Architecture

Canonical source for **how the system is architected.** This directory
summarizes and links to authoritative sources — it does not duplicate them.
The frozen conceptual data architecture stays where it is, at
`docs/DDS/analytics-platform-future-state-architecture.md` (see
[../00-governance/source-of-truth.md](../00-governance/source-of-truth.md)
for why).

| Document | Purpose |
|---|---|
| [system-architecture.md](system-architecture.md) | The frozen conceptual model (entities, relationships, change control) — summarized, with the DDS as the full authoritative text. |
| [application-architecture.md](application-architecture.md) | The product-facing layering: Administration App / EMS Web App / Analytics API / Grafana, and the product-architecture gaps (PA-1..PA-6). |
| [data-architecture.md](data-architecture.md) | Telemetry pipeline, aggregation, and the analytics/semantic layer — pointers into [06-platform/](../06-platform/) for full detail. |
| [api-architecture.md](api-architecture.md) | The Analytics API (Phase 7) contract — shape, auth, live endpoints. |
| [security-and-tenancy.md](security-and-tenancy.md) | Tenant isolation model, database role separation, secrets handling. |
| [deployment-architecture.md](deployment-architecture.md) | Deployment topology, container boundaries, independent-deployment principle. |

## Relationship to the frozen DDS

`docs/DDS/analytics-platform-future-state-architecture.md` is **CONCEPTUALLY
FROZEN** — the authoritative statement of the target data model
(Organization/Site/Space/Asset/Point/Parameter/Relationship/Calculation).
`docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md`
is the authoritative phased build sequence (Phases 0–17). This directory's
documents are a **product/application-facing view** on top of those two
documents — they never redefine or override them. Where anything here
appears to disagree with the DDS, the DDS wins.

The DDS's own red-team review and ten-scenario stress test — evidentiary
records whose conclusions are already folded into the frozen document — are
archived at
[../99-archive/historical-decisions/](../99-archive/historical-decisions/).

## Architecture change control (restated from the DDS)

A proposal to add a new core entity or abstraction must demonstrate all
five criteria the DDS states (§"Architecture change control"): a real
requirement that cannot be represented with the existing model; not merely
a legacy-compatibility problem; cannot reasonably be expressed as an Asset,
Space, Point, Parameter, Relationship, or Calculation; simpler alternatives
considered and documented; a clear lifecycle/ownership/tenant boundary/
analytical purpose. Absent all five: do not add it.
