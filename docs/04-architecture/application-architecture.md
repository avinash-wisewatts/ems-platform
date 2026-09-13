# Application Architecture

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Architecture
Source of truth: `ems-product-architecture.md` v0.1 (archived), consolidated here.
Related decisions: [ADR-006](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md), [ADR-007](../00-governance/decisions/ADR-007-analytics-api-boundary.md), [ADR-008](../00-governance/decisions/ADR-008-grafana-ops-role.md)

> This document does **not** replace the DDS. It describes only the
> product-facing architecture — application boundaries, the API boundary,
> customer-vs-admin responsibilities, and deployment principles.

## The stack, product view

```text
┌─────────────────────────────┐        ┌─────────────────────────────────────┐
│      Administration App      │        │   Customer EMS Web Application        │
│  (existing admin-portal)      │        │   (new; this product)                │
│  FastAPI + Jinja2, server-    │        │   React / TypeScript SPA             │
│  rendered                     │        │                                     │
│  admin / ops / onboarding     │        │   MONITOR → INVESTIGATE → (IMPROVE)  │
└──────────────┬───────────────┘        └──────────────────┬──────────────────┘
               │ writes                                    │ reads only
               │ (admin.* SECURITY DEFINER functions,      │ (GET /api/v1/*)
               │  onboarding_audit)                        │
               └───────────────┬──────────────────────────┘
                                ▼
                 ┌───────────────────────────────────┐
                 │          Analytics API             │   ← the contract (Phase 7)
                 │   /api/v1/*  — semantic, read-only │
                 │   flat error envelope, session     │
                 │   auth, server-side tenant/space   │
                 │   authorisation                    │
                 └───────────────┬───────────────────┘
                                 ▼
                 ┌───────────────────────────────────┐
                 │   Semantic / Analytics Platform    │
                 │   v_grafana_* views + functions,   │
                 │   config.parameters, asset &       │
                 │   asset↔space relationships,       │
                 │   parameter_calculations,          │
                 │   analytics.derived_parameter_values│
                 └───────────────┬───────────────────┘
                                 ▼
                 ┌───────────────────────────────────┐
                 │   Telemetry / Data Platform        │
                 │   MQTT → Telegraf → TimescaleDB,   │
                 │   energy_measurements (+5-tier     │
                 │   ladder), environment_measurements,│
                 │   demand_intervals, pipeline_state  │
                 └───────────────────────────────────┘

   Grafana ──► reads the same Semantic layer (v_grafana_*), OPS/engineering only.
              Customer-facing Grafana workflows retire workflow-by-workflow via
              the Phase 17 parity process. Grafana is never the customer UI.
```

This is the DDS's own layering (§F) — nothing here is new architecture.

## Application boundaries

| Aspect | Administration App | Customer EMS Web Application |
|---|---|---|
| Purpose | Org/site/user/permission/device administration, configuration, onboarding | Facility performance, investigation, navigation, analytics |
| Status | Existing, operationally intact, extended in place | New, additive, Phases 8–17 |
| Technology | FastAPI + server-rendered Jinja2 (`app/`) | React/TypeScript SPA |
| Write authority | The **sole write path** for metadata | **None** near term — read-only product |
| Data access | Direct DB, via `admin.*` functions | Read-only via the Analytics API only — no DB/TimescaleDB/Grafana access, no query builder, no dynamic SQL |
| Relationship | Not a redesign target | Not a redesign of the Administration App; may share auth/backend without merging |

**Grafana** remains the OPS/engineering surface, retired from the customer
role only workflow-by-workflow after each workflow's Phase 17 parity gate +
bake-in period — see [ADR-008](../00-governance/decisions/ADR-008-grafana-ops-role.md).

## The API boundary (Phase 7 Analytics API)

See [api-architecture.md](api-architecture.md) for the full contract.

## Customer vs. admin responsibilities

| Concern | Administration App | Customer EMS Web App |
|---|---|---|
| Create/edit organisations, sites, users, roles, devices, assets | ✅ owns it | ❌ never |
| Onboarding / commissioning | ✅ owns it | ❌ (may *show* status via the API) |
| Define asset relationships, parameter calculations, routing config | ✅ owns it | ❌ (consumes the resulting semantics) |
| Configure alert rules, functional categories, tariffs | ✅ primary owner | ❌ near term |
| View site/space/asset performance, energy, environment, demand | ⚠️ not its job | ✅ owns it |
| Investigate anomalies / drill down | ⚠️ not its job | ✅ owns it |
| Reports / exports (customer formats) | ❌ | ✅ (MVP-6) |
| Ops diagnostics, SQL playbooks, pipeline health | via Grafana / [10-operations/](../10-operations/) | ⚠️ a customer-facing data-quality view (MVP-4), not the ops playbook |

## Semantic-model exposure rules

**Exposed to customers** (their vocabulary): Organisation/Portfolio, Site/
Facility, Space/Area, Asset/Equipment/System, Parameter, Measurement/
Reading with context, Consumption, Demand/Peak Demand, Cost (later),
Comfort/Environment, Performance, Data quality.

**Never exposed**: `device_id`, `logical_point_id`, `raw_field_name`,
profile/mapping identifiers, hypertable/view/function names, internal
`quality_code` integers, Grafana org IDs/datasource UIDs, migration numbers,
table columns, SQL. Where an identifier must appear in a URL for
deep-linking, it is an **opaque semantic ID** already surfaced by the API —
never a telemetry identifier.

## `/app` and independent deployment

`/app` is the current staging route exposing the EMS Web Application — a
routing/deployment detail, not the application's architectural identity.
See [deployment-architecture.md](deployment-architecture.md) for the
current delivery mechanism and [../05-applications/ems-web/README.md](../05-applications/ems-web/README.md).

## Known product-architecture gaps (PA-1 through PA-6)

For product-owner and architecture-review attention. None blocks the
documentation set itself; several block specific screens — cross-referenced
throughout [02-requirements/](../02-requirements/) and
[03-ux-and-design/](../03-ux-and-design/).

| # | Gap | Impact | Status |
|---|---|---|---|
| PA-1 | Phase 7's first slice covers only sites + energy consumption + space environmental series (+`/me`). Almost every screen needs API surface that doesn't exist yet. | Expected — sequenced across MVP-1..MVP-8. | Tracked in [../02-requirements/requirements-traceability.md](../02-requirements/requirements-traceability.md). |
| PA-2 | "Functional categories" have no obvious home in the frozen model. | Cannot design category-based navigation until resolved. | **Still genuinely open** — not addressed by Q49–Q101. |
| PA-3 | "Cost" requires `config.tariffs`/`analytics.cost_values`, conditional on a real customer requirement. | Verified: no such table exists anywhere in the schema. | Resolved at the scope level (Q73/Q74); data dependency remains real. |
| PA-4 | No frontend customer-write path exists; configuration lives in the Administration App. | Near-term product is read-only. | Resolved by Q67 — configuration stays in the Administration App. |
| PA-5 | "Correlations" imply multi-parameter alignment, edging toward a query builder — a non-goal. | Correlations must be curated, never free-form. | Not required by Q49–Q101; Post-MVP. |
| PA-6 | Portfolio/corporate consolidated views need a cross-site aggregation surface the API doesn't define. | Portfolio depth resolved at scope/priority level (Q63/Q64); shape still not landed. | MVP-8, lowest priority. |
