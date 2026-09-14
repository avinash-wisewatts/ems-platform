# Product Roadmap (customer-outcome view)

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-product-roadmap.md` v0.2 (archived), verified against
`origin/staging` state as of 2026-09-11.

> This does **not** change the authoritative technical roadmap
> (`docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md`,
> Phases 0–17). It sequences the customer-facing MVP work that roadmap's
> Phases 7–17 imply, against the Product Owner Workshop's Q49–Q101 decisions.
> Where this document and the DDS roadmap could drift, the DDS roadmap wins;
> where this document and the workshop baseline could drift, the workshop
> baseline wins.

## Mapping principle

Every customer capability traces to a **screen**
([03-ux-and-design/](../03-ux-and-design/)), an **API capability** (Phase 7
boundary), and a **semantic/data capability** (a DDS mechanism). If any of
the three is missing, the capability is not "ready" regardless of how
finished the UI looks — enforced by
[../02-requirements/requirements-traceability.md](../02-requirements/requirements-traceability.md).
Every phase still requires its own explicit approval before any staging or
production change.

## Completed foundation (verified on `origin/staging`, 2026-09-11)

### Phase 7 — Analytics API / Query Boundary — **DONE**

Landed: `b923f88`, `6225970` (PR #43). Live: `GET /api/v1/sites`,
`GET /api/v1/sites/{id}/energy/consumption` (`1h`/`1d`),
`GET /api/v1/spaces/{id}/measurements` (TEMPERATURE/HUMIDITY/DEW_POINT;
`raw`/`1h`). Tenant/site/space access enforced server-side; `no_data` is a
normal 200. Not yet extended: Demand, Power Quality, Asset, comparison/
baseline, Attention, cost, alert, export, or reporting endpoints — the
majority of remaining MVP work.

### Phase 8 — Frontend Foundation (EMS Web Application shell) — **DONE**

Landed: `e5fd026`…`7c4349a` (10 commits) + PR #44 (boundary doc). Live: `GET
/api/v1/me` session bootstrap; `SessionProvider`/`TenantProvider`/
`RequirePermission`; shared time-range component; one charting foundation;
`QualityIndicator`/`EmptyState`/`ErrorState`/`NoDataYet`/`Loading`; app
shell/router/navigation. Confirmed **not** built: `PlaceholderArea.tsx` is
the literal content of every feature screen — no Spaces, Assets, Demand, PQ,
Attention, Portfolio, Alerts, Export, or Reports screen exists yet. This
matches the DDS roadmap's own Phase 8 exit criterion ("empty shell").

## MVP completion work

> **Status update (2026-09-13):** MVP-1, MVP-2, and MVP-3 below were
> written from the 2026-09-11 verification session, which found them all
> unbuilt. `origin/staging` has since moved (Slice 0/A → PR #46, Slice B →
> PR #48, Slice C → PR #49, MVP-1 closeout + MVP-3 → PR #50, commit
> `ddbe5a4`) and all three are now **DONE**. Scope/decisions-served content
> below is retained as the original planning record; status lines are
> updated in place with the landing evidence.

### MVP-1 (DDS Phase 9 core) — Hierarchy & Navigation Foundation — **DONE**

- **Objective**: let a customer reach a space or asset by name — the
  foundation every other MVP screen depends on.
- **Scope**: "spaces for a site" and "assets for a site" list endpoints,
  real Spaces/Assets list/detail screens replacing `PlaceholderArea`.
- **Out of scope**: the full interactive component-tree navigator (see
  [ADR-013](../00-governance/decisions/ADR-013-deferred-asset-component-tree.md)) —
  still deferred; not delivered by MVP-1.
- **Major decisions served**: Q51 (Site→Space→Asset), Q99 (Space as
  drill-down), Q100 (Asset — narrower, data-driven), Q62 (Site as primary
  context), Q101 (navigation context always visible). See
  [ADR-002](../00-governance/decisions/ADR-002-hierarchy-model.md).
- **Implementation status**: **Landed** — PR #46 (Slice 0), closed out by
  PR #50 (2026-09-13): `GET /api/v1/sites/{site_id}/spaces`,
  `GET /api/v1/sites/{site_id}/assets`; real `SpacesList`/`SpaceDetail`,
  `AssetsList`/`AssetDetail` screens; two-section primary nav; `HierarchyCrumb`
  `multiSite` segment.

### MVP-2 (DDS Phase 10 core) — Core Energy Analytics — **DONE**

- **Objective**: answer "how much energy," "what's our demand," "is our
  power quality OK," each with comparison.
- **Scope**: Energy Consumption comparison; Maximum Demand; Power Quality/
  PF/THD.
- **Major decisions served**: Q50/Q52 (core analytical questions), Q54–Q56/
  Q97 (comparison baseline), Q84 (automatic comparison periods), Q94–Q96
  (per-area experience).
- **Implementation status**: **Landed** — Slice A (PR #46,
  `EnergyOverview`), Slice B (PR #48, `DemandOverview`/
  `PowerQualityOverview`, `GET /api/v1/sites/{id}/demand`,
  `GET /api/v1/sites/{id}/power-quality`), Slice C (PR #49, the historical
  "typical reference" comparison — see
  [ADR-009](../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md)).

### MVP-3 (DDS Phase 9/10 composite) — Site Overview & Attention — **DONE**

- **Objective**: one coherent landing screen answering "how am I doing, and
  is there anything I need to pay attention to?"
- **Scope**: a real composite Site Overview screen built from MVP-1/MVP-2's
  endpoints; a predefined-condition Attention surface (thresholds on
  existing metrics — no anomaly scoring, no ML).
- **Out of scope**: intelligent ranking, root-cause explanation, or
  recommendations on the Attention surface (see
  [ADR-012](../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md)).
- **Major decisions served**: Q61 (landing experience), Q70/Q71 (information
  hierarchy, Overall Health as plain summary), Q57/Q72/Q98 (Attention —
  analytical, not intelligent), Q79 (healthy-state messaging), Q80
  (insufficient-data states — see
  [ADR-011](../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md)).
- **Depends on**: MVP-1 (hierarchy) + MVP-2 (analytics) — both landed
  first, as sequenced.
- **Implementation status**: **Landed** — PR #50, commit `ddbe5a4`
  (2026-09-13): `SiteOverview.tsx` replaces `ShellHome`; Energy Attention
  (±15% materiality — see
  [ADR-010](../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md))
  and three-state Site Health (Healthy / Needs Attention / Insufficient
  Data) both implemented. See
  [../08-verification/staging-validation.md](../08-verification/staging-validation.md)
  for the staging validation record.

### MVP-4 (DDS Phase 12, narrowed) — Data Quality & Freshness

- **Scope**: the `QualityIndicator` primitive (already scaffolded) backed by
  real `quality_code`/freshness state on energy and demand series, not just
  space measurements.
- **Decisions served**: Q59/Q60 (evidence and trust), Q81 (freshness
  visible), Q93 (customer-friendly errors).
- **Note**: a full connectivity/ops-style diagnostic screen is Post-MVP
  unless a later decision expands it.

### MVP-5 — Content & Metric Grammar

- **Scope**: copy/content work — definitions, units, contextual qualifiers —
  layered onto MVP-2/3's screens. Not a platform dependency; can run in
  parallel once those screens exist.
- **Decisions served**: Q83, Q85, Q86, Q87.

### MVP-6 (DDS Phase 15, narrowed) — Export & Basic Reporting

- **Decisions served**: Q75 (export — underlying data + context, not a BI
  tool), Q76 (reporting — deliberately simple, no scheduling/builder/
  narratives).
- **Depends on**: MVP-3 (reporting source) + MVP-2 (the figures exported).
- **Q75 (Export) — decided in full, not yet implemented (2026-09-14)**:
  content, context fields, format (CSV), delivery model, availability,
  comparison-basis behavior, time-range bounds, and data-gap/no-data
  handling are all now specified. See
  [ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md)
  and [02-requirements/functional-requirements.md §Export](../02-requirements/functional-requirements.md#export)
  (`EMS-REQ-094`–`EMS-REQ-099`).
- **Q76 (Reporting) — one report type decided and implemented, not yet
  deployed (2026-09-14)**: the Site Performance Report (catalogue,
  configuration, generation, structure, optional PDF, error handling) is
  decided and built. See
  [ADR-015](../00-governance/decisions/ADR-015-q76-site-performance-report.md)
  and [02-requirements/functional-requirements.md §Site Performance Report](../02-requirements/functional-requirements.md#site-performance-report)
  (`EMS-REQ-110`–`EMS-REQ-116`). **The rest of Q76 remains open** — Excel
  format, any additional report type, and a general report-definition
  storage mechanism are undecided.

### MVP-7 (DDS Phase 10, deferred sub-scope) — Basic Alerts

- **Decisions served**: Q77 (basic alerts on measurable conditions), Q78
  (in-product + email delivery), Q67 (configuration stays in the
  Administration App).
- **Depends on**: MVP-3's Attention thresholds.

### MVP-8 (DDS Phase 9/13, narrowed) — Portfolio Experience

- **Decisions served**: Q63/Q64 (portfolio is in scope but explicitly the
  **lowest-priority** MVP experience).
- **Depends on**: MVP-1/2/3 existing per-site first.
- **Sequencing note**: placed last because the workshop decided its
  priority is lowest, not purely a technical dependency.

### Financial / tariff track — cross-cutting, data-dependent

- **Decision served**: Q73/Q74 (financial visibility is MVP scope wherever
  accurate and sufficiently configured; otherwise show the underlying
  technical metric).
- **Verified**: no tariff, contracted-demand-limit, or cost table exists
  anywhere in the schema — a genuine data/configuration dependency, not an
  implemented-but-hidden capability. Does not block MVP-2's own work.

## Post-MVP (explicitly deferred by the workshop)

Recommendations, root-cause intelligence, adaptive/predictive baselines,
action logging/verification workflows, AI, automation, sophisticated
benchmarking (Q1–Q48 long-term direction); a dedicated connectivity/ops-style
Data Quality screen beyond freshness visibility; multi-channel alert
delivery beyond in-product+email; DDS Phase 11 (Asset Performance / motor
condition monitoring), Phase 13 (baseline overlays, cross-asset league
tables), Phase 14 (cost/benchmarking/insights foundations), Phase 16
(hardening/scale) — real technical phases, not cancelled, simply not
required by Q49–Q101 and sequenced after MVP completion. Phase 17 (Grafana
migration) is an ongoing parity-gated process starting once MVP-2's numbers
are parity-proven against Grafana.

## Capability → stage summary

| Customer capability | MVP stage | Status (2026-09-13, verified against commit `ddbe5a4`) |
|---|---|---|
| Site/Space/Asset navigation | MVP-1 | **DONE** |
| Energy Consumption + comparison | MVP-2 | **DONE** (Slice A + Slice C) |
| Maximum Demand | MVP-2 | **DONE** (Slice B) |
| Power Quality (PF/THD) | MVP-2 | **DONE** (Slice B) |
| Site Overview | MVP-3 | **DONE** |
| Attention / Issues | MVP-3 | **DONE** — Energy Attention only (±15%); Demand/PQ informational only, no threshold rule |
| Data freshness/quality on energy & demand | MVP-4 | Primitive scaffolded; real backing MISSING |
| Metric grammar/definitions/units | MVP-5 | Content only, no platform dependency |
| Export | MVP-6 | MISSING (code); **decision DECIDED 2026-09-14, see ADR-014**; depends on MVP-2/3 |
| Basic reporting | MVP-6 | Site Performance Report **implemented 2026-09-14, not yet deployed**, see ADR-015; broader Reporting scope still MISSING; depends on MVP-3 |
| Basic alerts | MVP-7 | MISSING; depends on MVP-3's Attention logic |
| Portfolio | MVP-8 | MISSING; lowest MVP priority by decision |
| Financial visibility | Cross-cutting | No tariff/cost data exists anywhere |

## Old DDS phase number → current stage mapping

| DDS phase | Status | Where it lives now |
|---|---|---|
| Phase 7 — Analytics API | **DONE** | Completed foundation |
| Phase 8 — Frontend Foundation | **DONE** | Completed foundation |
| Phase 9 — Core Site/Asset/Space UX | Split | Hierarchy → MVP-1; Site Overview → MVP-3 |
| Phase 10 — Energy Analytics | Split | Consumption/Demand/PQ → MVP-2; Attention-adjacent Alerts → MVP-7 |
| Phase 11 — Asset Performance | Deferred | Post-MVP — not required by Q49–Q101 |
| Phase 12 — Real-Time and Data Quality | Narrowed | Freshness → MVP-4; full connectivity screen → Post-MVP |
| Phase 13 — Advanced Efficiency Analytics | Deferred | Post-MVP — Q56 excludes normalised/adaptive baselines from MVP |
| Phase 14 — Cost/Benchmarking/Intelligence | Split | Cost data dependency → Financial track; benchmarking/insights → Post-MVP |
| Phase 15 — Reporting | Narrowed | Simple export/report → MVP-6; scheduling/builder → Post-MVP |
| Phase 16 — Hardening and Scale | Unchanged | Post-MVP, ongoing technical-quality track |
| Phase 17 — Grafana Migration | Unchanged | Post-MVP, ongoing parity-gated migration |
