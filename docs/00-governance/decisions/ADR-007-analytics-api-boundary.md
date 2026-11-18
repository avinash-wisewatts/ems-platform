# ADR-007: The Analytics API as the sole customer-facing semantic data boundary

Status: Decided; Phase 7 landed. Amendment 1 (2026-11-18): the boundary also carries a small, enumerated set of audited customer write routes — see "Amendment 1" below and [ADR-024](ADR-024-customer-configurable-alert-rules.md)
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

## Amendment 1 (2026-11-18) — enumerated, audited customer write routes

**HISTORICAL / DOCUMENTED EXPECTATION:** "read-only `GET /api/v1/*`
boundary" (Decision, above).

**CURRENT IMPLEMENTATION (verified on `origin/staging` `8abd023`,
2026-11-18):** the boundary already carries one customer write surface —
the Reports export jobs (`POST /api/v1/sites/{id}/report-exports`,
`POST /api/v1/report-exports/{job_id}/retry`; ADR-014 Amendment 2,
migrations 309/312) — which writes only the caller's own job records.

**CHANGE:** the Analytics API remains the sole customer-facing data
boundary and remains read-only for EMS telemetry, analytics and
metadata. It may additionally expose a small, **enumerated** set of
customer write routes, each approved by its own decision record. Alert
rules (create, edit, enable/disable, soft delete) and alert
acknowledgement are the second such set
([ADR-024](ADR-024-customer-configurable-alert-rules.md)). Every write
route must:

1. require a **dedicated** permission at the route (the blanket
   `/api/v1/*` → `dashboard.view` middleware rule is not sufficient) and
   name the route explicitly in the request-permission mapping;
2. accept only `application/json` and reject cross-site requests, in
   addition to the session cookie's same-origin protections;
3. write only through a SECURITY DEFINER database function that
   re-derives the actor from `p_portal_user_id`, re-checks the
   permission and the tenant/site/asset/parameter relationships, and
   returns "not found" for anything inaccessible (unchanged 404 rule);
4. write its `admin.audit_events` row in the same transaction, recording
   the actual acting user and whether that actor is a customer user or
   WiseWatts staff (`GLOBAL` scope), derived server-side (the
   Reports-export precedent does not audit; new write routes may not
   follow it in that respect);
5. keep the existing flat error envelope.

ADR-024 also replaces the MVP-7 alert read contract
(`GET /api/v1/sites/{site_id}/alerts`, `GET /api/v1/alerts/{alert_id}`)
with rule-aware reads — the explicit architecture decision this ADR
requires for a contract change (ADR-024 §19).

No generic write endpoint, query builder, dynamic SQL or direct frontend
database access is introduced. Status: **decided, not implemented** for
the alert routes.

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
