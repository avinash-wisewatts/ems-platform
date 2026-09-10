# WiseWatts EMS — Product Architecture

> **Status:** WORKING DRAFT  ·  **Version:** 0.1  ·  **Owner:** Product  ·  **Last updated:** 2026-09-10
>
> **Source basis:** `docs/DDS/analytics-platform-future-state-architecture.md` (§F, §F.0, §C, §E), the implementation roadmap (Phases 7–17), PR #44, `docs/operations/CICD_PIPELINE.md`, `docs/operations/PHASE8_FRONTEND_DEPLOYMENT.md`, `docs/platform-manual/12-grafana.md`, ZeroWatt technical overview (reference only).
>
> **This document does NOT replace the DDS.** The DDS remains authoritative for platform architecture. This document describes only the **product-facing** architecture — application boundaries, the API boundary, customer-vs-admin responsibilities, and deployment principles — and always defers to the DDS on anything conceptual.

---

## 1. The stack, product view

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

`[ARCH-CONSTRAINT]` This is the DDS's own layering (§F "the frontend, whichever surface renders it, should consume domain-shaped read views/functions, never raw tables"; §F.0 application-surfaces boundary). Nothing here is new architecture.

---

## 2. Application boundaries

### 2.1 Administration App

| Aspect | Statement | Evidence |
|---|---|---|
| Purpose | Organisation / site / user / permission / device administration; configuration; onboarding; operational/admin workflows | `[ARCH-CONSTRAINT]` DDS §F.0, roadmap compat table |
| Status | Existing; **left operationally intact**; extended in place with new `admin.*` write functions; never rewritten by this roadmap | `[ARCH-CONSTRAINT]` |
| Technology | FastAPI + server-rendered Jinja2 templates (`app/`) | `[ARCH-CONSTRAINT]` DDS §A.7 |
| Write authority | The **sole write path** for metadata; new relationship tables get `admin.*` functions following the existing permission-check + audit-log pattern | `[ARCH-CONSTRAINT]` roadmap Phase 7, compat table |
| Customer EMS relationship | The customer EMS is **not** a redesign of it; they are separate applications | `[WISEWATTS-DECISION]` PR #44 |

### 2.2 Customer EMS Web Application

| Aspect | Statement | Evidence |
|---|---|---|
| Purpose | Understand facility/site performance; investigate energy & environmental behaviour; navigate sites/spaces/assets; analyse consumption & demand; understand equipment performance; identify problems; **eventually** recommendations / intelligence / reporting / sustainability | `[WISEWATTS-DECISION]` |
| Status | **New**; additive; the subject of Phases 8–17 on the frontend side | `[ARCH-CONSTRAINT]` roadmap |
| Technology | React / TypeScript SPA (Phase 8 foundation already built and staged) | `[ARCH-CONSTRAINT]` `PHASE8_FRONTEND_DEPLOYMENT.md` |
| Data access | **Read-only, via the Analytics API only.** No direct DB/TimescaleDB/Grafana/internal-object access. No query builder. No dynamic SQL. | `[ARCH-CONSTRAINT]` DDS §F, roadmap Phases 8–15 |
| Must not expose | Raw telemetry structures; database implementation details; internal tables; Grafana queries; implementation-specific identifiers | `[ARCH-CONSTRAINT]` PR #44, product brief §2 |
| Write actions | Near term: **none** (read-only product). Any future customer-initiated configuration (e.g. self-configurable alerts) routes through an Administration-App-owned mechanism / dedicated `admin.*`-style function, never ad-hoc frontend writes | `[INFERRED]` from the "configuration belongs primarily in the Administration App" principle |

### 2.3 Grafana

| Aspect | Statement | Evidence |
|---|---|---|
| Role | OPS / engineering visualisation surface; retained indefinitely | `[ARCH-CONSTRAINT]` roadmap Phase 17 exit criteria |
| Customer role | Retired **workflow-by-workflow** only after that workflow's Phase 17 parity gate + bake-in period | `[ARCH-CONSTRAINT]` |
| Customer EMS relationship | The EMS Web Application does not embed, proxy, or depend on Grafana. It reads the same semantic layer through the Analytics API. | `[WISEWATTS-DECISION]` |

---

## 3. The API boundary (Phase 7 Analytics API)

`[ARCH-CONSTRAINT]`

- **Shape:** semantic, read-only `GET /api/v1/*`. Flat top-level error envelope `{"error": "<code>", "detail": "<message>"}` (401 `unauthenticated`, 403, 404 `not_found`, 422 `invalid_parameter` / `invalid_resolution` / `invalid_request`).
- **Auth:** the existing signed session cookie (`ems_admin_session`), shared with the Administration App. Served same-origin so the cookie flows automatically. No second auth system, no CORS, no CSRF token for GET-only reads.
- **Authorisation:** enforced **server-side** — SECURITY DEFINER functions (`analytics.portal_user_can_access_space`, tenant filters, `${__org.id}`-equivalent scoping) + session middleware. Frontend permission checks are UX-only.
- **First slice already live (Phase 7):**
  - `GET /api/v1/me` — session echo: identity + derived permission codes. Additive; no DB, no secrets.
  - `GET /api/v1/sites` — scope-filtered site list (`site_id`, `site_code`, `site_name`, `organization_id`, `timezone`).
  - `GET /api/v1/sites/{site_id}/energy/consumption` — energy consumption series (`from`, `to`, `resolution`; `no_data` is a normal 200).
  - `GET /api/v1/spaces/{space_id}/measurements` — environmental series (`parameter` ∈ {TEMPERATURE, HUMIDITY, DEW_POINT}, `resolution` ∈ {raw, 1h}; `no_data` normal 200; inaccessible/unknown → 404 with no existence leak). DEW_POINT is consumed from the Phase 6 persisted tier — **never recalculated in the browser**.
- **Extension model:** additive `v_grafana_*` views/functions + thin FastAPI only for what a view cannot express (Phase 7's stated pattern). **No change to the existing Phase 7 contract without an explicit architecture decision.**

`[WISEWATTS-DECISION]` The product treats the Analytics API as the single source of truth for what the customer can be shown. If a screen needs data the API does not expose, that is a **dependency to be scheduled**, not a reason to bypass the boundary. Tracked in `docs/product/ems-requirements-traceability.md`.

---

## 4. Customer vs. admin responsibilities

| Concern | Administration App | Customer EMS Web App |
|---|---|---|
| Create/edit organisations, sites, users, roles, devices, gateways, assets | ✅ owns it | ❌ never |
| Onboarding / commissioning | ✅ owns it | ❌ (may *show* commissioning/connectivity status via the API) |
| Define asset relationships, asset↔space "serves" maps, parameter calculations, routing config | ✅ owns it (new `admin.*` functions) | ❌ (consumes the resulting semantics) |
| Configure alert rules, functional categories, tariffs | ✅ primary owner `[INFERRED]` | ❌ near term; possible *assisted* configuration later, routed through admin mechanisms — `[OPEN]` |
| View site/space/asset performance, energy, environment, demand | ⚠️ not its job | ✅ owns it |
| Investigate anomalies / drill down | ⚠️ not its job | ✅ owns it |
| Reports / exports (customer formats) | ❌ | ✅ (Phase 15) |
| Ops diagnostics, SQL playbooks, pipeline health | via Grafana / `19-operations-and-diagnostics.md` | ⚠️ a customer-facing *data-quality* view exists (Phase 12), not the ops playbook |

`[OPEN]` The exact split for **self-configurable alerts** and **functional-category definition** — how much, if any, the customer does vs. an admin — is `OPEN — PRODUCT DECISION REQUIRED`.

---

## 5. Semantic-model exposure rules

`[ARCH-CONSTRAINT] + [WISEWATTS-DECISION]`

**Exposed to customers** (their vocabulary): Organisation/Portfolio, Site/Facility, Space/Area, Asset/Equipment/System, Parameter (as a friendly name + unit), Measurement/Reading with context, Consumption, Demand / Peak Demand, Cost (later), Comfort/Environment, Performance, Data quality (`GOOD/GAP/ESTIMATED/INVALID/PARTIAL`), Functional category (definition `[OPEN]`), Running hours (later).

**Never exposed to customers:** `device_id`, `logical_point_id`, `raw_field_name`, profile/mapping identifiers, hypertable/view/function names, `quality_code` internal integers (mapped to the five friendly states), Grafana org IDs / datasource UIDs / `${__org.id}`, migration numbers, table columns, SQL.

`[WISEWATTS-DECISION]` Where an identifier must appear in a URL for deep-linking, it is an **opaque semantic ID** already surfaced by the API (`site_id`, `space_id`, an asset id) — not a telemetry identifier, and never a raw field name.

---

## 6. Authentication & authorisation principles

`[ARCH-CONSTRAINT]`

1. **One session mechanism**, shared with the Administration App (`ems_admin_session`, `SameSite=Lax`, host-scoped, signed). No parallel auth system. No credentials or session secrets exposed to JavaScript.
2. **Same-origin delivery** so the cookie flows to `/api/v1` automatically; unauthenticated access to the EMS Web App redirects to the existing `/login`.
3. **Server-side authorisation is authoritative.** Tenant isolation and per-resource access (site/space/asset) are enforced by the API's SECURITY DEFINER functions and session middleware.
4. **Frontend permission checks gate navigation/UX only** — hiding a nav item is a convenience, not a control.
5. **Roles in the customer EMS are `[OPEN]`** — not assumed to equal the Administration App's role set. `OPEN — PRODUCT DECISION REQUIRED`.
6. **No customer-facing Grafana auth path.** The EMS Web App does not authenticate against or embed Grafana.

---

## 7. `/app` and independent deployment

`[ARCH-CONSTRAINT]` (from DDS §F.0 via PR #44) + `[WISEWATTS-DECISION]` (deployment approach)

- `/app` is the **current staging route** exposing the EMS Web Application. It is a **routing/deployment detail**, not the application's architectural identity. The final product boundary is the EMS Web Application itself. No commitment to `/app` permanently.
- The EMS Web Application is **independently deployable**: independently releasable and rollbackable **without changing the Administration App**.
- **Preferred** implementation/deployment: a **separate EMS Web Application image/container**. This is an **implementation/deployment decision, not a frozen conceptual-architecture requirement** — the DDS does not mandate container topology.
- **Rollback isolation:** rolling the EMS Web Application back has **no effect** on the Administration App, Grafana, the database, Phase 6 pipelines, or the energy subsystem.
- **Current staging delivery mechanism (Phase 8):** an independently versioned `ghcr.io/<repo>-web:<sha>` artifact carrying only the static bundle, extracted read-only into the admin-portal container at `/app/src/spa` and served same-origin under `/app` by the existing FastAPI hook. This is a *delivery mechanism chosen because no reverse proxy exists yet*; it is not the product boundary and is expected to evolve (e.g. a dedicated container behind a proxy) without changing anything in this document. See `docs/operations/PHASE8_FRONTEND_DEPLOYMENT.md`.
- **CI/CD:** "build once → test → promote the same artifact" (`docs/operations/CICD_PIPELINE.md`). The `-web` artifact is SHA-addressed and digest-pinnable, promotable staging → production unchanged. No production action is authorised by this document.

---

## 8. Relationship to the authoritative DDS

`[ARCH-CONSTRAINT]`

- **The DDS remains authoritative for platform architecture.** `docs/DDS/analytics-platform-future-state-architecture.md` is CONCEPTUALLY FROZEN; `...-implementation-roadmap.md` defines the phases.
- This document is **subordinate**: it describes the product-facing view and must not contradict the DDS. Where this document and the DDS appear to disagree, the DDS wins and this document is corrected.
- **No conceptual change** is proposed here: no new core entity, no change to Organisation/Site/Space/Asset/Point/Parameter semantics, asset relationships, temporal binding, tenant isolation, declarative routing, persisted derived calculations, quality semantics, the `SPACE_DEW_POINT` implementation, the Phase 7 API contract, or the Grafana transition strategy.
- The only DDS edit related to this product effort is the already-merged PR #44 (new §F.0 + Phase 8 wording), which made the application/deployment boundary explicit **without** changing the frozen model.
- Product requirements that would require an architecture change are **not adopted**; they are logged as explicit dependencies in `ems-customer-requirements.md` / `ems-requirements-traceability.md` and referred to architecture review.

---

## 9. Known product-architecture gaps / contradictions discovered

`[INFERRED]` — for product-owner and architecture-review attention. None of these block v0.1 documentation.

| # | Gap / tension | Impact | Where tracked |
|---|---|---|---|
| PA-1 | Phase 7 first slice exposes only sites + energy consumption + space environmental series (+`/me`). Almost every screen in `ems-information-architecture.md` needs API surface that **does not exist yet** (demand, breakdown, asset performance, trends/comparisons, portfolio roll-ups, alerts, cost, reports). | Expected — the roadmap sequences these (Phases 9–15). Product docs mark each screen's API dependency as `PLANNED` or `MISSING`. | traceability doc |
| PA-2 | "Functional categories" (a ZeroWatt-observed grouping concept) has **no** obvious home in the frozen model. It may map to `asset_type_id`, an asset-relationship type, a VIRTUAL asset, or site energy-meter roles — or need a new config concept (which the freeze rules resist). | Cannot design category-based navigation until resolved. | `[OPEN]` #12; traceability doc |
| PA-3 | "Cost" requires `config.tariffs` / `analytics.cost_values`, explicitly **conditional on a real customer requirement** (roadmap Phase 14). Product must not assume cost screens are guaranteed. | Cost is `SHOULD`/`LATER`, not `MUST`. | `[OPEN]` #7 |
| PA-4 | Customer **write** actions (self-configurable alerts, saved views, report schedules) have no frontend write path today and the architecture pushes configuration into the Administration App. A customer-facing "save my alert" needs an explicit, audited mechanism. | Alerts/reports configuration UX is constrained; near-term product is read-only. | §4; `[OPEN]` #6 |
| PA-5 | "Correlations" (e.g. energy vs. temperature) implies multi-parameter, possibly cross-domain series alignment. The derived-parameter framework (§B.7) can express *derived* values, but ad-hoc customer-chosen correlations edge toward a query builder, which is a non-goal. | "Correlations" must be **curated**, not free-form. | traceability doc |
| PA-6 | Portfolio / corporate consolidated views need cross-site aggregation surface in the API; the roadmap mentions "site and corporate views" only as a capability, not a phase deliverable with a defined shape. | Portfolio depth is `SHOULD` + `[OPEN]` #2. | roadmap doc, `[OPEN]` #2 |

---

## 10. Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial working draft. Layering, application boundaries, API boundary, responsibilities, semantic-exposure rules, auth principles, `/app` + independent-deployment principle, DDS relationship, gaps PA-1..PA-6. |
