# WiseWatts EMS — Product Roadmap (customer-outcome view)

> **Status:** WORKING DRAFT · **Version:** 0.2 · **Owner:** Product · **Last updated:** 2026-09-11
>
> **Source basis:** `docs/DDS/analytics-platform-future-state-architecture-implementation-roadmap.md` (Phases 7–17, technical objectives), `ems-product-definition.md`, `ems-information-architecture.md`, `ems-product-owner-workshop-baseline.md` §92–134 (Q49–Q101, MVP-scoped decisions), verified state of `origin/staging` (`a5094a1`) as of 2026-09-11.
>
> **This does NOT change the authoritative technical roadmap.** The DDS implementation roadmap's phase objectives are unchanged. **v0.2 re-baselines this document** against two facts that v0.1 (2026-09-10) predates: (1) Phase 7 and Phase 8 are verified **landed and merged** on `origin/staging`, not merely "first slice" in progress; (2) the Product Owner Workshop has since produced Q49–Q101 (MVP-scoped decisions), which resolve most of v0.1's `[OPEN]` items. Where this document and the DDS could drift, the **technical roadmap wins**; where this document and the workshop baseline could drift, the **workshop baseline (Q1–Q101) wins** — this document never restates or re-decides a workshop decision, only sequences the work it implies.

Labels: `[ARCH-CONSTRAINT]` (from the technical roadmap) · `[WISEWATTS-DECISION]` (product framing, workshop-sourced) · `[OPEN]` (genuinely unresolved).

---

## 0. Mapping principle (unchanged from v0.1)

`[WISEWATTS-DECISION]` The customer product is delivered **through** the technical phases, not alongside them. Every customer capability traces to: a **screen** (`ems-information-architecture.md`), an **API capability** (Phase 7 boundary), and a **semantic/data capability** (a DDS mechanism). If any of those three is missing, the capability is not "ready" regardless of how finished the UI looks — enforced by `ems-requirements-traceability.md`.

`[ARCH-CONSTRAINT]` Every phase still requires its own explicit approval before any staging or production change. Nothing here authorises work.

---

## 1. Completed foundation (verified on `origin/staging`, 2026-09-11)

These are **done** — not "in progress," not "first slice pending completion." Verified this session by direct branch comparison (`8118478..origin/staging`) and code inspection, not inferred from commit titles.

### Phase 7 — Analytics API / Query Boundary — **DONE**

- **Landed:** `b923f88`, `6225970` (PR #43, merged).
- **What exists:** `GET /api/v1/sites`, `GET /api/v1/sites/{id}/energy/consumption` (`1h`/`1d`), `GET /api/v1/spaces/{id}/measurements` (TEMPERATURE/HUMIDITY/DEW_POINT; `raw`/`1h`). Tenant/site/space access is enforced server-side (`admin.portal_user_can_access_site`, `analytics.portal_user_can_access_space`, migration 231) — an inaccessible or unknown resource is a 404, indistinguishable from "doesn't exist." `no_data` is a normal 200. Flat error envelope.
- **Not yet extended:** no Demand, Power Quality, Asset, comparison/baseline, Attention, cost, alert, export, or reporting endpoints exist. This is the majority of the remaining MVP work — see §2.

### Phase 8 — Frontend Foundation (EMS Web Application shell) — **DONE**

- **Landed:** `e5fd026` … `7c4349a` (10 commits), plus the boundary doc PR #44.
- **What exists (verified against the `web/` file diff, 69 files):** `GET /api/v1/me` session bootstrap; `SessionProvider`/`TenantProvider`/`RequirePermission`; `TimeRangePicker`/`ranges.ts` (shared time context); `ChartFrame` (one charting foundation); `QualityIndicator`, `EmptyState`/`ErrorState`/`NoDataYet`/`Loading`; `AppLayout`/`router.tsx`/`navigation.ts`; `ShellHome.tsx`, `SelectContext.tsx`. Independently built/deployed `-web:<sha>` artifact, mounted read-only into the admin-portal container and served same-origin under `/app`.
- **Confirmed NOT built:** `PlaceholderArea.tsx` is the literal content of every feature screen. No Spaces, Assets, Demand, PQ, Attention, Portfolio, Alerts, Export, or Reports screen exists in the diff. This matches the technical roadmap's own Phase 8 exit criterion ("empty shell").

**Correction from v0.1:** v0.1 marked these "*(done: first slice on staging)*" as an aside; v0.2 treats them as a completed foundation layer with its own section, because the workshop's Q49–Q101 MVP scope is now the thing being sequenced against, not against.

---

## 2. MVP completion work

`[WISEWATTS-DECISION]` Re-sequenced from v0.1's Phase 9–15 screen-by-screen order onto the actual **dependency graph** verified this session (§ below), and onto Q49–Q101 as the product contract. Old phase numbers are kept where the technical roadmap already names that phase; renumbered stages are labelled `MVP-n` and cross-referenced to their nearest old phase for continuity. **No old phase is pretended not to have existed** — see §5 mapping table.

### MVP-1 (old Phase 9 core) — Hierarchy & Navigation Foundation

- **Customer decisions served:** Q51 (Site→Space→Asset drill-down), Q99 (Space as contextualised drill-down, not primary nav), Q100 (Asset — narrower, data-driven view), Q62 (Site as primary context), Q101 (navigation context always visible).
- **Delivers:** "spaces for a site" list endpoint, "assets for a site" list endpoint, asset-relationship + asset↔space read objects (component tree, serves-map) — all additive `v_grafana_*`-pattern views/functions through Phase 7, per its established extension model. Frontend: real Spaces list/detail, real Assets list/detail replacing `PlaceholderArea`.
- **Why first:** every other MVP screen (Site Overview, Attention, Investigation, Export) needs a customer to be able to reach a space or asset by name. It is also the **only** area needing solely additive API work with a data/semantic layer that already exists in full (`metadata.spaces`, `metadata.assets`, `asset_relationships`, `space_points`) — confirmed by direct schema inspection this session.
- **Status of underlying data:** LIVE (schema + relationships already exist; only the read-API surface is missing).

### MVP-2 (old Phase 10 core) — Core Energy Analytics

- **Customer decisions served:** Q50/Q52 (the 4 core analytical questions; Energy Consumption, Max Demand, Power Quality, Energy Performance), Q54/Q55/Q56/Q97 (comparison baseline — see §6 for the resolved definition), Q84 (automatic comparison periods), Q94/Q95/Q96 (per-area experience).
- **Delivers, in dependency order (verified this session):**
  1. **Energy Consumption comparison** — extends the already-LIVE consumption endpoint with previous-period / same-period-previously / rolling-average comparison, reading the existing `analytics.energy_consumption_hourly/daily` historians. No new data pipeline.
  2. **Maximum Demand** — API + UI only. **Verified this session:** the demand *calculation* layer already exists in full (`analytics.demand_intervals`, `analytics.demand_state`, `analytics.v_energy_demand_15min`/daily/monthly views, `config.site_demand_policies` for calculation methodology) — nothing here is a new analytical capability, only a missing Phase 7 endpoint and a missing screen. Contracted-demand *limit* is a separate, smaller admin-config gap (see §7).
  3. **Power Quality (PF/THD)** — API + UI only. **Verified this session:** `telemetry.energy_measurements` already carries `power_factor_total/l1/l2/l3` and `*_thd_*_percent` columns. Same shape of gap as Demand — no new telemetry needed.
- **Status of underlying data:** LIVE for all three (consumption, demand, PF/THD) at the telemetry/analytics layer; the gap is entirely API + frontend.

### MVP-3 (old Phase 9/10 composite) — Site Overview & Attention

- **Customer decisions served:** Q61 (landing experience), Q70/Q71 (Site Overview information hierarchy, Overall Health as a plain-language summary, not a proprietary score), Q57/Q72/Q98 (Attention — analytical, not intelligent, predefined conditions only), Q79 (healthy-state messaging), Q80 (empty/insufficient-data states).
- **Delivers:** a real composite Site Overview screen (not the current `ShellHome` placeholder) built from MVP-1 and MVP-2's endpoints; a predefined-condition Attention surface (thresholds on existing metrics — no anomaly scoring, no ML).
- **Depends on:** MVP-1 (hierarchy for "where") + MVP-2 (analytics for "how much/how are we doing").

### MVP-4 (old Phase 12, narrowed) — Data Quality & Freshness

- **Customer decisions served:** Q59/Q60 (evidence and trust), Q81 (data freshness visible), Q93 (customer-friendly error states).
- **Delivers:** the `QualityIndicator` primitive (already scaffolded, Phase 8) backed by real `quality_code`/freshness state on energy and demand series, not just space measurements (already live there).
- **Note:** v0.1's Phase 12 also included a full connectivity/ops-style "Data Quality" screen (`device_telemetry_state`); Q81 only requires freshness to be *visible wherever it matters*, not a dedicated diagnostic screen. The dedicated screen is now **Post-MVP** unless a later decision expands it (§3).

### MVP-5 — Content & Metric Grammar

- **Customer decisions served:** Q83 (common analytical grammar), Q85 (metric definitions), Q86 (units/terminology), Q87 (metric context).
- **Delivers:** copy/content work layered onto MVP-2/3's screens — definitions, units, contextual qualifiers. **Not a new API or schema dependency** — classified `F — DOCUMENTATION/CONTENT` in §Part-2 below. Can run in parallel with MVP-2/3 once their screens exist to attach content to.

### MVP-6 (old Phase 15, narrowed) — Export & Basic Reporting

- **Customer decisions served:** Q75 (export — underlying data + context, not a BI tool), Q76 (reporting — deliberately simple, derived from Site Overview/Energy Analytics, no scheduling/builder/narratives).
- **Depends on:** MVP-3 (Site Overview is the reporting source) + MVP-2 (the energy/demand/PQ figures being exported).

### MVP-7 (old Phase 10, deferred sub-scope) — Basic Alerts

- **Customer decisions served:** Q77 (basic customer alerts on clear, measurable conditions), Q78 (in-product delivery), Q67 (alert *configuration* stays in the Administration App).
- **Depends on:** MVP-3's Attention thresholds (an alert is the same predefined-condition logic, delivered as a notification rather than a screen state).

### MVP-8 (old Phase 9/13, narrowed) — Portfolio Experience

- **Customer decisions served:** Q63/Q64 (portfolio **is** in MVP scope, but is explicitly the **lowest-priority** MVP experience).
- **Depends on:** MVP-1/2/3 existing per-site first (portfolio is a roll-up of site-level capability that must already be real).
- **Sequencing note:** this is placed last among MVP work **because the workshop decided its priority is lowest**, not because of a technical dependency alone — an explicit product-priority call, not an inferred one.

### Financial / tariff track — cross-cutting, data-dependent (not phase-gated)

- **Customer decision served:** Q73/Q74 (financial visibility is part of MVP *wherever accurate and sufficiently configured*; otherwise show the underlying technical metric — never manufacture financial precision).
- **Verified this session:** no tariff, contracted-demand-limit, or cost table exists anywhere in the schema (`config.tariffs` / `analytics.cost_values` referenced in prior docs do not exist as tables — they were placeholder names for an undesigned capability). This is a genuine data/configuration dependency, not an implemented-but-hidden capability.
- **Does not block** MVP-2's Demand/PQ/Consumption work, which stand on their own as technical metrics per Q73's own governing principle. See §7.

---

## 3. Post-MVP (explicitly deferred by the workshop — not re-litigated here)

`[ARCH-CONSTRAINT] + [WISEWATTS-DECISION]` Carried forward from Q1–Q48 (long-term direction) and the explicit MVP exclusions named in the original task framing: recommendations, root-cause intelligence, intelligent prioritisation, adaptive/predictive intelligence, action logging, verification workflows, AI, automation, sophisticated benchmarking. Also deferred by specific Q49–Q101 decisions:

- Weather/occupancy/production-normalised comparisons (Q56 — explicitly not attempted in MVP).
- Adaptive/predictive baselines (Q55 — comparison only, not prediction, in MVP).
- A dedicated connectivity/ops-style Data Quality screen beyond freshness visibility (see MVP-4 note).
- Multi-channel alert delivery beyond in-product (Q78 names in-product as the MVP delivery channel; other channels are not decided against, simply not specified as MVP).
- Old Phase 11 (Asset Performance / condition monitoring, motor-domain `asset_health`) and old Phase 13 (baseline overlays, cross-asset league tables), old Phase 14 (cost/benchmarking/insights/recommendations foundations), old Phase 16 (hardening/scale) — these remain real technical-roadmap phases; none is "cancelled," they are simply not required to satisfy Q49–Q101 and are sequenced after MVP completion.
- Old Phase 17 (Grafana customer-workflow migration) is an ongoing parity-gated migration process, not a single deliverable — it starts once MVP-2's numbers are parity-proven against Grafana and continues past MVP as a long tail; tracked separately, not treated as a blocking MVP stage.

---

## 4. Capability → stage summary

| Customer capability | MVP stage | Underlying data/API status (verified) |
|---|---|---|
| Site/Space/Asset navigation | MVP-1 | Schema LIVE; API MISSING |
| Energy Consumption + comparison | MVP-2 | Consumption LIVE; comparison MISSING (API only) |
| Maximum Demand | MVP-2 | Analytics LIVE; API + UI MISSING |
| Power Quality (PF/THD) | MVP-2 | Telemetry LIVE; API + UI MISSING |
| Site Overview | MVP-3 | Composite; depends on MVP-1/2 |
| Attention / Issues | MVP-3 | MISSING (predefined-condition logic, not built) |
| Data freshness/quality on energy & demand | MVP-4 | Primitive scaffolded (Phase 8); real backing MISSING |
| Metric grammar/definitions/units | MVP-5 | Content only, no platform dependency |
| Export | MVP-6 | MISSING; depends on MVP-2/3 |
| Basic reporting | MVP-6 | MISSING; depends on MVP-3 |
| Basic alerts | MVP-7 | MISSING; depends on MVP-3's Attention logic |
| Portfolio | MVP-8 | MISSING; lowest MVP priority by decision |
| Financial visibility | Cross-cutting | No tariff/cost data exists anywhere; genuine dependency, not a blocker for the above |

---

## 5. Old phase number → current stage mapping (historical continuity)

| Old phase (DDS roadmap) | Status | Where it lives now |
|---|---|---|
| Phase 7 — Analytics API | **DONE** | §1 |
| Phase 8 — Frontend Foundation | **DONE** | §1 |
| Phase 9 — Core Site/Asset/Space UX | Split | Hierarchy → MVP-1; Site Overview → MVP-3 |
| Phase 10 — Energy Analytics | Split | Consumption/Demand/PQ → MVP-2; Attention-adjacent Alerts → MVP-7 |
| Phase 11 — Asset Performance | Deferred | Post-MVP (§3) — not required by Q49–Q101 |
| Phase 12 — Real-Time and Data Quality | Narrowed | Freshness-on-existing-series → MVP-4; full connectivity screen → Post-MVP |
| Phase 13 — Advanced Efficiency Analytics | Deferred | Post-MVP (§3) — Q56 excludes normalised/adaptive baselines from MVP |
| Phase 14 — Cost/Benchmarking/Intelligence | Split | Cost data dependency → Financial track (§2); benchmarking/insights/recommendations → Post-MVP |
| Phase 15 — Reporting | Narrowed | Simple export/report → MVP-6; scheduling/report-builder → Post-MVP |
| Phase 16 — Hardening and Scale | Unchanged | Post-MVP, ongoing technical-quality track |
| Phase 17 — Grafana Migration | Unchanged | Post-MVP, ongoing parity-gated migration (§3) |

---

## 6. Proposed MVP starting point (supersedes v0.1 §5)

`[WISEWATTS-DECISION]` Start with **MVP-1 (hierarchy/navigation)**, not the v0.1 "start with Spaces only" proposal, because:

1. Q49–Q101 now define the **full** MVP analytical scope (Q52) — Energy Consumption, Max Demand, PQ, Energy Performance, Attention, and Space/Asset drill-down are all explicitly in scope together, not staged as "Spaces first, energy later." Sequencing by data-readiness (MVP-1 → MVP-2) is a dependency call, not a scope-narrowing one.
2. Every MVP-2/3 screen needs a customer to be able to reach a space or asset by name first — MVP-1 is the one stage every later stage depends on.
3. v0.1's blocking-questions list (§5, old doc) — landing page, portfolio-vs-site, Site Overview headline metrics, investigation depth, Space nav-vs-drilldown, roles — is **now resolved** by Q61/Q62/Q70/Q71/Q51/Q99/Q65 respectively. **No product decision blocks starting MVP-1.**

---

## 7. Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial working draft. Customer-outcome view of Phases 7–17, capability→phase map, proposed Phase 9 starting point. |
| 0.2 | 2026-09-11 | **ROADMAP RE-BASELINE.** Verified Phase 7/8 as landed (not first-slice-in-progress) against `origin/staging` (`a5094a1`). Re-sequenced remaining work as MVP-1..MVP-8 by dependency + Q49–Q101 customer-value priority, replacing the old arbitrary Phase 9–15 screen order. Added verified findings: Demand and Power Quality analytics/telemetry already exist in full (only API+UI missing); no tariff/cost schema exists anywhere. Old phase numbers preserved via §5 mapping table, not discarded. Post-MVP section separates what the workshop explicitly deferred from what simply isn't required yet.|
