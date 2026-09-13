# Requirements Traceability

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering
Source of truth: `ems-requirements-traceability.md` v0.2 (archived), consolidated here.

> **Status update (2026-09-13):** the tables below were built from a
> verification session dated 2026-09-11. `origin/staging` has since moved
> (commit `ddbe5a4`, PRs #46/#48/#49/#50) and MVP-1/MVP-2/MVP-3 are now
> **DONE** — see [../01-product/roadmap.md](../01-product/roadmap.md) and
> §5 below for the consolidated update. The per-Q classifications in §2 are
> preserved as the historical record of what was true on 2026-09-11 (do not
> silently rewrite history — see
> [../00-governance/source-of-truth.md](../00-governance/source-of-truth.md)),
> with §5 stating current status for every row that has since changed.

**Purpose:** this is the working control document. It exists to stop the
team building attractive UI without the underlying semantic/API support. A
requirement is not "buildable" until its whole chain — screen ⟶ API
capability ⟶ semantic/data capability ⟶ roadmap stage — is green.

This document's §2 (Q49–Q101 classification) is the **MVP-readiness-
authoritative** view. §3's `EMS-REQ` matrix (in
[functional-requirements.md](functional-requirements.md)) is kept for
continuity.

## 1. The traceability chain

```text
Product requirement (EMS-REQ-nnn) / Workshop decision (Qn)
        ↓
Customer screen / capability (../03-ux-and-design/information-architecture.md)
        ↓
API capability (Phase 7 Analytics API — GET /api/v1/…)
        ↓
Semantic / data capability (DDS mechanism: view/function, table, calculation)
        ↓
Roadmap stage (../01-product/roadmap.md, MVP-1..MVP-8)
        ↓
Implementation status
```

### Status legend (API-capability granularity)

| Status | Meaning |
|---|---|
| `LIVE` | The API/semantic capability exists on `origin/staging` today — verified, not inferred. |
| `PLANNED (MVP-n)` | The roadmap will deliver it in stage *n*; shape is additive and understood. |
| `MISSING` | No API/semantic capability exists and none is scheduled with a defined shape. |
| `BLOCKED (PA-n)` | Blocked on a named product-architecture gap (see [../04-architecture/application-architecture.md](../04-architecture/application-architecture.md) §gaps). |
| `SCAFFOLD` | Frontend primitive exists (Phase 8) but is not backed by real data yet. |

### Q-classification legend (workshop-decision granularity — used in §2)

| Code | Meaning |
|---|---|
| `A — LANDED` | The required capability exists sufficiently on `origin/staging` to satisfy the decision. |
| `B — PARTIAL` | Some implementation exists but does not yet satisfy the decision. |
| `C — NOT LANDED` | No meaningful implementation exists. |
| `D — DEPENDENCY` | Requires another platform/configuration/API dependency before it can be built. |
| `E — OPEN PRODUCT DECISION` | Cannot responsibly proceed until a genuine, unresolved product decision is made. |
| `F — DOCUMENTATION/CONTENT` | The underlying capability exists; what remains is definitions/labels/copy, not code. |

### API-capability shorthand (verified against `origin/staging`, 2026-09-11)

| Code | API capability | State |
|---|---|---|
| `API.me` | `GET /api/v1/me` — session identity + permission codes | `LIVE` |
| `API.sites` | `GET /api/v1/sites` — scope-filtered site list | `LIVE` |
| `API.energy.consumption` | `GET /api/v1/sites/{id}/energy/consumption` (`1h`/`1d`) | `LIVE` |
| `API.space.measurements` | `GET /api/v1/spaces/{id}/measurements` (TEMPERATURE/HUMIDITY/DEW_POINT; `raw`/`1h`) | `LIVE` |
| `API.spaces.list` | "spaces for a site" list | `PLANNED (MVP-1)` |
| `API.assets.list` | "assets for a site" list | `PLANNED (MVP-1)` |
| `API.asset.rel` | asset-relationship + asset↔space read objects | `PLANNED (MVP-1)` |
| `API.asset.measurements` | asset-scoped measurement series | `PLANNED (MVP-1/Post-MVP)` |
| `API.energy.demand` | demand series / peak / load-duration | `PLANNED (MVP-2)` — underlying analytics **verified LIVE** (`analytics.demand_intervals`, `demand_state`, `v_energy_demand_15min`/daily/monthly); only the API+UI layer is missing |
| `API.energy.pq` | power factor / THD series | `PLANNED (MVP-2)` — underlying telemetry **verified LIVE** (`telemetry.energy_measurements.power_factor_*`, `*_thd_*_percent`) |
| `API.energy.compare` | period/baseline comparison surface | `PLANNED (MVP-2)` — reads existing historians only |
| `API.env.rollup` | site-wide environmental roll-up | `PLANNED (MVP-1/3)` |
| `API.comfort.targets` | per-parameter target/tolerance metadata | `PLANNED (MVP-3)` |
| `API.quality.state` | device/point telemetry state, freshness, connectivity | `PLANNED (MVP-4)` |
| `API.asset.condition` | `asset_health`-backed condition parameters | `PLANNED (Post-MVP)` |
| `API.derived` | persisted derived parameters (COP, baselines) | Phase 6 `LIVE` for SPACE_DEW_POINT; others `PLANNED (Post-MVP)` |
| `API.attention` | predefined-condition Attention/Issues surface | `MISSING`; `PLANNED (MVP-3)` |
| `API.alerts` | alert model + list/history | `MISSING`; `PLANNED (MVP-7)` |
| `API.export` | export of series + context | `MISSING`; `PLANNED (MVP-6)` |
| `API.reports` | simple report generation | `MISSING`; `PLANNED (MVP-6)` |
| `API.portfolio` | cross-site aggregation | `MISSING`; `PLANNED (MVP-8, lowest priority)` |
| `API.cost` | tariff-aware cost values | `MISSING` — **verified: no `config.tariffs`/`analytics.cost_values`-equivalent table exists anywhere in the schema.** |
| `API.categories` | functional-category model | `MISSING` + `BLOCKED (PA-2)` — not addressed by Q49–Q101 |
| `API.writes` | any customer-initiated write (saved views, alert rules) | `MISSING` + `BLOCKED (PA-4)`; not required for MVP (Q67) |

## 2. Q49–Q101 MVP classification (verified 2026-09-11)

| Q# | Decision | Class | Verified basis |
|---|---|---|---|
| Q49 | MVP Boundary | — | Process decision, not an implementation item. |
| Q50 | 4 core analytical questions | **B** | Only "how much energy" is live; comparison, issues, investigation depth are not. |
| Q51 | Site→Space→Asset drill-down | **B** | Site: `A`. Space: `B` (measurements only, no list/detail). Asset: `C` (no API surface at all). |
| Q52 | MVP analytical scope | **B** | Consumption `A` (site-level); Demand/PQ `D`; Energy Performance `C`; Attention `C`; Space/Asset `B`/`C`. |
| Q53 | Shared time context | **A** | `TimeRangePicker`/`ranges.ts` landed, Phase 8. |
| Q54 | Comparison baseline | **D** | Definition fully resolved; comparison API is unbuilt. |
| Q55 | Expected performance = comparison, not prediction | **A** (decision) / **C** (capability) | Decision settled; nothing implements it yet. |
| Q56 | Historical comparison types | **D** | Decided, unbuilt. |
| Q57 | Issues/Attention — analytical not intelligent | **C** | No Attention surface exists. |
| Q58 | MVP investigation | **B** | Depends on Q51, itself `B`/`C`. |
| Q59 | Evidence and trust | **B** | `QualityIndicator` exists; only backs space measurements today. |
| Q60 | Data quality and analytical trust | **B** | Same as Q59. |
| Q61 | MVP landing experience | **B** | Login→site-select shell landed; Site Overview content is `PlaceholderArea`. |
| Q62 | MVP site scope | **A** | Site selection + tenant/site context landed (Phase 8). |
| Q63 | Portfolio experience (included, lower priority) | **C** | No portfolio aggregation API exists; consistent with its decided low priority. |
| Q64 | Portfolio MVP depth | **C** | Same as Q63. |
| Q65 | MVP customer roles | **B** | `ADMIN`/`OPERATOR`/`VIEWER` model exists and is enforced server-side; no explicit mapping to "Facility Manager" persona yet. |
| Q66 | MVP customer actions | **A** | Time-range change is the only action needed today and is live. |
| Q67 | MVP configuration boundary | **A** | Already true architecturally; no change required. |
| Q68 | MVP customer administration | **C** | User/role management exists in the Administration App, not the EMS Web Application surface the decision refers to. |
| Q69 | MVP information architecture | **B** | Routing/shell landed; full IA content not built. |
| Q70 | Site Overview information hierarchy | **C** | No composite Site Overview screen/endpoint exists. |
| Q71 | Overall Site Health | **C** | Not built. |
| Q72 | Significant Issues/Attention | **C** | Not built. |
| Q73 | MVP financial visibility | **D** | Governing principle decided; **verified: zero tariff/cost schema exists.** |
| Q74 | MVP financial language | **D** | Same dependency as Q73. |
| Q75 | MVP export | **C** | No export capability exists. |
| Q76 | MVP reporting | **C** | No reporting capability exists. |
| Q77 | MVP alerts | **C** | No alert model/endpoint exists. |
| Q78 | MVP alert delivery (in-product + email) | **C** | Same as Q77. |
| Q79 | Healthy-state experience | **C** | Not built; depends on Q70/Q72. |
| Q80 | Empty/insufficient data experience | **B** | `EmptyState`/`ErrorState`/`NoDataYet` exist (Phase 8); not exercised against real feature content. |
| Q81 | MVP data freshness | **B** | `quality_code` exists for space measurements only. |
| Q82 | MVP data granularity | **B** | `raw`/`1h` (space), `1h`/`1d` (energy) exist; no `5m`/`15m` tier exposed via the API yet. |
| Q83 | MVP metric consistency | **F** | Content/design-system work; no platform dependency. |
| Q84 | MVP comparison periods | **D** | Decided, unbuilt. |
| Q85 | MVP metric definitions | **F** | Content work. |
| Q86 | MVP units and terminology | **F** | Content work; API already returns semantic fields. |
| Q87 | MVP metric context | **F** | Content work. |
| Q88 | MVP first-time experience | **B** | Login→Select landed; Site Overview→Analyse content not built. |
| Q89 | MVP returning-user experience | **C** | No persisted "last portfolio/site" context found in frontend state. |
| Q90 | MVP search/quick navigation | **C** | Not built. |
| Q91 | MVP responsive experience | **B** | Shell scaffolded responsively; not verified against real feature content. |
| Q92 | MVP performance expectations | **C** | No performance budget or measurement evidence found. |
| Q93 | MVP error handling | **B** | Flat error envelope + `EmptyState`/`ErrorState` landed; full coverage depends on feature screens existing. |
| Q94 | Energy Consumption experience | **B** | API live; screen is a placeholder. |
| Q95 | Maximum Demand experience | **D** | Analytics layer verified live; API+UI missing — a build dependency, not a data one. |
| Q96 | Power Quality experience | **D** | Telemetry verified live; API+UI missing — a build dependency, not a data one. |
| Q97 | Energy Performance experience | **D** | Fully specified by Q54–Q56; comparison API unbuilt. |
| Q98 | MVP Attention experience | **C** | Not built. |
| Q99 | MVP Space experience | **B** | Measurements API live; no space list/detail screen. |
| Q100 | MVP Asset experience | **C** | No API surface at all — the largest single MVP gap. |
| Q101 | MVP navigation context | **B** | Shell nav/tenant-site context landed; real breadcrumb content depends on MVP-1/3. |

**Headline finding (2026-09-11):** Asset (Q51/Q52/Q100) has zero platform
surface. Attention (Q57/Q72/Q98), Site Overview (Q70/Q71), Portfolio
(Q63/Q64), Export/Reporting (Q75/Q76), and Alerts (Q77/Q78) are all
`C — NOT LANDED`. Demand and PQ (Q95/Q96) are `D`, not `C` — their data
foundations are already built; this materially changes their position in
the dependency graph (see [../01-product/roadmap.md](../01-product/roadmap.md), MVP-2).

## 3. Blocked-by-decision register (verified 2026-09-11)

| Blocker | Blocks | Status | Owner |
|---|---|---|---|
| `PA-2` functional categories have no home in the frozen model | Category-based nav/breakdown | **Still genuinely open** — not addressed by Q49–Q101. Not required for MVP scope as decided. | Product → Architecture |
| `PA-3` cost/tariffs conditional on a real customer requirement | Financial visibility | **Resolved at the scope level** by Q73/Q74 — the data dependency itself remains real: no tariff schema exists. | Data/config, not product |
| `PA-4` no customer-write mechanism | Self-configurable alerts, saved views | **Resolved** by Q67 — configuration stays in the Administration App; MVP is read-only. | — |
| `PA-5` correlations edge toward a query builder | Curated correlations | Not required by Q49–Q101; **Post-MVP**. | — |
| `PA-6` no cross-site aggregation surface | Portfolio | **Resolved at scope/priority level** by Q63/Q64 (in scope, lowest priority). API shape still `C — NOT LANDED`. | Architecture (when scheduled) |
| Customer roles undefined | Role-specific overviews | **Partially resolved** by Q65 (Facility/Energy Manager is primary) — no explicit mapping to `ADMIN`/`OPERATOR`/`VIEWER` yet. | Product (light) → Engineering |
| Alert model undefined | Alerts | **Resolved at scope level** by Q77/Q78. Shape/schema still `C — NOT LANDED`. | Engineering |
| Shift-context model missing | Shift analysis | Not addressed; **Post-MVP**. | — |
| Production-quantity source missing | Process KPIs | Not addressed; **Post-MVP**. | — |
| Action log missing | "Did the action work" (MEASURE stage) | Explicitly Post-MVP. | — |

## 4. Status update (2026-09-13) — MVP-1/2/3 landed

Verified against `origin/staging` commit `ddbe5a4` (PRs #46, #48, #49, #50).
Every Q-row below moves from its 2026-09-11 classification in §2 to `A —
LANDED` unless otherwise noted:

| Q# | 2026-09-11 class (§2) | 2026-09-13 status |
|---|---|---|
| Q51, Q99, Q100 | B / B / C | **A** — `API.spaces.list`/`API.assets.list` live; `SpacesList`/`SpaceDetail`/`AssetsList`/`AssetDetail` built. Component-tree navigation itself remains deferred ([ADR-013](../00-governance/decisions/ADR-013-deferred-asset-component-tree.md)). |
| Q61, Q69, Q88, Q101 | B | **A** — `SiteOverview.tsx` replaces `ShellHome`; two-section nav; `HierarchyCrumb` `multiSite` segment. |
| Q70, Q71, Q72, Q98 | C | **A** — Site Health (3-state) and Attention (Energy-only, ±15%) both built. |
| Q79, Q80 | C / B | **A** — `siteHealth.ts` checks assessability first; Insufficient Data never reads as Healthy. |
| Q54, Q55, Q56, Q84, Q97 | D | **A** — Slice C typical-reference comparison landed ([ADR-009](../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md)). |
| Q94 | B | **A** — `EnergyOverview` real. |
| Q95, Q96 | D | **A** — `DemandOverview`/`PowerQualityOverview` real; `API.energy.demand`/`API.energy.pq` live. |
| Q57 | C | **A** for Energy only — Demand/PQ remain informational, no threshold rule (explicit MVP-3 decision, not a gap). |
| Q65, Q89, Q90, Q92 | B / C / C / C | **Unchanged** — not addressed by PRs #46-#50. |
| Q63, Q64, Q73–Q78, Q82, Q91, Q93 | various | **Unchanged** unless noted above — Portfolio, financial/tariff, alerts, export/reporting, data granularity beyond what's described, and full responsive/performance verification remain as classified in §2. |

`API.spaces.list`, `API.assets.list`, `API.energy.demand`, `API.energy.pq`,
and `API.energy.compare` (the typical-reference form of it) move from
`PLANNED`/`MISSING` in §1's shorthand table to **`LIVE`**.
`API.attention` remains `MISSING` as a backend concept — Attention is
computed entirely client-side from data the Energy endpoints already
return (see [ADR-010](../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md)),
so no `/attention` endpoint exists or is planned to exist for this rule.

## 5. Anti-pattern guardrails

See [scope-and-deferred-functionality.md](scope-and-deferred-functionality.md)
§"Anti-pattern guardrails."
