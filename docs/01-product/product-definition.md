# Product Definition

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-product-definition.md` v0.1.1 (archived), consolidated
here with the Product Owner Workshop's Q1–Q101 decisions folded in inline.
Related decisions: [ADR-001](../00-governance/decisions/ADR-001-product-vision-and-principles.md), [ADR-002](../00-governance/decisions/ADR-002-hierarchy-model.md), [ADR-006](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md)

> This consolidates `docs/product/ems-product-definition.md` (v0.1.1) and
> the relevant sections of the Product Owner Workshop baseline. Where the
> original v0.1.1 document tracked a question as "open" and the workshop has
> since decided it, that decision is stated here directly, with its Q-number
> citation — not left as a pointer. Both source documents are preserved
> verbatim at [../99-archive/superseded-product/](../99-archive/superseded-product/).

## 1. Product vision

See [product-vision.md](product-vision.md) for the one-page version. In
short: WiseWatts EMS is a facility intelligence system organized around
MONITOR → INVESTIGATE → (later: IMPROVE → MEASURE), not a chart-type
catalogue.

## 2. Target users

| Persona | Primary questions | Notes |
|---|---|---|
| **Facility / Energy Manager** (single site) | How is my site doing? Why is the bill up? Where is the waste? | The primary MVP persona (Workshop Q65). |
| **Portfolio / corporate energy lead** (multi-site) | Which sites are worst? Are we improving? | Portfolio is in MVP scope but the lowest-priority MVP experience (Workshop Q63/Q64). |
| **Plant / operations engineer** (industrial) | Equipment performance, demand peaks and their causes. | Shift/running-hours capabilities are `LATER`. |
| **Sustainability / ESG owner** | Carbon, reporting formats. | `LATER`. |
| **Executive / non-operational viewer** | One-glance status. | Read-mostly. |

Other B2B personas share the same underlying analytics — MVP does not build
separate role-specific dashboards (Workshop Q65). Whatever roles exist,
permission enforcement is **server-side** (SECURITY DEFINER functions +
session middleware); frontend permission checks gate navigation/UX only.

## 3. Product boundary

### 3.1 Administration App — existing, unchanged

Remains the administrative/operational interface: organisation, site, user,
device administration; configuration; onboarding/commissioning. Extended in
place with new `admin.*` functions; never rewritten by the customer-EMS
roadmap. See [ADR-006](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md).

### 3.2 Customer EMS Web Application — new

A new customer-facing application for understanding performance,
investigating behaviour, navigating sites/spaces/assets, analysing
consumption/demand, and — eventually — recommendations and reporting. It
consumes the Analytics API only ([ADR-007](../00-governance/decisions/ADR-007-analytics-api-boundary.md))
and must never directly expose raw telemetry structures, database
implementation details, or Grafana queries. It is **not** a redesign of the
Administration App; the two may share authentication/backend services
without merging.

### 3.3 Grafana — OPS/engineering surface

See [ADR-008](../00-governance/decisions/ADR-008-grafana-ops-role.md).
Grafana is retained for ops/engineering indefinitely; customer-facing
workflows migrate only through the Phase 17 per-workflow parity process.

### 3.4 The layering (product view)

```text
        Administration App                 Customer EMS Web Application
   (admin/ops; existing; intact)        (customer-facing; new; this product)
                │                                       │
                │  writes (admin.* functions)           │  reads only
                └───────────────┬───────────────────────┘
                                ▼
                        Analytics API  (Phase 7 query boundary — the contract)
                                ▼
                Semantic / Analytics Platform  (v_grafana_* views + functions,
                   config.parameters, asset/space relationships, derived params)
                                ▼
                  Telemetry / Data Platform  (MQTT → Telegraf → TimescaleDB,
                     energy_measurements, environment_measurements, …)

        Grafana  ── reads the same semantic layer, OPS/engineering only,
                    customer role retired workflow-by-workflow via Phase 17 parity
```

See [../04-architecture/application-architecture.md](../04-architecture/application-architecture.md)
for the full technical treatment.

## 4. `/app` — a routing detail, not the product identity

`/app` is the current staging route exposing the EMS Web Application — a
routing/deployment detail, not the application's architectural identity. The
EMS Web Application is treated as **independently deployable**: releasable
and rollbackable without changing the Administration App, Grafana, the
database, or the energy subsystem. Rolling it back has no effect on any of
those. See [../05-applications/ems-web/README.md](../05-applications/ems-web/README.md)
for the current delivery mechanism.

## 5. Core customer journey

```text
Login
  ↓
Organisation / Portfolio    (single-site customers land directly on Site Overview — Workshop Q62)
  ↓
Site
  ↓
Site Overview                   ("How are we doing?" — MONITOR; Workshop Q61/Q69/Q70)
  ↓
 ┌───────────────┬────────────────┬───────────────┐
 ↓               ↓                ↓
Energy        Environment       Assets
 ↓               ↓                ↓
Consumption   Temperature      Asset Performance
Demand        Humidity         Measurements
(Cost, later) (other params)
 ↓
Analytics                       ("Why is this happening?" — INVESTIGATE)
 ↓
Report / Action                 (IMPROVE / MEASURE — later)
```

Detailed screen-by-screen treatment:
[../03-ux-and-design/information-architecture.md](../03-ux-and-design/information-architecture.md).

## 6. Information hierarchy principle

The customer-facing experience uses the **semantic model**
(`Organisation/Portfolio → Site → Space → Asset`, per
[ADR-002](../00-governance/decisions/ADR-002-hierarchy-model.md)), not
telemetry/database structures. The customer sees `Radisson Blu → Banquet
Hall 2 → Temperature → 24.3 °C`, never device IDs, logical-point IDs, or raw
field names. **Resolved (Workshop Q51, Q99):** Space is a drill-down target,
not primary top-level navigation.

## 7. Product principles

1. Business questions first, not chart types.
2. Semantic vocabulary only — no raw telemetry terminology, no implementation identifiers, no Grafana queries.
3. Progressive investigation — every "how are we doing" number has a path to "why."
4. The Analytics API is the only door.
5. Performance is a product requirement, not an afterthought.
6. "No data" is a normal state, never an error.
7. Quality is always visible (`GOOD / GAP / ESTIMATED / INVALID / PARTIAL`); the product never invents a quality value the API doesn't provide.
8. Role-appropriate views; enforcement is server-side.
9. Don't clone any reference product's navigation, terminology, or layout.
10. The frozen architecture wins — no product requirement silently forces an architecture change.

## 8. Terminology

See [terminology.md](terminology.md) for the full customer-facing vocabulary
and its platform-internal mapping.

## 9. Product goals (v0.1)

- **G1 — One honest number.** Answer "how is my site doing" in one screen with a comparison and visible data quality.
- **G2 — A cheap next question.** One step toward "why," without leaving the flow.
- **G3 — Their vocabulary.** No device IDs, logical-point IDs, or Grafana artefacts.
- **G4 — Portfolio and site.** Multi-site customers get roll-ups; single-site customers aren't taxed with portfolio ceremony.
- **G5 — Trust.** No-data/partial/estimated shown truthfully; numbers match Grafana (parity discipline).
- **G6 — Independently shippable.** Ships and rolls back on its own.
- **G7 — A path to intelligence.** Supports IMPROVE/MEASURE later without a rebuild — nothing AI ships before its phase.

## 10. Product non-goals (v0.1)

Not a rebuild of the Administration App · not a Grafana replacement for ops/
engineering · not a generic query builder / metric explorer / raw-tag
browser · not a place exposing telemetry structure or implementation
identifiers · not an AI product in the near term · not a billing engine ·
not a driver of schema change · not a reason to modify Phase 6, the energy
subsystem, Grafana, or the Phase 7 API contract without an explicit,
separate architecture decision · not a clone of a reference product's
navigation, terminology, or layout.

## 11. Relationship to the frozen architecture

Consistent with, and subordinate to, the DDS: Organisation → Site structure
and tenant isolation on every row; Space/Asset/Point/Parameter semantics; the
Analytics API boundary as the only customer read path; Grafana's OPS/
engineering role and Phase 17 parity strategy; energy-subsystem stability.
See [../04-architecture/README.md](../04-architecture/README.md).

## 12. Product decisions — resolved by the Product Owner Workshop

The following were open in v0.1 (2026-09-10) and are now decided (Q49–Q101,
2026-09-11). See [../00-governance/decisions/](../00-governance/decisions/)
for the formal decision records and
[../02-requirements/requirements-traceability.md](../02-requirements/requirements-traceability.md)
for implementation status.

| # | Question | Resolution |
|---|---|---|
| 1 | First landing page after login | Site Overview / Energy Health (Q61, Q88) |
| 2 | Portfolio-first vs. site-first | Site is primary; single-site customers land directly on Site Overview (Q62, Q63) |
| 3 | Five headline things on Site Overview | Overall Health → Attention → Energy Performance → Max Demand → Power Quality → investigation paths (Q70, Q71, Q72) |
| 4 | How customers select among multiple sites | Touched by Q90 (search/quick nav); exact interaction pattern still a design detail |
| 5 | Which roles exist in the customer application | Facility/Energy Manager is primary (Q65); mapping to existing `ADMIN`/`OPERATOR`/`VIEWER` roles is an implementation task |
| 6 | How alerts appear and are configured | **In-product only** — email removed 2026-09-14, superseding the archived Q78 email statement (Q77; [ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md)); full lifecycle/state/retention/recurrence/filtering behavior now decided; configuration stays in the Administration App (Q67) |
| 7 | Which energy-cost capabilities are required | Financial visibility is MVP scope wherever accurate/sufficiently configured (Q73); no tariff schema exists yet — a data dependency, not an open scope question |
| 8 | Initial target industries | **Still open** — not addressed by Q49–Q101 |
| 9 | How much asset detail customers see | A narrower, data-driven version of the common analytical experience (Q100) |
| 10 | Required reporting formats | Partially resolved — Q76 gives the general shape (simple, derived, no builder); specific export formats undecided |
| 11 | Space: primary nav or drill-down | Drill-down (Q51, Q99) — see [ADR-002](../00-governance/decisions/ADR-002-hierarchy-model.md) |
| 12 | How functional categories are defined | **Still open** — not addressed by Q49–Q101 |
| 13 | What "normal"/baseline performance means | Historical comparison (previous/same-period-previously/rolling average) is the MVP default; configured expectation used where supplied (Q54–Q56, Q97) |

### Product owner's five key questions

1. **First thing a customer sees on login?** → Site Overview / Energy Health (Q61, Q88).
2. **Portfolio level or site level?** → Site is primary (Q62).
3. **Five most important things about the facility?** → Site Overview information hierarchy (Q70, Q71).
4. **How far should investigation go?** → Site → Space → Asset (Q51, Q58).
5. **What should EMS do substantially better than reference products?** → **Still open** — a genuine differentiation question, not an implementation dependency.
