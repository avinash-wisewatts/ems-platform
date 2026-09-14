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
| Alert model undefined | Alerts | **Product/UX fully decided 2026-09-14** ([ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md)) and **architecture fully decided 2026-09-14** ([ADR-017](../00-governance/decisions/ADR-017-mvp7-alert-architecture.md)) — evaluation mechanism (extended TimescaleDB background job) and domain model (`Alert`, DDS 11th concept) both resolved. Shape/schema still `C — NOT LANDED` — no code/migration exists. Remaining: candidate-tracking design, persistence-retry semantics, and the MVP-3 client-migration follow-on are implementation-design tasks, not open architecture decisions. | Product (done) → Architecture (done) → Engineering |
| Space/Asset-level Attention not yet built | Alerts (MVP-7) hierarchy scoping | **Reconciled 2026-09-14** ([ADR-017](../00-governance/decisions/ADR-017-mvp7-alert-architecture.md)): a sequencing dependency, not a contradiction. The original workshop (Q99, Q100) specifies Attention as part of the Space/Asset experience "where supported"; MVP-3's implementation (commit `19c09d7`) explicitly narrowed its own build increment to Site-level Energy only, deferring Space/Asset Attention the same way it deferred Demand/PQ thresholds. MVP-7 alerts can only be generated from the one condition that exists today (Site-level Energy) until a Space/Asset materiality rule is separately built — engineering sequencing, not a new product/architecture decision. | Engineering (MVP-3 scope extension, not yet scheduled) |
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

## 6. Status update (2026-09-14) — Q75 Export decisions resolved

The MVP-6 Product Decision Workshop (2026-09-14) resolved every
previously open Export (Q75) question identified by that day's MVP-6
discovery pass. Full record: [ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md).
New requirements: [functional-requirements.md §Export](functional-requirements.md#export)
(`EMS-REQ-094`–`EMS-REQ-099`).

| Item | 2026-09-11 status (§1/§2) | 2026-09-14 status |
|---|---|---|
| Q75 (MVP export) | `C — NOT LANDED` (§2, "No export capability exists.") | **Decision resolved** — content, context fields, format, delivery model, availability, comparison/baseline behavior, time-range bounds, gap/no-data handling, and hierarchy scoping are all now decided (ADR-014). **Implementation status is unchanged: still no export capability exists anywhere in the codebase.** The `C` capability classification is accurate for "landed"; what changed is that the decision blocker referenced by the discovery pass's Decision Status Table is now closed for every Export question raised there. |
| `API.export` (§1 shorthand) | `MISSING`; `PLANNED (MVP-6)` | **Unchanged as a code fact** — still `MISSING`, still `PLANNED (MVP-6)`. The *shape* is now fully specified (ADR-014) rather than merely "additive and understood in outline," per the `PLANNED (MVP-n)` legend definition. No endpoint, view, or function exists. |

**Q76 (Reporting) is explicitly unaffected by this update** — its format,
catalogue-contents, and report-definition-storage questions remain exactly
as classified in §2 (`C`) and in `functional-requirements.md`
(`EMS-REQ-090`–`EMS-REQ-093`, `DRAFT`/`BLOCKED`). Do not read this section
as resolving Reporting; only Export (Q75) was decided in this workshop.

This does not alter §2's 2026-09-11 classification row for Q75, which
remains the preserved historical record of that date per
[source-of-truth.md](../00-governance/source-of-truth.md)'s no-silent-
rewrite rule. §4 line 189's "Q73–Q78... remain as classified in §2" is
superseded for Q75 specifically by this section — Q75's *decision* status
has changed; its *implementation* status has not, and §4's statement
remains accurate for Q76-Q78, Q73, Q74.

## 7. Status update (2026-09-14) — Q76 Site Performance Report decided and implemented, not yet deployed

The Q76 Reporting Product Decision Workshop (2026-09-14) resolved a
narrow subset of Q76's open questions — enough to define and implement
one report type, the Site Performance Report. Full record:
[ADR-015](../00-governance/decisions/ADR-015-q76-site-performance-report.md).
New requirements: [functional-requirements.md §Site Performance Report](functional-requirements.md#site-performance-report)
(`EMS-REQ-110`–`EMS-REQ-116`).

| Item | 2026-09-11 status (§2) | 2026-09-14 status |
|---|---|---|
| Q76 (MVP reporting) | `C — NOT LANDED` ("No reporting capability exists.") | **Partially decided and implemented, not yet deployed** — catalogue (one type), configuration, generation, structure, PDF, and error handling are decided AND built for the Site Performance Report specifically (ADR-015; `web/src/routes/reports/`). Verified this session: full frontend suite (209 tests), `tsc --noEmit`, `eslint --max-warnings 0`, `vite build` all pass. No staging/production deployment has occurred. **Report catalogue breadth, non-PDF format questions (e.g. Excel), scheduled/automated variants, and any report type beyond Site Performance remain exactly as open as the 2026-09-14 Q76 workshop brief left them.** This is not a full resolution of Q76. |

**This section does not resolve Q75/Export** (already recorded in §6) **or
the general Q76 questions this workshop did not touch** (report-definition
storage as a general mechanism, Excel format, multi-report catalogues,
Space/Asset-scoped analytical content, a real data-availability API). Two
genuine architecture/data gaps were identified during this work, not
silently resolved — recorded in full in ADR-015's "Decision — gap
resolutions" section:

1. **No Space/Asset-scoped Energy/Demand/Power-Quality/Attention/Health
   capability exists anywhere in the platform.** The Site Performance
   Report's hierarchy-context selector (Site/Space/Asset) therefore
   changes only the report's title and Investigation-section target — its
   analytical content is always the selected Site's own data. This is a
   genuine capability gap, not a design choice; closing it requires new
   API surface.
2. **No endpoint or mechanism exposes a site's actual data-available date
   range.** The same gap already recorded against Export (§6, ADR-014
   decision 9). The Site Performance Report's Custom period picker does
   not enforce a fabricated bound as a result.

Both gaps apply equally to Export (§6) and to any future Q76 report type
— they are platform-level gaps, not specific to this one report.

## 8. Status update (2026-09-14) — Q77/MVP-7 Basic Alerts fully scoped, not implemented; 2 architecture questions open

A Q77/MVP-7 discovery conversation, conducted in ChatGPT and transferred
into this session as a structured handoff, resolved Q77/MVP-7 Basic Alerts
to full product/UX detail — trigger/qualification, Active/Resolved/Ended
lifecycle, configuration-change transitions, persistence-failure handling,
retention, recurrence, content/detail structure, navigation, filtering/
ordering, and authorization. Full record:
[ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md).
New requirements: [functional-requirements.md §Alerts](functional-requirements.md#alerts)
(`EMS-REQ-117`–`EMS-REQ-127`); `EMS-REQ-080`/`081`/`084` corrected.

| Item | 2026-09-11 status (§2) | 2026-09-14 status |
|---|---|---|
| Q77 (MVP alerts) | `C — NOT LANDED` ("No alert model/endpoint exists.") | **Fully decided at product/UX level, not implemented.** Every behavioral question the archived baseline left open (lifecycle, states, retention, recurrence, content, filtering, authorization) is now specified (ADR-016). **Implementation status is unchanged: no alert model, endpoint, evaluation mechanism, or UI exists anywhere in the codebase.** The `C` capability classification remains accurate for "landed"; what changed is that the decision blocker is now closed, and two specific architecture blockers are now named instead of a generic "no alert model" gap. |
| Q78 (MVP alert delivery) | `C — NOT LANDED` ("Same as Q77.") | **Decision superseded, not merely resolved**: the archived baseline's "in-product + email" is corrected to **in-product only** — email is fully removed from MVP-7 scope, not deferred alongside a landed email channel. Implementation status unchanged (`C`). |
| `API.alerts` (§1 shorthand) | `MISSING`; `PLANNED (MVP-7)` | **Unchanged as a code fact** — still `MISSING`, still `PLANNED (MVP-7)`. The *shape* is now fully specified at the product level (ADR-016), but two architecture questions (no evaluation mechanism, no Alert entity in the frozen DDS model) must be resolved before an endpoint can be designed, let alone built. |

**Two genuine architecture questions were identified during this
documentation pass, not silently resolved** — recorded in full in
ADR-016's "Architecture questions identified" section:

1. **No server-side Attention/alert evaluation mechanism exists in any
   form.** Attention today (`web/src/attention/energyAttention.ts`) is a
   stateless client-side computation re-run at render time — there is no
   scheduler, job, or persisted evaluation state anywhere in `app/src`
   (verified by `grep`). The handoff's qualification/resolution-timer
   model (gap-resetting 5-minute/1-minute windows, restart-survival,
   30-minute persistence retry) presupposes a continuous, stateful,
   server-side evaluation process that does not exist today in any form,
   not even a stub to extend.
2. **No `Alert` entity exists in the frozen DDS ten-concept model**
   ([system-architecture.md](../04-architecture/system-architecture.md))
   and none exists in `postgres/` (verified by `grep`). A persisted,
   immutable, stateful Alert record is a new core entity requiring the
   DDS's five-criteria change-control test — not yet run.

This does not alter §2's 2026-09-11 classification rows for Q77/Q78, which
remain the preserved historical record per
[source-of-truth.md](../00-governance/source-of-truth.md)'s no-silent-
rewrite rule. §4 line 189's "Q63, Q64, Q73–Q78... remain as classified in
§2" is superseded for Q77/Q78 specifically by this section — their
*decision* status has changed (fully, for Q77; by correction, for Q78);
their *implementation* status has not, and §4's statement remains accurate
for Q63, Q64, Q73–Q76, Q82, Q91, Q93.

## 9. Status update (2026-09-14) — Q77/MVP-7 alert architecture decided (A1+B1); not implemented

Following §8's product/UX capture, an architecture investigation brief
identified two open questions (server-side evaluation mechanism; Alert
domain concept), and Product/Architecture ratified both — **A1** (extend
the existing TimescaleDB-native background-job mechanism) and **B1**
(introduce a minimal `Alert` domain concept, formally amending the frozen
DDS from 10 to 11 core concepts). Full record:
[ADR-017](../00-governance/decisions/ADR-017-mvp7-alert-architecture.md).

| Item | 2026-09-14 §8 status | 2026-09-14 (this section) status |
|---|---|---|
| Q77 architecture (evaluation mechanism) | Open — "no server-side Attention/alert evaluation mechanism exists in any form." | **Decided**: extends `postgres/jobs/`'s existing TimescaleDB `add_job` pattern (1-minute interval, matching `69_environment_routing_job.sql`'s cadence). A new canonical SQL function becomes the single source of truth for the ±15% materiality rule; the existing client-side implementation (ADR-010) is tracked for future migration, gated by a mandatory parity test — not silently duplicated. **Still `MISSING` in code.** |
| Q77 architecture (Alert domain concept) | Open — "no `Alert` entity exists in the frozen DDS model." | **Decided**: `Alert` added as the DDS's 11th core concept (five-criteria test applied and passed — see ADR-017). `analytics.insights` explicitly not reused; no generic event framework, generalized Subject, or severity taxonomy introduced. **Still `MISSING` in code/schema** — no migration exists. |
| `API.alerts` (§1 shorthand) | `MISSING`; `PLANNED (MVP-7)` | **Unchanged as a code fact** — still `MISSING`, still `PLANNED (MVP-7)`. Verified compliant with the Analytics API boundary (ADR-007) and the existing tenant-authorization pattern (`_require_portal_user`, three-role scope model) at the design level; no endpoint exists. |

**Reconciled, not silently resolved**: Space/Asset-level Attention is
product-specified (Q99, Q100 — "where supported") but not yet built,
deferred by MVP-3's own implementation-scoping decision the same way
Demand/PQ thresholds were — a sequencing dependency, not a contradiction
between ADR-016 and ADR-010. MVP-7 alerts are Site-level-Energy-only in
practice until that extension is built — recorded in §3's blocker register
above. Candidate/pending-qualification tracking and the 30-minute
persistence-retry mechanism's relationship to TimescaleDB's own job-level
retry are confirmed **implementation design details, resolvable under
ADR-017's existing architecture** — no new architecture decision is
required, provided candidate-tracking state is durable/idempotent across
job runs and the discard-with-operational-record outcome reuses the
platform's existing failure/quarantine-logging convention (e.g.
`postgres/migrations/003_telemetry_pipeline_performance_state.sql`) rather
than introducing a new customer-facing entity.

## 10. Status update (2026-09-14) — Q77/MVP-7 Basic Alerts implemented, staging validation pending

Following §8 (product capture) and §9 (architecture decided), MVP-7 was
implemented in the same workstream. Full record: ADR-016, ADR-017, and
[docs/07-features/alerts/README.md](../07-features/alerts/README.md).

| Item | §9 status | 2026-09-14 (this section) status |
|---|---|---|
| Q77 (MVP alerts) | Architecture decided, `C — NOT LANDED` in code | **Implemented**: `postgres/migrations/238`/`239` (schema, evaluator, lifecycle procedure, job), `postgres/jobs/238_alert_evaluation_job.sql`, `GET /api/v1/sites/{id}/alerts` + `.../alerts/{id}` (Analytics API), `web/src/routes/alerts/AlertsArea.tsx` (list/detail/filter/tabs) + header indicator. Backend: 9 route-contract tests + 16 static SQL-contract tests, all passing. Frontend: 6 new component tests + navigation regression fixes; full suite (216 tests), `tsc --noEmit`, `eslint --max-warnings 0`, `vite build` all pass. |
| `API.alerts` (§1 shorthand) | `MISSING`; `PLANNED (MVP-7)` | **`LIVE`** — `GET /api/v1/sites/{site_id}/alerts`, `GET /api/v1/alerts/{alert_id}`. |

**Known limitations, flagged not silently absorbed** (full list:
`docs/07-features/alerts/README.md` "Known limitations / deviations"):
evaluation period is the most recent completed site-local day (a
consequence of the existing whole-day constraint, not a new product
decision); no executable cross-language parity harness between the SQL and
TypeScript materiality implementations (ADR-017's named precondition —
only static checks exist); no live "latest value" re-fetch in the detail
view; Space/Asset cascading filters not implemented (no such condition
exists); "Load more" is button- not scroll-triggered; header indicator
count capped at 200; **no live TimescaleDB instance was available in this
environment to execute the migrations themselves** — the SQL was validated
by careful manual review (which did catch and fix one real bug: a `FOUND`-
variable scoping error across multiple statements in the lifecycle
procedure) and static contract tests, not live execution; this relies on
the CI database/migration integration job as the first live-execution
gate.

This does not alter §8/§9's own historical snapshots, preserved per
[source-of-truth.md](../00-governance/source-of-truth.md)'s no-silent-
rewrite rule.
