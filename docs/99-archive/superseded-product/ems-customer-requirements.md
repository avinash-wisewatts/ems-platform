# WiseWatts EMS — Customer Requirements Catalogue

> **Status:** WORKING DRAFT  ·  **Version:** 0.1  ·  **Owner:** Product  ·  **Last updated:** 2026-09-10
>
> **Source basis:** product-owner brief (§4–§16), `ems-product-definition.md`, `ems-information-architecture.md`, `ems-product-roadmap.md`, DDS + roadmap (Phases 7–17), ZeroWatt technical overview's 25-capability catalogue (reference only).
>
> This is an **initial catalogue**. Priorities are a **starting hypothesis**. Items marked **PO-REVIEW** need product-owner confirmation. Inference is never silently promoted to fact.

---

## 1. Conventions

**ID:** `EMS-REQ-NNN` (stable once assigned).

**Priority:**

| Value | Meaning |
|---|---|
| `MUST` | Required for the relevant product phase. |
| `SHOULD` | Important, not blocking the initial release. |
| `COULD` | Useful future enhancement. |
| `LATER` | Explicitly deferred. |
| `NOT-IN-SCOPE` | Rejected or intentionally outside the customer EMS. |

**Source** (may be multiple): `PRODUCT_OWNER` · `ARCHITECTURE` (DDS) · `ROADMAP` · `ZEROWATT_DEMO` · `ZEROWATT_TECHNICAL_REFERENCE` · `INFERENCE`.

**Status:** `DRAFT` · `PO-REVIEW` (needs product-owner decision) · `BLOCKED` (needs an architecture/API decision — see `Dependencies`) · `READY-FOR-DESIGN` (agreed enough to design against).

**Phase:** the technical roadmap phase that would deliver it (`8`–`17`), or `—`.

**Dependencies:** other `EMS-REQ` ids, roadmap phases, API capabilities, or `PA-n` gaps from `ems-product-architecture.md` §9.

Every requirement is expressed **business-question-first**: *customer question → capability → metric/semantic concept → required data → visualisation/interaction*.

---

## 2. Foundation & platform boundary

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-001 | **Separate customer application.** The customer EMS is a distinct application from the Administration App, not a redesign of it. | — (product principle) | MUST | PRODUCT_OWNER, ARCHITECTURE | 8 | READY-FOR-DESIGN | PR #44 | DDS §F.0. |
| EMS-REQ-002 | **Analytics-API-only data access.** The customer app reads exclusively via `/api/v1/*`; never DB / TimescaleDB / Grafana / internal objects. | — | MUST | ARCHITECTURE | 7–8 | READY-FOR-DESIGN | Phase 7 | No query builder, no dynamic SQL. |
| EMS-REQ-003 | **No implementation identifiers exposed.** No device IDs, logical-point IDs, raw field names, Grafana org/datasource IDs, table/column/SQL, migration numbers in the customer UI. | "What am I looking at?" (in my terms) | MUST | PRODUCT_OWNER, ARCHITECTURE | 8+ | READY-FOR-DESIGN | EMS-REQ-002 | Deep-link URLs may use opaque semantic IDs already surfaced by the API. |
| EMS-REQ-004 | **Shared authentication.** Reuse the existing signed session (`ems_admin_session`); no parallel auth system; no secrets in JS. | "Log me in once." | MUST | ARCHITECTURE | 8 | READY-FOR-DESIGN | — | Same-origin delivery so the cookie flows to `/api/v1`. |
| EMS-REQ-005 | **Server-side authorisation is authoritative.** Tenant/site/space access enforced by the API; frontend permission checks gate UX only. | "Only show me what I'm allowed to see." | MUST | ARCHITECTURE | 7–8 | READY-FOR-DESIGN | — | SECURITY DEFINER functions; 404-no-leak for inaccessible resources. |
| EMS-REQ-006 | **Independently deployable & rollbackable.** Ship/rollback the EMS Web App without changing the Administration App, Grafana, DB, Phase 6, or energy. | — | MUST | PRODUCT_OWNER, ARCHITECTURE | 8 | READY-FOR-DESIGN | — | Preferred: separate image/container (implementation decision, not a frozen requirement). `/app` is a routing detail. |
| EMS-REQ-007 | **Grafana stays OPS/engineering.** Customer-facing Grafana workflows migrate only via the Phase 17 per-workflow parity process. | — | MUST | ARCHITECTURE, ROADMAP | 10–17 | READY-FOR-DESIGN | Phase 10 parity, Phase 17 | Grafana is never the customer UI. |
| EMS-REQ-008 | **No Phase 7 contract change without an explicit architecture decision.** New needs are additive views/functions or a logged dependency. | — | MUST | ARCHITECTURE | 7+ | READY-FOR-DESIGN | — | |

---

## 3. Navigation & context

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-010 | **Organisation / portfolio context.** The signed-in user's organisation and its sites are the top of navigation. | "Which of my facilities?" | MUST | PRODUCT_OWNER, ROADMAP | 8–9 | READY-FOR-DESIGN | `GET /api/v1/sites` (LIVE) | Grouping/region `[OPEN]`. |
| EMS-REQ-011 | **Site context & selection.** Choose a site; all site-scoped screens follow the selection. | "Take me to Radisson Blu." | MUST | PRODUCT_OWNER | 8–9 | PO-REVIEW | EMS-REQ-010 | Multi-site selection pattern = `OPEN #4`. |
| EMS-REQ-012 | **Portfolio vs. site landing.** Multi-site users land at portfolio level or on a site (TBD); single-site users skip portfolio. | "Where do I start?" | MUST | PRODUCT_OWNER | 9 | PO-REVIEW | EMS-REQ-010 | `OPEN #1`, `OPEN #2`. Design supports both. |
| EMS-REQ-013 | **Semantic breadcrumb.** Every screen shows `Organisation ▸ Site ▸ Space/Asset ▸ Parameter`, clickable, no IDs. | "Where am I?" | MUST | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | 8–9 | READY-FOR-DESIGN | EMS-REQ-003 | The "no raw-tag overload" principle. |
| EMS-REQ-014 | **Spaces navigation.** Browse a site's spaces; open a space's environmental detail. | "What's the temperature in Banquet Hall 2?" | MUST | PRODUCT_OWNER, ARCHITECTURE | 9 | READY-FOR-DESIGN | "spaces for a site" endpoint (PLANNED P9); `/spaces/{id}/measurements` (LIVE) | Space-as-nav vs. drill-down = `OPEN #11`. |
| EMS-REQ-015 | **Assets navigation.** Browse a site's assets/systems; open an asset. | "Show me my chillers." | MUST | PRODUCT_OWNER, ARCHITECTURE | 9 | READY-FOR-DESIGN | "assets for a site" endpoint (PLANNED P9) | |
| EMS-REQ-016 | **Asset component tree.** Navigate `AHU-01 → Fan → Motor` via `asset_relationships`. | "What's this made of?" | SHOULD | ARCHITECTURE, ZEROWATT_TECHNICAL_REFERENCE | 9 | READY-FOR-DESIGN | Phases 2/9; asset-relationship read object | Context-aware system (ZW #21). |
| EMS-REQ-017 | **Spaces served by an asset / assets serving a space.** Bidirectional `asset_space_relationships`. | "What conditions this room?" | SHOULD | ARCHITECTURE | 9 | READY-FOR-DESIGN | Phases 2/9 | |
| EMS-REQ-018 | **Functional categories in navigation.** Group meters/assets into meaningful categories (HVAC, Lighting, Process…). | "Show me HVAC vs. Process." | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | 10 | BLOCKED | PA-2; `OPEN #12` | No clean home in the frozen model yet. Do not design category nav until resolved. |
| EMS-REQ-019 | **Deep-linkable screens.** URLs encode semantic context (site/space/asset + time range) for sharing/bookmarking. | "Send my colleague this exact view." | SHOULD | INFERENCE | 9+ | DRAFT | EMS-REQ-003 | Opaque semantic IDs only. |

---

## 4. MONITOR — "How are we doing?"

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-020 | **Site Overview.** A single MONITOR screen per site with headline KPIs + a path to "why". | "How is this facility doing?" | MUST | PRODUCT_OWNER | 9–10 | PO-REVIEW | EMS-REQ-021..025; `OPEN #3` | Candidate landing page. |
| EMS-REQ-021 | **Energy vs. expected/baseline.** Consumption for the period with a comparison (previous period; baseline once it exists). | "Is today's consumption normal?" | MUST | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | 10 (baseline 13) | READY-FOR-DESIGN | `energy/consumption` (LIVE); comparison (P10); baseline (P13) | "Comparison to expected/baseline performance." |
| EMS-REQ-022 | **Current & peak demand vs. contracted.** Show demand now, peak in period, and the contracted/agreed limit. | "Are we near our demand limit?" | MUST | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | 10 | BLOCKED | demand series via Phase 7 (PLANNED P10) | Maximum-demand analysis (ZW #9). |
| EMS-REQ-023 | **Environmental status roll-up.** Count/List of spaces in vs. out of comfort band. | "Are any rooms uncomfortable?" | MUST | PRODUCT_OWNER | 9 | READY-FOR-DESIGN | `/spaces/{id}/measurements` (LIVE); site roll-up (PLANNED P9); comfort targets | |
| EMS-REQ-024 | **Data-quality / connectivity health.** A single honest signal: is the data trustworthy and current? | "Can I trust these numbers?" | MUST | PRODUCT_OWNER, ARCHITECTURE | 12 | READY-FOR-DESIGN | `device_telemetry_state` via Phase 7 (PLANNED P12) | Quality scaffolding exists (P8). |
| EMS-REQ-025 | **Cost-to-date vs. budget.** Money view on the overview. | "What has this cost so far?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | 14 | BLOCKED | PA-3; `OPEN #7`; `config.tariffs` | Only if tariffs are built. |
| EMS-REQ-026 | **Portfolio Overview.** Multi-site health tiles + "sites needing attention". | "Which site should I worry about?" | SHOULD | PRODUCT_OWNER | 9–13 | PO-REVIEW | PA-6; `OPEN #2` | Cross-site aggregation surface undefined. |
| EMS-REQ-027 | **Period comparison ("compare to previous").** Any headline metric can be shown against the equivalent prior period. | "Better or worse than last month?" | MUST | PRODUCT_OWNER | 10 | READY-FOR-DESIGN | EMS-REQ-021 | Basic comparisons (PO §13 MUST). |
| EMS-REQ-028 | **Notable-events strip.** Short list of period highlights (e.g. "demand peak 14:20", "Kitchen out of band 09:00–11:00"). | "What happened today?" | SHOULD | INFERENCE, ZEROWATT_DEMO | 10–12 | DRAFT | EMS-REQ-022, EMS-REQ-023 | Not "insights"; deterministic period facts. |

---

## 5. INVESTIGATE — "Why is this happening?"

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-030 | **Progressive drill-down.** Every KPI opens toward: time → system → asset → space → underlying measurement. | "Why did this number move?" | MUST | PRODUCT_OWNER | 9–11 | PO-REVIEW | `OPEN #4` (how far); EMS-REQ-016/017 | The core INVESTIGATE loop. Depth is a PO decision. |
| EMS-REQ-031 | **Energy consumption trend + spike inspection.** Trend at appropriate resolution; click a spike to zoom to its window. | "When did consumption deviate, and by how much?" | MUST | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | 10 | READY-FOR-DESIGN | `energy/consumption` (LIVE) | Resolution ladder 1min–daily as supported. |
| EMS-REQ-032 | **Demand peak investigation.** Zoom to a peak; see contributing assets/systems and their timing. | "Why did demand peak, and what was running?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | 10–11 | BLOCKED | demand series (P10); contributing-equipment attribution (P10/11) | Maximum-demand analysis with equipment attribution (ZW #9). |
| EMS-REQ-033 | **Energy breakdown.** Consumption split by functional category / system / meter role; explicit "unaccounted" residual. | "Where is the energy going?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | 10 | BLOCKED | PA-2; `OPEN #12` | Functional categories (ZW #7). |
| EMS-REQ-034 | **Space environmental trend with comfort band.** Per-parameter trend; target/`direction_of_good` overlay where present. | "Was the room too hot, and for how long?" | MUST | PRODUCT_OWNER, ARCHITECTURE | 9 | READY-FOR-DESIGN | `/spaces/{id}/measurements` (LIVE); comfort targets (PLANNED) | Dew point from Phase 6 persisted tier — never browser-calculated. |
| EMS-REQ-035 | **Asset measurements (leaf view).** The honest, contextual list/trend of an asset's parameters with attribution ("attributed to Motor A" / "unattributed"). | "Show me the actual readings." | SHOULD | ARCHITECTURE, ZEROWATT_TECHNICAL_REFERENCE | 9–11 | DRAFT | asset-scoped measurements (PLANNED P9/11) | Semantic attribution, not device IDs. |
| EMS-REQ-036 | **Curated correlations.** Pre-defined pairs (energy vs. outside temp; HVAC power vs. space temp). | "Does my energy track the weather?" | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | 10–13 | DRAFT | PA-5; curated correlation series | **Curated only** — never free-form metric-vs-metric. |
| EMS-REQ-037 | **Trends (curated multi-series).** Plot several named semantic series on aligned timelines. | "How have these moved together?" | MUST | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | 9–10 | READY-FOR-DESIGN | curated series catalogue | Aligned timelines (ZW #1). No tag browser. |
| EMS-REQ-038 | **Comparisons (like-for-like).** Compare periods, sites, spaces, or same-type assets. | "Is this better or worse than X?" | SHOULD | PRODUCT_OWNER | 13 | DRAFT | cross-asset comparison views (P13) | Asset comparison only within one `asset_type_id` (fairness rule). |

---

## 6. Energy detail

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-040 | **Energy consumption workflow (parity with Grafana).** Consumption, load profile, comparisons — numerically identical to the existing dashboards. | "How much energy did we use?" | MUST | ROADMAP | 10 | READY-FOR-DESIGN | Phase 10 parity gate | Grafana remains system of record until Phase 17 acceptance. |
| EMS-REQ-041 | **Demand workflow (parity).** Demand trend, peak, load-duration. | "What was our demand profile?" | MUST/SHOULD | ROADMAP | 10 | BLOCKED | demand via Phase 7 (PLANNED) | |
| EMS-REQ-042 | **Multi-utility monitoring.** Energy plus water, gas, thermal, process values on aligned timelines. | "Show energy and water together." | SHOULD | ZEROWATT_TECHNICAL_REFERENCE | 10–12 | DRAFT | `water_measurements`/fuel-thermal wired to loaders (Phase 3+) | Unified multi-parameter monitoring (ZW #1). |
| EMS-REQ-043 | **Power-quality analysis.** Voltage, current, power factor, harmonics at high resolution; imbalance & out-of-tolerance highlighting. | "Is my supply healthy?" | SHOULD | ZEROWATT_TECHNICAL_REFERENCE | 11/13 | DRAFT | high-res electrical params via Phase 7 | ZW #16. Phase labels shown as friendly `L1/L2/L3`. |
| EMS-REQ-044 | **Exact tariff costing.** Rate × consumption incl. time-of-day rates and demand charges. | "What did that cost, exactly?" | SHOULD/LATER | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | 14 | BLOCKED | PA-3; `config.tariffs`/`analytics.cost_values`; `OPEN #7` | Rate model, not a billing engine. |
| EMS-REQ-045 | **Custom process KPIs.** Domain KPIs such as energy per unit of production. | "What's our kWh per tonne?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | 13–14 | DRAFT | production data source (none today) | ZW #11. Needs a production-quantity input. |
| EMS-REQ-046 | **Automatic running hours.** Equipment running hours computed from telemetry. | "How long did the compressor run?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | derived-parameter calc; not scheduled | ZW #12. |
| EMS-REQ-047 | **Start-up detection.** Identify equipment starts and abnormal start-up behaviour. | "Did the chiller short-cycle?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | detection logic in analytics code; not scheduled | ZW #10. |
| EMS-REQ-048 | **Shift-wise views.** Energy/production framed by shift context. | "How did the night shift do?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | no shift-context model exists; `[OPEN]` | ZW #18. |
| EMS-REQ-049 | **Live single-line / energy-flow view.** Visualise power flow and energy balance. | "Show power flowing through my site." | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | real-time model; `config.site_energy_meter_roles` as a basis | ZW #6. Significant; deferred. |

---

## 7. Environment

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-050 | **Environmental measurements per space.** Temperature, humidity, dew point (and more as wired) with quality. | "What are the conditions in this space?" | MUST | PRODUCT_OWNER, ARCHITECTURE | 9 | READY-FOR-DESIGN | `/spaces/{id}/measurements` (LIVE) | DEW_POINT = Phase 6 persisted. |
| EMS-REQ-051 | **Site-wide environmental grid/map.** All spaces' current value for a chosen parameter; in/out of band. | "Which rooms are out of comfort?" | MUST | PRODUCT_OWNER | 9 | READY-FOR-DESIGN | site environmental roll-up (PLANNED P9) | |
| EMS-REQ-052 | **Comfort band overlay.** Target/tolerance band on environmental trends. | "Was it within target?" | SHOULD | ARCHITECTURE | 9–12 | DRAFT | `direction_of_good`/target metadata on parameters | |
| EMS-REQ-053 | **Additional environmental parameters.** CO₂, occupancy, pressure surfaced consistently as they are wired. | "What about air quality?" | COULD | ARCHITECTURE, ZEROWATT_TECHNICAL_REFERENCE | 9–12 | DRAFT | `space_points` for those parameters; loaders | Modular expansion (ZW #3). |
| EMS-REQ-054 | **Environment ↔ energy correlation (curated).** e.g. HVAC energy vs. space temperature. | "Is HVAC working harder than it should?" | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | 10–13 | DRAFT | PA-5; curated pair | |

---

## 8. Assets & performance

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-060 | **Asset Overview.** Status, key parameters, component tree, spaces served, recent events. | "How is this chiller doing?" | MUST | PRODUCT_OWNER, ARCHITECTURE | 9 (structure) / 11 (condition) | READY-FOR-DESIGN | EMS-REQ-015/016/017 | |
| EMS-REQ-061 | **Asset Performance / condition monitoring.** Runtime, vibration, temperatures, operating status, per-asset efficiency (motor domain first). | "Is this equipment degrading?" | SHOULD | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | 11 | DRAFT | `asset_health` + derived params via Phase 7 | Extends to other domains after motor reference validated. |
| EMS-REQ-062 | **Derived efficiency parameters (e.g. COP).** Consume Phase 6 persisted derived values; never compute in the browser. | "What's the plant efficiency?" | SHOULD | ARCHITECTURE | 11–13 | DRAFT | `parameter_calculations`/`derived_parameter_values` | |
| EMS-REQ-063 | **Baseline / expected-performance overlays.** "Compared to what?" bands on energy & asset views. | "Is this normal for these conditions?" | SHOULD | ROADMAP | 13 | DRAFT | baseline as `parameter_calculations` specialization | Probabilistic; bake-in before exposure. |
| EMS-REQ-064 | **Cross-asset comparison.** Compare derived values across assets sharing an `asset_type_id`. | "Which of my 5 AHUs is worst?" | SHOULD | ROADMAP, ARCHITECTURE | 13 | DRAFT | cross-asset comparison views | Fairness rule enforced. |
| EMS-REQ-065 | **Operating envelope view.** Show an asset's operation against its normal envelope. | "Is it operating outside its normal range?" | COULD | ROADMAP | 13 | DRAFT | EMS-REQ-063 | |

---

## 9. Data quality & real-time

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-070 | **Consistent quality indicators.** `GOOD/GAP/ESTIMATED/INVALID/PARTIAL` rendered wherever a value/series appears; `null` renders nothing. | "How good is this reading?" | MUST | ARCHITECTURE, PRODUCT_OWNER | 8 (scaffold) / 12 (real) | READY-FOR-DESIGN | — | Never invent a quality value the API didn't return. |
| EMS-REQ-071 | **No-data as a normal state.** Newly-commissioned/uncommissioned/pre-history reads as "no data yet", never an error. | "Why is this empty?" | MUST | ARCHITECTURE | 8 | READY-FOR-DESIGN | — | Explain *why* where possible. |
| EMS-REQ-072 | **Graceful resolution degradation.** If a tier isn't commissioned (e.g. `energy_consumption_5min`), fall back to a coarser tier with a note. | "Why only hourly here?" | SHOULD | INFERENCE, ARCHITECTURE | 10–12 | DRAFT | — | Known staging commissioning gap. |
| EMS-REQ-073 | **Customer-facing connectivity / freshness view.** Live status, last-seen, communication health, point-level quality. | "Is anything offline?" | SHOULD | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | 12 | DRAFT | `device_telemetry_state`/`device_status`/`device_live_point_state` via Phase 7 | Not the ops SQL playbook. |
| EMS-REQ-074 | **High-resolution + aggregated views.** Support detailed (seconds/minute) data and useful hourly/daily/weekly/monthly aggregation. | "Zoom into the second; zoom out to the month." | MUST | ZEROWATT_TECHNICAL_REFERENCE | 9–10 | READY-FOR-DESIGN | resolution ladder; API resolution params | ZW #5. Clamped to API-supported resolutions. |

---

## 10. Alerts

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-080 | **View active & historical alerts.** Semantic subject, severity, value vs. threshold, time, status. | "What's wrong right now?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | — | BLOCKED | `OPEN #6`; no alert model/endpoint defined; relation to `analytics.insights` (P14) | Alerts ≠ insights conceptually. |
| EMS-REQ-081 | **Alert → context navigation.** From an alert, jump to the metric's screen at the relevant time. | "Show me what triggered this." | SHOULD | INFERENCE | — | DRAFT | EMS-REQ-080, EMS-REQ-030 | |
| EMS-REQ-082 | **Self-configurable alert rules.** Customers/plant users define alert rules. | "Alert me if the freezer goes above −18 °C." | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | BLOCKED | PA-4; config primarily in the Administration App | ZW #13. Introduces customer-write; needs an audited mechanism. |
| EMS-REQ-083 | **Demand-approaching alerts.** Warn when demand nears the contracted limit. | "Are we about to exceed contracted demand?" | COULD | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | — | DRAFT | EMS-REQ-022, EMS-REQ-080 | |
| EMS-REQ-084 | **Multi-channel notification.** Email / mobile / messaging delivery of alerts. | "Text me when it happens." | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | delivery infra; `[OPEN]` | ZW #15. |

---

## 11. Reporting

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-090 | **Report catalogue + viewer.** Templated reports with preview. | "Give me the monthly energy report." | SHOULD | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | 15 | DRAFT | report-definition storage; reads only via Phase 7 | |
| EMS-REQ-091 | **Familiar export formats.** PDF and Excel exports in customer-required formats. | "In the format finance expects." | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | 15 | BLOCKED | `OPEN #10` (which formats) | ZW #14. |
| EMS-REQ-092 | **Scheduled report generation & delivery.** Reports run unattended on a schedule. | "Send it automatically every month." | SHOULD | ROADMAP | 15 | DRAFT | existing job-scheduling conventions; delivery `[OPEN]` | |
| EMS-REQ-093 | **Report figures traceable to on-screen numbers.** A report figure matches what the customer sees (Phase 10 parity). | "Does the report match the dashboard?" | MUST (of reporting) | ROADMAP | 15 | DRAFT | Phase 10 parity | |

---

## 12. Cross-cutting experience

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-100 | **Shared time-range / resolution control.** One component; presets Today/7D/30D/3M/1Y + custom; resolution clamped to API support. | "Change the period once, everywhere." | MUST | PRODUCT_OWNER, ARCHITECTURE | 8 | READY-FOR-DESIGN | — | Measurements 3M/1Y unsupported by Phase 7 first slice — disabled with a reason. |
| EMS-REQ-101 | **One charting foundation.** A single chart library/component used consistently. | — | MUST | ARCHITECTURE | 8 | READY-FOR-DESIGN | — | No mixed chart libraries. |
| EMS-REQ-102 | **Role-appropriate views.** Different users see role-appropriate information & navigation. | "Show me what matters to my job." | MUST | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | 8–9 | PO-REVIEW | `OPEN #5` (which roles) | ZW #13 (role-based dashboards). Enforcement server-side. |
| EMS-REQ-103 | **Fast page loads.** Performance is a product requirement with budgets. | "Why is this slow?" (never) | MUST | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | 8, 16 | PO-REVIEW | budgets `[OPEN]` | ZW #19. First-paint usable; progressive fill. |
| EMS-REQ-104 | **Responsive to phone width.** Usable at ~400px; no horizontal body scroll. | "Check it on my phone." | MUST | PRODUCT_OWNER | 8 | READY-FOR-DESIGN | — | |
| EMS-REQ-105 | **Consistent empty/error states.** Distinct empty vs. no-data vs. error; never leak SQL/identifiers/stack traces. | "What do I do now?" | MUST | ARCHITECTURE | 8 | READY-FOR-DESIGN | EMS-REQ-071 | |
| EMS-REQ-106 | **Saved views / bookmarks.** Persist a customer's chosen context + range. | "Take me back to my usual view." | COULD | INFERENCE | 9+ | DRAFT | per-viewer storage; possibly a customer-write (PA-4) | Start with per-browser; server-side later. |
| EMS-REQ-107 | **Existing sensor/PLC reuse (product framing).** The product presents data from existing meters/sensors/PLC/SCADA without asking the customer to re-instrument. | "Do I need new hardware?" (no) | SHOULD | ZEROWATT_TECHNICAL_REFERENCE | — | READY-FOR-DESIGN | onboarding in the Administration App | ZW #2. A positioning/onboarding fact, mostly not a UI feature. |
| EMS-REQ-108 | **Modular expansion (product framing).** New sensors/parameters appear in the same analytical experience without a bespoke screen each. | "Will new sensors just show up?" | SHOULD | ZEROWATT_TECHNICAL_REFERENCE | 9+ | DRAFT | generic parameter handling; `generic_point_measurements` | ZW #3. |
| EMS-REQ-109 | **Context-aware system (product framing).** The product understands relationships between measurements, assets, spaces, systems, utilities. | "Why does this measurement matter?" | MUST | ZEROWATT_TECHNICAL_REFERENCE, ARCHITECTURE | 9+ | READY-FOR-DESIGN | asset/space relationships; parameter registry | ZW #21. This is the semantic model, exposed. |

---

## 13. IMPROVE / MEASURE — later intelligence

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-120 | **Insights surface.** Read `analytics.insights` (narrow, evidence-referencing event log). | "What has the system noticed?" | LATER | ROADMAP | 14 | DRAFT | detectors ship per-approval; detection logic outside schema | |
| EMS-REQ-121 | **Anomaly detection (customer-facing).** Surface anomalies with evidence. | "Anything abnormal?" | LATER | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | 14 | DRAFT | EMS-REQ-120 | **No AI/anomaly scoring before Phase 14.** |
| EMS-REQ-122 | **Recommendations / actionable intelligence.** Turn findings into suggested actions. | "What should I do?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | 14+ | DRAFT | EMS-REQ-120 | ZW #22. IMPROVE stage. |
| EMS-REQ-123 | **Best-practice comparison.** Compare performance against recognised best practices. | "How do we compare to best practice?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | 13–14 | DRAFT | a best-practice reference set (none today) | ZW #21 (built-in best practices). |
| EMS-REQ-124 | **Energy-saving opportunity identification.** Highlight quantified saving opportunities. | "Where can I save?" | LATER | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | 14+ | DRAFT | EMS-REQ-063, EMS-REQ-122 | |
| EMS-REQ-125 | **Did-the-action-work (MEASURE).** Before/after comparison around a recorded action. | "Did my change help?" | LATER | PRODUCT_OWNER | 13–15 | DRAFT | EMS-REQ-038, action log (none today) | The fourth journey stage. |
| EMS-REQ-126 | **Digital logbook.** Combine manual operational readings/notes with automatic telemetry. | "Record a manual meter read." | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | BLOCKED | PA-4 (customer-write mechanism) | ZW #4. |
| EMS-REQ-127 | **AI assistant / continuous AI insights.** Conversational / always-on AI analysis. | "Ask the system." | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | — | ZW #23/24. **Explicitly deferred. No AI now.** |
| EMS-REQ-128 | **Automatic GHG / carbon accounting.** Scope 1/2/3 emissions and sustainability reporting. | "What are our emissions?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | 14+ | DRAFT | emissions factors, tariffs/consumption; conditional on customer requirement | ZW #25. |

---

## 14. NOT IN SCOPE (customer EMS)

| ID | Title | Reason | Source |
|---|---|---|---|
| EMS-REQ-900 | Customer administration of organisations/sites/users/devices/config | Belongs to the Administration App; the customer EMS is not a redesign of it. | ARCHITECTURE, PRODUCT_OWNER |
| EMS-REQ-901 | Generic query builder / free-form metric explorer for customers | Non-goal; would require dynamic SQL and expose implementation structure. | ARCHITECTURE, PRODUCT_OWNER |
| EMS-REQ-902 | Customer access to Grafana as the EMS UI | Grafana is OPS/engineering; customer workflows migrate only via Phase 17 parity. | ARCHITECTURE |
| EMS-REQ-903 | Raw-tag / telemetry-name browser | Directly violates the "no raw-tag overload" principle and EMS-REQ-003. | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE |
| EMS-REQ-904 | Generalised billing engine | Out of scope; cost is rate × consumption/demand only (Phase 14, conditional). | ROADMAP |
| EMS-REQ-905 | New database entities invented to support a UI idea | Prohibited; frozen architecture change-control applies. | ARCHITECTURE |
| EMS-REQ-906 | AI/recommendation functionality ahead of Phase 14 | Explicitly deferred by the product brief and roadmap. | PRODUCT_OWNER, ROADMAP |
| EMS-REQ-907 | Cloning ZeroWatt's navigation, terminology, or dashboard layout | The product owner requires a distinct WiseWatts product. | PRODUCT_OWNER |
| EMS-REQ-908 | Modifying Phase 6 / energy pipelines / Grafana / the Phase 7 contract to enable a screen | Requires a separate explicit architecture decision, not a product requirement. | ARCHITECTURE |

---

## 15. Priority summary (draft — PO-REVIEW)

**MUST (near-term, Phases 8–10, + 12 for quality):** 001–008, 010–015, 020–024, 027, 030, 031, 034, 037, 040, 050, 051, 060, 070, 071, 074, 100–105, 109. (+ 041/022 as MUST/SHOULD depending on the demand-endpoint schedule.)

**SHOULD:** 016–019, 025, 026, 028, 032, 033, 035, 036, 038, 041–043, 052, 054, 061–064, 072, 073, 080, 081, 090–093, 102-perf items, 106–108.

**COULD:** 053, 065, 083, 106.

**LATER:** 044–049, 082, 084, 120–128.

**NOT-IN-SCOPE:** 900–908.

⚠️ **The ZeroWatt catalogue did not make every capability a MUST.** Of the 25 referenced capabilities, this draft classifies ~4 as MUST-adjacent (unified monitoring, high-res+aggregated, context-aware, role-based), ~9 as SHOULD, and ~12 as LATER.

---

## 16. ZeroWatt 25-capability cross-reference

`[ZEROWATT-OBSERVED]` — reference catalogue. **Classification is a WiseWatts draft decision, not acceptance.** ZeroWatt-specific implementation claims are **not** WiseWatts requirements without product-owner approval.

| # | ZeroWatt capability | WiseWatts requirement(s) | Draft priority | Note |
|---|---|---|---|---|
| 1 | Unified multi-parameter monitoring (aligned timelines) | EMS-REQ-037, 042, 074 | SHOULD/MUST | Core to Trends. |
| 2 | Existing sensor/PLC/SCADA reuse | EMS-REQ-107 | SHOULD | Positioning/onboarding, not a screen. |
| 3 | Modular expansion | EMS-REQ-053, 108 | SHOULD | Generic parameter handling. |
| 4 | Digital logbook (manual + telemetry) | EMS-REQ-126 | LATER | Customer-write (PA-4). |
| 5 | Seconds-level + aggregated logging | EMS-REQ-074 | MUST | Resolution ladder. |
| 6 | Live single-line / energy flow | EMS-REQ-049 | LATER | Real-time SLD. |
| 7 | Functional categories | EMS-REQ-018, 033 | SHOULD | BLOCKED on PA-2. |
| 8 | Exact tariff costing (ToD + demand charges) | EMS-REQ-044, 025 | SHOULD/LATER | BLOCKED on PA-3, `OPEN #7`. |
| 9 | Maximum-demand analysis (peaks, timing, equipment, contracted) | EMS-REQ-022, 032 | MUST/SHOULD | |
| 10 | Start-up detection | EMS-REQ-047 | LATER | |
| 11 | Custom process KPIs (energy/unit) | EMS-REQ-045 | LATER | Needs production data. |
| 12 | Automatic running hours | EMS-REQ-046 | LATER | |
| 13 | Self-configurable alerts | EMS-REQ-082 (+080 to view) | LATER/SHOULD | Config primarily in Administration App. |
| 14 | Familiar report formats (Excel/PDF) | EMS-REQ-091 | SHOULD | `OPEN #10`. |
| 15 | Multi-channel access (mobile/email/messaging) | EMS-REQ-084 | LATER | |
| 16 | High-resolution power analytics (V, I, PF, harmonics) | EMS-REQ-043 | SHOULD | |
| 17 | Role-based dashboards | EMS-REQ-102 | MUST | `OPEN #5`. |
| 18 | Shift-wise dashboards | EMS-REQ-048 | LATER | Needs shift model. |
| 19 | Fast page loads | EMS-REQ-103 | MUST | Product requirement, not afterthought. |
| 20 | Site and corporate views | EMS-REQ-010, 026 | MUST/SHOULD | Portfolio depth `OPEN #2`. |
| 21 | Context-aware system | EMS-REQ-013, 109, 016, 017 | MUST | This is the semantic model exposed. |
| 22 | Built-in best practices | EMS-REQ-123 | LATER | |
| 23 | Actionable intelligence | EMS-REQ-122, 124 | LATER | IMPROVE stage. |
| 24 | Continuous AI insights | EMS-REQ-127, 120 | LATER | **No AI before Phase 14.** |
| 25 | Automatic GHG accounting (Scope 1/2/3) | EMS-REQ-128 | LATER | Conditional on customer requirement. |

---

## 17. Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial catalogue: 90+ IDs across foundation, navigation, MONITOR, INVESTIGATE, energy, environment, assets, data-quality, alerts, reporting, cross-cutting, later-intelligence, NOT-IN-SCOPE; priority summary; ZeroWatt 25-capability cross-reference. All priorities are draft / PO-REVIEW. |
