# WiseWatts EMS — Requirements Traceability

> **Status:** WORKING DRAFT  ·  **Version:** 0.1  ·  **Owner:** Product  ·  **Last updated:** 2026-09-10
>
> **Source basis:** `ems-customer-requirements.md`, `ems-information-architecture.md`, `ems-product-roadmap.md`, `ems-product-architecture.md`, DDS + roadmap (Phases 7–17).
>
> **Purpose:** this is the **working control document**. It exists to stop us building attractive UI without the underlying semantic/API support. A requirement is not "buildable" until its whole chain — screen ⟶ API capability ⟶ semantic/data capability ⟶ roadmap phase — is green.

---

## 1. The traceability chain

```text
Product requirement (EMS-REQ-nnn)
        ↓
Customer screen / capability (ems-information-architecture.md §4.x)
        ↓
API capability (Phase 7 Analytics API — GET /api/v1/…)
        ↓
Semantic / data capability (DDS mechanism: view/function, table, calculation)
        ↓
Roadmap phase (technical roadmap Phase N)
        ↓
Implementation status
```

### Status legend

| Status | Meaning |
|---|---|
| `LIVE` | The API/semantic capability exists on staging today (Phase 7 first slice / Phase 6). |
| `PLANNED (Pn)` | The roadmap will deliver it in phase *n*; shape is additive and understood. |
| `MISSING` | No API/semantic capability exists and none is scheduled with a defined shape — needs a product/architecture decision first. |
| `BLOCKED (PA-n)` | Blocked on a named product-architecture gap (`ems-product-architecture.md` §9). |
| `SCAFFOLD` | Frontend primitive exists (Phase 8) but is not backed by real data yet. |

### API-capability shorthand

| Code | API capability | State |
|---|---|---|
| `API.me` | `GET /api/v1/me` — session identity + permission codes | `LIVE` |
| `API.sites` | `GET /api/v1/sites` — scope-filtered site list | `LIVE` |
| `API.energy.consumption` | `GET /api/v1/sites/{id}/energy/consumption` | `LIVE` |
| `API.space.measurements` | `GET /api/v1/spaces/{id}/measurements` (TEMPERATURE/HUMIDITY/DEW_POINT; raw,1h) | `LIVE` |
| `API.spaces.list` | "spaces for a site" list | `PLANNED (P9)` |
| `API.assets.list` | "assets for a site" list | `PLANNED (P9)` |
| `API.asset.rel` | asset-relationship + asset↔space read objects (component tree, serves-map) | `PLANNED (P9)` |
| `API.asset.measurements` | asset-scoped measurement series | `PLANNED (P9/P11)` |
| `API.energy.demand` | demand series / peak / load-duration | `PLANNED (P10)` |
| `API.energy.breakdown` | consumption split by meter-role / category / system | `PLANNED (P10)` + `BLOCKED (PA-2)` |
| `API.energy.compare` | period/site comparison surface | `PLANNED (P10)` |
| `API.env.rollup` | site-wide environmental roll-up ("spaces out of band") | `PLANNED (P9)` |
| `API.comfort.targets` | per-parameter target/tolerance metadata | `PLANNED (P9)` |
| `API.quality.state` | device/point telemetry state, freshness, connectivity | `PLANNED (P12)` |
| `API.asset.condition` | `asset_health`-backed condition parameters | `PLANNED (P11)` |
| `API.derived` | persisted derived parameters (COP, baselines) | Phase 6 `LIVE` for SPACE_DEW_POINT; others `PLANNED (P11/P13)` |
| `API.baseline` | baseline / expected-performance series | `PLANNED (P13)` |
| `API.compare.assets` | cross-asset comparison (same `asset_type_id`) | `PLANNED (P13)` |
| `API.correlations` | curated correlation pairs | `MISSING` + `BLOCKED (PA-5)` |
| `API.trends` | curated multi-series trend catalogue | `PLANNED (P9/P10)` |
| `API.portfolio` | cross-site aggregation | `MISSING` + `BLOCKED (PA-6)` |
| `API.cost` | tariff-aware cost values | `MISSING` + `BLOCKED (PA-3)` |
| `API.alerts` | alert model + list/history | `MISSING` (`OPEN #6`) |
| `API.insights` | `analytics.insights` event log | `PLANNED (P14)` |
| `API.reports` | report definitions + generation | `PLANNED (P15)` |
| `API.categories` | functional-category model | `MISSING` + `BLOCKED (PA-2)` |
| `API.writes` | any customer-initiated write (saved views, alert rules, logbook) | `MISSING` + `BLOCKED (PA-4)` |

---

## 2. Traceability matrix

`Req → Screen(s) → API capability → Semantic/data capability → Phase → Status`

| Req | Screen(s) (IA §) | API capability | Semantic / data capability | Phase | Status |
|---|---|---|---|---|---|
| 001 separate app | all | — | app boundary (DDS §F.0) | 8 | `LIVE` |
| 002 API-only | all | (the boundary itself) | Phase 7 query boundary | 7–8 | `LIVE` |
| 003 no impl IDs | all | all `/api/v1/*` return semantic fields only | `v_grafana_*` naming/tenant conventions | 8+ | `LIVE` (must be upheld per new endpoint) |
| 004 shared auth | all | session cookie on `/api/v1` | `SessionMiddleware`, `portal_identity` | 8 | `LIVE` |
| 005 server-side authz | all | 401/403/404-no-leak | SECURITY DEFINER (`portal_user_can_access_space`, tenant filters) | 7–8 | `LIVE` |
| 006 independent deploy | — | — | `-web` artifact, bind-mount, CI/CD | 8 | `LIVE` |
| 007 Grafana OPS-only | — | — | Phase 17 parity process | 10–17 | `PLANNED (P17)` |
| 008 no contract change | — | additive-only rule | roadmap Phase 7 extension model | 7+ | `LIVE` (policy) |
| 010 org/portfolio context | Portfolio Overview, Sites (§4.1–4.2) | `API.sites` (+ `API.portfolio` for roll-ups) | `metadata.organizations`/`sites`, tenant scope | 8–9 | `API.sites` `LIVE`; roll-ups `MISSING (PA-6)` |
| 011 site selection | Sites, Site Overview (§4.2–4.3) | `API.sites` | site scope | 8–9 | `LIVE` (pattern `OPEN #4`) |
| 012 landing / portfolio-vs-site | Portfolio Overview, Site Overview | `API.sites` | — | 9 | `PO-REVIEW` (`OPEN #1/#2`) |
| 013 semantic breadcrumb | all | fields on every response | semantic model | 8–9 | `LIVE` (upheld per endpoint) |
| 014 spaces navigation | Spaces list + detail (§4.4–4.5) | `API.spaces.list`, `API.space.measurements` | `metadata.spaces`, `space_points`, `environment_measurements` | 9 | list `PLANNED (P9)`; series `LIVE` |
| 015 assets navigation | Assets list + Asset Overview (§4.6–4.7) | `API.assets.list` | `metadata.assets` | 9 | `PLANNED (P9)` |
| 016 component tree | Asset Overview (§4.7) | `API.asset.rel` | `asset_relationships` (typed, effective-dated) | 9 | `PLANNED (P9)` |
| 017 serves-map | Space detail, Asset Overview | `API.asset.rel` | `asset_space_relationships` | 9 | `PLANNED (P9)` |
| 018 functional categories (nav) | Assets list, Breakdown (§4.6, 4.13) | `API.categories` | **no model today** | 10 | `BLOCKED (PA-2)` / `OPEN #12` |
| 019 deep links | all | opaque semantic IDs in responses | — | 9+ | `DRAFT` |
| 020 Site Overview | Site Overview (§4.3) | composite of 021–024 | composite | 9–10 | `PO-REVIEW` (`OPEN #3`) |
| 021 energy vs expected | Site Overview, Energy Consumption | `API.energy.consumption` + `API.energy.compare` (+ `API.baseline`) | `analytics.energy_consumption_*`; baseline calc (P13) | 10 (13) | consumption `LIVE`; comparison `PLANNED (P10)`; baseline `PLANNED (P13)` |
| 022 demand vs contracted | Site Overview, Demand (§4.11) | `API.energy.demand` | `demand_intervals`/`demand_state`; contracted-demand config | 10 | `BLOCKED` — `API.energy.demand` `PLANNED (P10)`; contracted value source `[OPEN]` |
| 023 environmental roll-up | Site Overview, Environment (§4.14) | `API.env.rollup`, `API.comfort.targets` | `environment_measurements`+`space_id`; target metadata | 9 | series `LIVE`; roll-up + targets `PLANNED (P9)` |
| 024 data-quality health | Site/Portfolio Overview, Data Quality (§4) | `API.quality.state` | `device_telemetry_state`/`device_status` | 12 | `PLANNED (P12)`; indicators `SCAFFOLD` |
| 025 cost-to-date | Site Overview, Energy Cost (§4.12) | `API.cost` | `config.tariffs`/`analytics.cost_values` | 14 | `BLOCKED (PA-3)` / `OPEN #7` |
| 026 Portfolio Overview | Portfolio Overview (§4.1) | `API.portfolio` | cross-site aggregation | 9–13 | `MISSING (PA-6)` / `OPEN #2` |
| 027 period comparison | many | `API.energy.compare` / `API.trends` | period-over-period on existing tiers | 10 | `PLANNED (P10)` |
| 028 notable-events strip | Site Overview | derived from `API.energy.demand` + `API.env.rollup` | deterministic period facts | 10–12 | `DRAFT` (depends on 022/023) |
| 030 progressive drill-down | all detail screens | 016/017 + time-window params on series | asset/space relationships; resolution ladder | 9–11 | `PLANNED` (depth `OPEN #4`) |
| 031 consumption trend/spike | Energy Consumption (§4.10) | `API.energy.consumption` | `analytics.energy_consumption_*` (5 tiers) | 10 | `LIVE` (tier availability varies by commissioning) |
| 032 demand-peak investigation | Demand (§4.11) | `API.energy.demand` + contributing-asset attribution | demand + asset context | 10–11 | `BLOCKED` (attribution `PLANNED (P10/11)`) |
| 033 energy breakdown | Breakdown (§4.13) | `API.energy.breakdown` | meter-role / category / system split | 10 | `BLOCKED (PA-2)` |
| 034 space env trend + band | Space detail (§4.5) | `API.space.measurements` + `API.comfort.targets` | `environment_measurements`; DEW_POINT persisted (P6); target metadata | 9 | series+DEW_POINT `LIVE`; targets `PLANNED (P9)` |
| 035 asset measurements leaf | Asset Measurements (§4.9) | `API.asset.measurements` | domain tables / `generic_point_measurements`; attribution via `asset_points` | 9/11 | `PLANNED` |
| 036 curated correlations | Correlations (§4.18) | `API.correlations` | curated pairs | 10–13 | `MISSING` + `BLOCKED (PA-5)` |
| 037 curated trends | Trends (§4.16) | `API.trends` | curated semantic-series catalogue | 9–10 | `PLANNED (P9/P10)` |
| 038 comparisons | Comparisons (§4.17) | `API.compare.assets` / `API.energy.compare` | cross-asset comparison views (P13) | 13 | `PLANNED (P13)` |
| 040 energy consumption parity | Energy Consumption | `API.energy.consumption` | `analytics.energy_consumption_*` | 10 | `LIVE` (parity gate is the work) |
| 041 demand parity | Demand | `API.energy.demand` | `demand_intervals`/`demand_state` | 10 | `PLANNED (P10)` |
| 042 multi-utility | Trends, Energy | `API.trends` incl. water/fuel/thermal | `water_measurements`, broadened `energy_measurements` | 10–12 | `PLANNED` (loaders per Phase 3+) |
| 043 power quality | Power Quality (§4.15) | high-res electrical params via `API.trends`/dedicated | `energy_measurements` wide columns; `qualifier` L1/L2/L3 | 11/13 | `PLANNED` |
| 044 tariff costing | Energy Cost | `API.cost` | `config.tariffs`/`analytics.cost_values` | 14 | `BLOCKED (PA-3)` |
| 045 process KPIs | Analytics | `API.derived` + production input | `parameter_calculations`; **production quantity source missing** | 13–14 | `MISSING` (no production data) |
| 046 running hours | Asset Performance | `API.derived` | derived calc; not scheduled | — | `MISSING` (unscheduled) |
| 047 start-up detection | Asset Performance / Alerts | `API.insights` or dedicated | detection in analytics code | — | `MISSING` (unscheduled) |
| 048 shift views | (cross-cutting) | needs shift dimension | **no shift-context model** | — | `MISSING` (`[OPEN]`) |
| 049 live SLD | Future area | real-time flow | `site_energy_meter_roles` as basis; real-time infra | — | `MISSING` (LATER) |
| 050 space env measurements | Space detail | `API.space.measurements` | `environment_measurements`+`space_id`; P6 DEW_POINT | 9 | `LIVE` |
| 051 site env grid | Environment (§4.14) | `API.env.rollup` | site roll-up over spaces | 9 | `PLANNED (P9)` |
| 052 comfort band overlay | Space detail, Environment | `API.comfort.targets` | `direction_of_good`/target metadata on `config.parameters` | 9–12 | `PLANNED` |
| 053 extra env params (CO₂…) | Environment | `API.space.measurements` extended | `space_points` for those parameters; loaders | 9–12 | `MISSING` (per parameter) |
| 054 env↔energy correlation | Correlations | `API.correlations` | curated pair | 10–13 | `BLOCKED (PA-5)` |
| 060 Asset Overview | Asset Overview (§4.7) | `API.assets.list` + `API.asset.rel` (+ `API.asset.condition`) | `metadata.assets`, relationships | 9 / 11 | structure `PLANNED (P9)`; condition `PLANNED (P11)` |
| 061 asset performance | Asset Performance (§4.8) | `API.asset.condition` + `API.derived` | `asset_health`, derived params | 11 | `PLANNED (P11)` |
| 062 derived efficiency (COP) | Asset Performance | `API.derived` | `parameter_calculations`/`derived_parameter_values` | 11–13 | `PLANNED` (SPACE_DEW_POINT precedent `LIVE`) |
| 063 baseline overlays | Energy Consumption, Asset Performance | `API.baseline` | baseline as `parameter_calculations` specialization | 13 | `PLANNED (P13)` |
| 064 cross-asset comparison | Comparisons | `API.compare.assets` | comparison views within `asset_type_id` | 13 | `PLANNED (P13)` |
| 065 operating envelope | Asset Performance | `API.baseline` | envelope from baseline | 13 | `PLANNED (P13)` |
| 070 quality indicators | all | `quality_code`/`is_estimated` on series | quality semantics | 8 / 12 | `SCAFFOLD` → `LIVE` real backing (P12) |
| 071 no-data normal | all | `no_data:true` 200 pattern | — | 8 | `LIVE` |
| 072 resolution degradation | Energy, Environment | resolution params + tier availability | 5-tier ladder; commissioning state | 10–12 | `DRAFT` |
| 073 connectivity view | Data Quality (§4) | `API.quality.state` | `device_telemetry_state`/`device_status`/`device_live_point_state` | 12 | `PLANNED (P12)` |
| 074 hi-res + aggregated | all series | resolution params | 5-tier ladder | 9–10 | `LIVE` (subset) |
| 080 view alerts | Alerts (§4.19) | `API.alerts` | **no alert model** | — | `MISSING` (`OPEN #6`) |
| 081 alert→context | Alerts | `API.alerts` + series params | — | — | `DRAFT` |
| 082 self-configurable alerts | Alerts + Administration App | `API.writes` (or admin mechanism) | audited rule store | — | `BLOCKED (PA-4)` |
| 083 demand-approaching alert | Alerts | `API.alerts` + `API.energy.demand` | threshold on demand | — | `DRAFT` |
| 084 multi-channel notify | (infra) | delivery service | — | — | `MISSING` (LATER) |
| 090 report catalogue/viewer | Reports (§4.20) | `API.reports` | report-definition storage; reads via Phase 7 | 15 | `PLANNED (P15)` |
| 091 export formats | Reports | `API.reports` (export) | format templates | 15 | `BLOCKED` — formats `OPEN #10` |
| 092 scheduled reports | Reports | `API.reports` (schedule) | existing job-scheduling conventions | 15 | `PLANNED (P15)` |
| 093 report parity | Reports | `API.reports` | Phase 10 parity discipline | 15 | `PLANNED` (depends P10) |
| 100 time-range control | all | resolution/`from`/`to` params | resolution ladder | 8 | `LIVE` |
| 101 one charting foundation | all | — | — | 8 | `LIVE` |
| 102 role-appropriate views | all | `API.me` permission codes | `ROLE_PERMISSIONS` / server authz | 8–9 | `LIVE` (which roles `OPEN #5`) |
| 103 fast page loads | all | efficient endpoints + caching | Phase 16 hardening | 8, 16 | `DRAFT` (budgets `[OPEN]`) |
| 104 responsive | all | — | — | 8 | `LIVE` |
| 105 empty/error states | all | error envelope + `no_data` | — | 8 | `LIVE` |
| 106 saved views | all | `API.writes` (later); per-browser now | per-viewer storage | 9+ | `DRAFT` / `BLOCKED (PA-4)` for server-side |
| 107 sensor/PLC reuse | (positioning) | — | onboarding in Administration App | — | `LIVE` (fact) |
| 108 modular expansion | all | generic parameter handling | `generic_point_measurements`, `config.parameters` | 9+ | `PLANNED` |
| 109 context-aware system | all | relationship read objects | semantic model | 9+ | `PLANNED (P9)` |
| 120 insights surface | Insights (future) | `API.insights` | `analytics.insights` | 14 | `PLANNED (P14)` |
| 121 anomaly detection | Insights | `API.insights` | detectors (per-approval) | 14 | `PLANNED (P14)` |
| 122 recommendations | Recommendations (future) | `API.insights` extended | detection→action mapping | 14+ | `MISSING` (LATER) |
| 123 best-practice comparison | Comparisons/Insights | `API.compare.assets` + reference set | **best-practice reference set missing** | 13–14 | `MISSING` |
| 124 saving opportunities | Insights/Recommendations | `API.baseline` + `API.insights` | quantified-gap calc | 14+ | `MISSING` (LATER) |
| 125 did-the-action-work | Comparisons/Reports | `API.compare.assets`/`API.energy.compare` + action log | **action log missing** | 13–15 | `MISSING` |
| 126 digital logbook | Future area | `API.writes` | audited manual-reading store | — | `BLOCKED (PA-4)` |
| 127 AI assistant | Future area | — | — | — | `MISSING` (LATER — **no AI now**) |
| 128 GHG accounting | Sustainability (future) | `API.cost`-adjacent + emissions factors | emissions model | 14+ | `MISSING` (conditional) |

---

## 3. Buildable-now set (v0.1 assessment)

`[INFERRED]` Given only what is `LIVE` today (`API.me`, `API.sites`, `API.energy.consumption`, `API.space.measurements` incl. persisted DEW_POINT), the requirements whose **entire chain is green now** are:

- **001–008** (foundation / boundary — already true).
- **010, 011, 013** (org/site context, breadcrumb) — via `API.sites`.
- **050, 034 (series portion), 014 (detail portion)** — space environmental detail via `API.space.measurements`.
- **031, 040 (consumption trend portion), 074 (subset)** — energy consumption trend via `API.energy.consumption`.
- **070 (scaffold), 071, 100, 101, 104, 105** — cross-cutting primitives (Phase 8).
- **102** (role-aware nav) — via `API.me` permission codes (which roles is `OPEN #5`).

Everything else needs `API.spaces.list` / `API.assets.list` / `API.asset.rel` at minimum (Phase 9), or a later phase, or a blocked decision.

**⟶ This is the evidence base for the "Proposed Phase 9 starting point" in `ems-product-roadmap.md` §5** (start with Spaces, the only feature area with a live endpoint).

---

## 4. Blocked-by-decision register

| Blocker | Blocks (Req) | Needs | Owner |
|---|---|---|---|
| `PA-2` functional categories have no home in the frozen model | 018, 033, and category-based nav/breakdown | product decision on what a "functional category" maps to (asset_type? relationship type? VIRTUAL asset? new config?) → then an architecture decision | Product → Architecture |
| `PA-3` cost/tariffs conditional on a real customer requirement | 025, 044, 128 (partly) | product decision: is tariff-aware cost commercially required, and in what form? (`OPEN #7`) | Product |
| `PA-4` no customer-write mechanism | 082, 106 (server-side), 126 | product + architecture decision on an audited customer-write path (vs. Administration-App-owned config) | Product → Architecture |
| `PA-5` correlations edge toward a query builder | 036, 054 | product decision to keep correlations **curated**; define the initial pair list | Product |
| `PA-6` no cross-site aggregation surface | 026, portfolio KPIs on 010/020 | product decision on portfolio depth (`OPEN #2`) → then API shape | Product → Architecture |
| `OPEN #5` customer roles undefined | 102, role-specific overviews | product decision on the customer role set | Product |
| `OPEN #6` alert model undefined | 080, 081, 083 | product decision on what a customer alert is and how it appears; relation to `analytics.insights` | Product → Architecture |
| shift-context model missing | 048 | product decision whether shift analysis is in scope; if so, a shift model | Product |
| production-quantity source missing | 045 | a data source for production units | Product |
| action log missing | 125 | a place to record "the customer did X" | Product → Architecture |

---

## 5. Anti-pattern guardrails (things this document exists to catch)

`[WISEWATTS-DECISION]` A requirement or screen is **rejected in review** if it:

- needs data the Analytics API does not expose **and** proposes to reach past the API to get it;
- needs a new database entity/column to support a UI idea (freeze rules apply);
- becomes a free-form query builder / metric-vs-metric explorer / raw-tag browser;
- introduces dynamic SQL anywhere;
- introduces AI/recommendation/anomaly-scoring ahead of Phase 14;
- requires a change to Phase 6, energy pipelines, Grafana, or the Phase 7 contract without a separate explicit architecture decision;
- makes an energy number that also appears in Grafana without a parity commitment (Phase 10).

---

## 6. Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial traceability matrix for EMS-REQ-001..128; API-capability shorthand + states; buildable-now set; blocked-by-decision register; anti-pattern guardrails. |
