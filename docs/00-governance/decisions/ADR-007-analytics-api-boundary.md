# ADR-007: The Analytics API as the sole customer-facing semantic data boundary

Status: Decided; Phase 7 landed
Date: 2026-09-10 (product decision, consistent with DDS §F); Phase 7 merged to `staging` via PR #43 (`b923f88`, `6225970`)
Decision owners: Architecture
Related requirements: EMS-REQ-002, EMS-REQ-003, EMS-REQ-005, EMS-REQ-008
Related features: [Analytics API](../../05-applications/analytics-api/README.md)

## Context

There was no application-level analytics API before Phase 7 — Grafana's SQL
views *were* the API. A customer-facing web application cannot query
PostgreSQL/TimescaleDB/Grafana directly without re-exposing exactly the raw
telemetry structures the product principles (ADR-001) prohibit.

## Decision

The customer EMS Web Application reads **exclusively** via a semantic,
read-only `GET /api/v1/*` boundary — the Analytics API. It never queries the
database, TimescaleDB, Grafana, or internal analytics objects directly; no
query builder, no dynamic SQL. Authorisation is enforced **server-side**
(SECURITY DEFINER functions, tenant/site/space scoping) — frontend permission
checks are UX-only. The API returns a flat error envelope
(`{"error": "<code>", "detail": "<message>"}`); an inaccessible or unknown
resource returns 404 indistinguishable from "doesn't exist." No change to the
existing Phase 7 contract without an explicit architecture decision — new
needs are additive views/functions or a logged dependency.

## Rationale

`ems-product-architecture.md` §3: "the product treats the Analytics API as
the single source of truth for what the customer can be shown. If a screen
needs data the API does not expose, that is a dependency to be scheduled, not
a reason to bypass the boundary." This directly enforces ADR-001's "no raw
telemetry terminology in the customer UI" principle at the data-access layer,
not just in the UI.

## Alternatives considered

Not established in available source material.

## Consequences

- Every screen in `03-ux-and-design/information-architecture.md` records an
  explicit API-dependency status (`LIVE` / `PLANNED (MVP-n)` / `MISSING`) —
  a screen is not "ready" regardless of how finished its UI looks until its
  API and semantic/data capability both exist
  ([02-requirements/requirements-traceability.md](../../02-requirements/requirements-traceability.md)).
- Extending the API is additive `v_grafana_*`-pattern views/functions
  through the existing thin FastAPI layer, following the same pattern
  already used for Grafana — never a parallel query mechanism.

## Evidence / references

- `docs/product/ems-product-architecture.md` §3 — [../../99-archive/superseded-product/ems-product-architecture.md](../../99-archive/superseded-product/ems-product-architecture.md)
- `docs/DDS/analytics-platform-future-state-architecture.md` §F
- `docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md` Phase 7

## Implementation references

Phase 7 — **DONE**. Live endpoints: `GET /api/v1/me`, `GET /api/v1/sites`,
`GET /api/v1/sites/{id}/energy/consumption`, `GET /api/v1/spaces/{id}/measurements`.
See [../../05-applications/analytics-api/README.md](../../05-applications/analytics-api/README.md).

## Validation references

Tenant/site/space access enforced server-side via
`admin.portal_user_can_access_site`/`analytics.portal_user_can_access_space`
(migration 231) — verified as part of the 2026-09-11 staging state check.
Demand, Power Quality, Asset, comparison/baseline, Attention, cost, alert,
export, and reporting endpoints do not yet exist (majority of remaining MVP
work).
