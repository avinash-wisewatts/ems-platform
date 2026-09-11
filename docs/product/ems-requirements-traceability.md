# WiseWatts EMS — Requirements Traceability

> **Status:** WORKING DRAFT · **Version:** 0.2 · **Owner:** Product · **Last updated:** 2026-09-11
>
> **Source basis:** `ems-customer-requirements.md`, `ems-information-architecture.md`, `ems-product-roadmap.md` (v0.2), `ems-product-architecture.md`, DDS + roadmap (Phases 7–17), `ems-product-owner-workshop-baseline.md` §92–134 (Q49–Q101), and direct verification against `origin/staging` (`a5094a1`) on 2026-09-11 (branch comparison, code/schema inspection — not inferred from commit titles).
>
> **Purpose:** this is the **working control document**. It exists to stop us building attractive UI without the underlying semantic/API support. A requirement is not "buildable" until its whole chain — screen ⟶ API capability ⟶ semantic/data capability ⟶ roadmap stage — is green.
>
> **TRACEABILITY UPDATE (v0.2):** v0.1 (2026-09-10) predated the workshop's Q49–Q101 MVP decisions and was written while Phase 7/8 were "in progress" locally. v0.2 verifies every LIVE/PLANNED/MISSING claim against the actual `origin/staging` state and adds §2 (Q49–Q101 classification), which is now the primary MVP-readiness view — the EMS-REQ matrix in §3 is kept for continuity but §2 is authoritative for MVP scope questions.

---

## 1. The traceability chain

```text
Product requirement (EMS-REQ-nnn) / Workshop decision (Qn)
        ↓
Customer screen / capability (ems-information-architecture.md §4.x)
        ↓
API capability (Phase 7 Analytics API — GET /api/v1/…)
        ↓
Semantic / data capability (DDS mechanism: view/function, table, calculation)
        ↓
Roadmap stage (ems-product-roadmap.md v0.2, MVP-1..MVP-8)
        ↓
Implementation status
```

### Status legend (API-capability granularity)

| Status | Meaning |
|---|---|
| `LIVE` | The API/semantic capability exists on `origin/staging` today — verified, not inferred. |
| `PLANNED (MVP-n)` | The re-baselined roadmap will deliver it in stage *n*; shape is additive and understood. |
| `MISSING` | No API/semantic capability exists and none is scheduled with a defined shape — needs a product/architecture decision first. |
| `BLOCKED (PA-n)` | Blocked on a named product-architecture gap (`ems-product-architecture.md` §9). |
| `SCAFFOLD` | Frontend primitive exists (Phase 8) but is not backed by real data yet. |

### Q-classification legend (workshop-decision granularity — used in §2)

| Code | Meaning |
|---|---|
| `A — LANDED` | The required capability exists sufficiently on `origin/staging` to satisfy the decision. |
| `B — PARTIAL` | Some implementation exists but does not yet satisfy the decision (e.g. a primitive with no real content behind it). |
| `C — NOT LANDED` | No meaningful implementation exists. |
| `D — DEPENDENCY` | Requires another platform/configuration/API dependency before it can be built. |
| `E — OPEN PRODUCT DECISION` | Cannot responsibly proceed until a genuine, unresolved product decision is made. |
| `F — DOCUMENTATION/CONTENT` | The underlying capability exists; what remains is definitions, labels, copy — not code. |

### API-capability shorthand

| Code | API capability | State (verified) |
|---|---|---|
| `API.me` | `GET /api/v1/me` — session identity + permission codes | `LIVE` |
| `API.sites` | `GET /api/v1/sites` — scope-filtered site list | `LIVE` |
| `API.energy.consumption` | `GET /api/v1/sites/{id}/energy/consumption` (`1h`/`1d`) | `LIVE` |
| `API.space.measurements` | `GET /api/v1/spaces/{id}/measurements` (TEMPERATURE/HUMIDITY/DEW_POINT; `raw`/`1h`) | `LIVE` |
| `API.spaces.list` | "spaces for a site" list | `PLANNED (MVP-1)` |
| `API.assets.list` | "assets for a site" list | `PLANNED (MVP-1)` |
| `API.asset.rel` | asset-relationship + asset↔space read objects (component tree, serves-map) | `PLANNED (MVP-1)` |
| `API.asset.measurements` | asset-scoped measurement series | `PLANNED (MVP-1/Post-MVP)` |
| `API.energy.demand` | demand series / peak / load-duration | `PLANNED (MVP-2)` — **underlying analytics verified LIVE** (`analytics.demand_intervals`, `demand_state`, `v_energy_demand_15min`/daily/monthly); only the API+UI layer is missing |
| `API.energy.pq` | power factor / THD series | `PLANNED (MVP-2)` — **underlying telemetry verified LIVE** (`telemetry.energy_measurements.power_factor_*`, `*_thd_*_percent`); only the API+UI layer is missing |
| `API.energy.compare` | period/baseline comparison surface | `PLANNED (MVP-2)` — reads existing historians only, no new data mechanism |
| `API.env.rollup` | site-wide environmental roll-up ("spaces out of band") | `PLANNED (MVP-1/3)` |
| `API.comfort.targets` | per-parameter target/tolerance metadata | `PLANNED (MVP-3)` |
| `API.quality.state` | device/point telemetry state, freshness, connectivity | `PLANNED (MVP-4)` |
| `API.asset.condition` | `asset_health`-backed condition parameters | `PLANNED (Post-MVP)` — not required by Q49–Q101 |
| `API.derived` | persisted derived parameters (COP, baselines) | Phase 6 `LIVE` for SPACE_DEW_POINT; others `PLANNED (Post-MVP)` |
| `API.attention` | predefined-condition Attention/Issues surface | `MISSING` — no shape defined yet; `PLANNED (MVP-3)` |
| `API.alerts` | alert model + list/history | `MISSING`; `PLANNED (MVP-7)` |
| `API.export` | export of series + context | `MISSING`; `PLANNED (MVP-6)` |
| `API.reports` | simple report generation | `MISSING`; `PLANNED (MVP-6)` |
| `API.portfolio` | cross-site aggregation | `MISSING`; `PLANNED (MVP-8, lowest priority)` |
| `API.cost` | tariff-aware cost values | `MISSING` — **verified this session: no `config.tariffs`/`analytics.cost_values`-equivalent table exists anywhere in the schema.** Cross-cutting `DEPENDENCY`, not phase-gated. |
| `API.categories` | functional-category model | `MISSING` + `BLOCKED (PA-2)` — not addressed by Q49–Q101; genuinely still open |
| `API.writes` | any customer-initiated write (saved views, alert rules) | `MISSING` + `BLOCKED (PA-4)`; not required for MVP (Q67: config stays in Administration App) |

---

## 2. Q49–Q101 MVP classification (verified 2026-09-11)

`Q# — decision title → classification → basis`

| Q# | Decision | Class | Verified basis |
|---|---|---|---|
| Q49 | MVP Boundary | — | Process decision, not an implementation item. |
| Q50 | 4 core analytical questions | **B** | Only "how much energy" (`API.energy.consumption`) is live; comparison, issues, and investigation depth are not. |
| Q51 | Site→Space→Asset drill-down | **B** | Site: `A`. Space: `B` (measurements only, no list/detail screen). Asset: `C` (no API surface at all). |
| Q52 | MVP analytical scope | **B** | Energy Consumption `A` (site-level); Demand/PQ `D` (data exists, API+UI missing); Energy Performance `C`; Attention `C`; Space/Asset drill-down `B`/`C`. |
| Q53 | Shared time context | **A** | `TimeRangePicker`/`ranges.ts` landed, Phase 8. |
| Q54 | Comparison baseline | **D** | Definition is fully resolved (see §6 of roadmap / Part 6 of this session's report) — no product decision blocks it; comparison API is unbuilt. Not `E`. |
| Q55 | Expected performance = comparison, not prediction | **A** (as a decision) / **C** (as a capability) | Decision itself is settled; nothing implements it yet. |
| Q56 | Historical comparison types | **D** | Same as Q54 — decided, unbuilt. |
| Q57 | Issues/Attention — analytical not intelligent | **C** | No Attention surface exists. |
| Q58 | MVP investigation | **B** | Depends on Q51's hierarchy, which is itself `B`/`C`. |
| Q59 | Evidence and trust | **B** | `QualityIndicator` component exists; only backs space measurements today. |
| Q60 | Data quality and analytical trust | **B** | Same as Q59. |
| Q61 | MVP landing experience | **B** | Login→site-select shell landed; Site Overview content is `PlaceholderArea`. |
| Q62 | MVP site scope | **A** | Site selection + tenant/site context landed (Phase 8). |
| Q63 | Portfolio experience (included, lower priority) | **C** | No portfolio aggregation API exists; consistent with its decided low priority. |
| Q64 | Portfolio MVP depth | **C** | Same as Q63. |
| Q65 | MVP customer roles (Facility/Energy Manager) | **B** | `ADMIN`/`OPERATOR`/`VIEWER` role model exists and is enforced server-side; no explicit mapping of these to "Facility Manager" persona has been made. |
| Q66 | MVP customer actions (time range, investigation only) | **A** | Time-range change is the only action needed today and is live. |
| Q67 | MVP configuration boundary (Admin Portal owns config) | **A** | Already true architecturally; no change required. |
| Q68 | MVP customer administration (User & Role Mgmt) | **C** | User/role management exists in the Administration App, not in the EMS Web Application surface the decision refers to. |
| Q69 | MVP information architecture | **B** | Routing/shell landed; full IA content not built. |
| Q70 | Site Overview information hierarchy | **C** | No composite Site Overview screen/endpoint exists. |
| Q71 | Overall Site Health (plain summary, not a score) | **C** | Not built. |
| Q72 | Significant Issues/Attention | **C** | Not built (same gap as Q57/Q98). |
| Q73 | MVP financial visibility | **D** | Governing principle decided; **verified this session: zero tariff/cost schema exists.** Genuine data dependency, not a blocker for unrelated energy analytics. |
| Q74 | MVP financial language (measured vs. estimated) | **D** | Same dependency as Q73; the distinction itself is already decided. |
| Q75 | MVP export | **C** | No export capability exists. |
| Q76 | MVP reporting | **C** | No reporting capability exists. |
| Q77 | MVP alerts | **C** | No alert model/endpoint exists. |
| Q78 | MVP alert delivery (in-product) | **C** | Same as Q77. |
| Q79 | Healthy-state experience | **C** | Not built; depends on Q70/Q72 existing first. |
| Q80 | Empty/insufficient data experience | **B** | `EmptyState`/`ErrorState`/`NoDataYet` components exist (Phase 8); not yet exercised against real feature content. |
| Q81 | MVP data freshness | **B** | `quality_code` exists for space measurements only; not for energy/demand. |
| Q82 | MVP data granularity | **B** | `raw`/`1h` (space), `1h`/`1d` (energy) exist; no `5m`/`15m` tier exposed via the API yet, though the underlying aggregation tiers exist per the frozen architecture. |
| Q83 | MVP metric consistency (common grammar) | **F** | Content/design-system work once screens exist; no platform dependency. |
| Q84 | MVP comparison periods (automatic) | **D** | Same status as Q54 — decided, unbuilt. |
| Q85 | MVP metric definitions | **F** | Content work. |
| Q86 | MVP units and terminology | **F** | Content work; API already returns semantic fields, not raw ones, so the platform side is done. |
| Q87 | MVP metric context | **F** | Content work, layered onto MVP-2/3 screens. |
| Q88 | MVP first-time experience | **B** | Login→Select landed; Site Overview→Analyse content not built. |
| Q89 | MVP returning-user experience | **C** | No persisted "last portfolio/site" context found in the frontend state. |
| Q90 | MVP search/quick navigation | **C** | Not built. |
| Q91 | MVP responsive experience | **B** | Shell is scaffolded responsively (Phase 8 foundation); not verified against real feature content because none exists yet. |
| Q92 | MVP performance expectations | **C** | No performance budget or measurement evidence found this session, either way. |
| Q93 | MVP error handling | **B** | Flat error envelope + `EmptyState`/`ErrorState` landed; full coverage depends on feature screens existing. |
| Q94 | Energy Consumption experience | **B** | API live; screen is a placeholder. |
| Q95 | Maximum Demand experience | **D** | Analytics layer verified live; API+UI missing — a build dependency, not a data one. |
| Q96 | Power Quality experience | **D** | Telemetry verified live; API+UI missing — a build dependency, not a data one. |
| Q97 | Energy Performance experience | **D** | Fully specified by Q54–Q56 (see roadmap §6); comparison API unbuilt. |
| Q98 | MVP Attention experience | **C** | Not built. |
| Q99 | MVP Space experience | **B** | Measurements API live; no space list/detail screen. |
| Q100 | MVP Asset experience | **C** | No API surface at all — the largest single MVP gap. |
| Q101 | MVP navigation context | **B** | Shell nav/tenant-site context landed; real breadcrumb content depends on MVP-1/3. |

**Headline, unchanged from the prior session's finding and reconfirmed here:** Asset (Q51/Q52/Q100) has zero platform surface. Attention (Q57/Q72/Q98), Site Overview (Q70/Q71), Portfolio (Q63/Q64), Export/Reporting (Q75/Q76), and Alerts (Q77/Q78) are all `C — NOT LANDED`. Demand and PQ (Q95/Q96) are `D`, not `C` — their data foundations are already built; this is new information from this session's schema verification and materially changes their position in the dependency graph (see roadmap §2, MVP-2).

---

## 3. EMS-REQ traceability matrix (kept for continuity; see §2 for MVP-authoritative view)

The full `Req → Screen(s) → API capability → Semantic/data capability → Phase → Status` matrix from v0.1 is preserved in `ems-customer-requirements.md`'s own requirement table (per Part 9 instruction: requirements are not rewritten here). This document's contribution is the **status verification**: every `LIVE` claim in the original matrix was re-checked this session against `origin/staging` and confirmed accurate; every `PLANNED (Phase N)` reference should now be read against the roadmap v0.2 mapping in §5 of `ems-product-roadmap.md`, since old Phase 9–15 numbers have been re-sequenced into MVP-1..MVP-8.

---

## 4. Blocked-by-decision register (verified 2026-09-11)

| Blocker | Blocks | Status this session | Owner |
|---|---|---|---|
| `PA-2` functional categories have no home in the frozen model | Category-based nav/breakdown | **Still genuinely open** — Q49–Q101 does not address functional categories. Not required for MVP scope as decided. | Product → Architecture |
| `PA-3` cost/tariffs conditional on a real customer requirement | Financial visibility | **Resolved at the scope level** by Q73/Q74 (financial visibility is MVP scope, conditional on defensible data) — but **the data dependency itself remains real and verified**: no tariff schema exists. Reclassified `D — DEPENDENCY`, not an open product question. | Data/config, not product |
| `PA-4` no customer-write mechanism | Self-configurable alerts, saved views | **Resolved** by Q67 — configuration stays in the Administration App; the customer EMS is read-only for MVP. Not a blocker for MVP alerts (Q77/Q78, which are view-only + admin-configured). | — |
| `PA-5` correlations edge toward a query builder | Curated correlations | Not required by Q49–Q101; **Post-MVP**. | — |
| `PA-6` no cross-site aggregation surface | Portfolio | **Resolved at the scope/priority level** by Q63/Q64 (in scope, lowest priority). The API shape itself is still `C — NOT LANDED`. | Architecture (when scheduled) |
| Customer roles undefined | Role-specific overviews | **Partially resolved** by Q65 (Facility/Energy Manager is the primary persona) — the existing `ADMIN`/`OPERATOR`/`VIEWER` model has not yet been explicitly mapped to it. | Product (light) → Engineering |
| Alert model undefined | Alerts | **Resolved at the scope level** by Q77/Q78 (basic, measurable-condition alerts, in-product delivery). Shape/schema still `C — NOT LANDED`. | Engineering |
| Shift-context model missing | Shift analysis | Not addressed by Q49–Q101; **Post-MVP**, consistent with the original MVP scope exclusions. | — |
| Production-quantity source missing | Process KPIs | Not addressed; **Post-MVP**. | — |
| Action log missing | "Did the action work" (MEASURE stage) | Not addressed; explicitly Post-MVP (MEASURE stage, later intelligence). | — |

---

## 5. Anti-pattern guardrails (unchanged from v0.1)

`[WISEWATTS-DECISION]` A requirement or screen is **rejected in review** if it:

- needs data the Analytics API does not expose **and** proposes to reach past the API to get it;
- needs a new database entity/column to support a UI idea (freeze rules apply);
- becomes a free-form query builder / metric-vs-metric explorer / raw-tag browser;
- introduces dynamic SQL anywhere;
- introduces AI/recommendation/anomaly-scoring ahead of its phase;
- requires a change to Phase 6, energy pipelines, Grafana, or the Phase 7 contract without a separate explicit architecture decision;
- makes an energy number that also appears in Grafana without a parity commitment.

---

## 6. Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial traceability matrix for EMS-REQ-001..128; API-capability shorthand + states; buildable-now set; blocked-by-decision register; anti-pattern guardrails. |
| 0.2 | 2026-09-11 | **TRACEABILITY UPDATE.** Added §2, a verified Q49–Q101 classification (A–F scheme) as the MVP-authoritative view. Re-verified every API-capability status against `origin/staging` directly (not inferred). New finding: Demand and Power Quality analytics/telemetry are already live; reclassified from `MISSING`-adjacent to `D — DEPENDENCY` (build-only gap). New finding: no tariff/cost schema exists anywhere — confirmed, not assumed. Updated blocked-by-decision register to reflect which PA-gaps the workshop has since resolved at the scope/priority level vs. which remain genuinely open (PA-2 only, for functional categories). |
