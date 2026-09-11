# WiseWatts EMS — Information Architecture / UX Blueprint

> **Status:** WORKING DRAFT  ·  **Version:** 0.1.1  ·  **Owner:** Product  ·  **Last updated:** 2026-09-11 (§6 status pointers only — see Version History; no product decision altered)
>
> **Source basis:** product-owner brief (§5–§8, §13, §16), `ems-product-definition.md`, DDS §F / §F.0 / §B.2–B.5 / §E, roadmap Phases 7–17, ZeroWatt technical overview (reference only).
>
> **This is a product-design hypothesis, not a UI specification.** Navigation, screen inventory and layouts stay a hypothesis until the product owner reviews them. Nothing here authorises implementation. All screens are `PRODUCT OWNER REVIEW REQUIRED`.

Labels: `[ZEROWATT-OBSERVED]` `[INFERRED]` `[WISEWATTS-DECISION]` `[ARCH-CONSTRAINT]` `[OPEN]` — see `ems-product-definition.md` §0.

---

## 1. Design intent

`[WISEWATTS-DECISION]` The IA serves the four-stage experience: **MONITOR → INVESTIGATE → (IMPROVE → MEASURE later)**. Two rules shape every screen:

1. **Every headline number offers a cheap next question.** A KPI is a door, not a dead end (drill-down to time / space / system / asset / measurement).
2. **Semantic context around every measurement** `[ZEROWATT-OBSERVED]` — `Site → Space → Parameter → Value`, never `device → logical point → raw field`.

`[OPEN]` The **first landing page** and **portfolio-first vs. site-first** are unresolved (PO questions 1 & 2). The IA below is written so either resolution works: a Portfolio Overview and a Site Overview both exist; routing between them is the open decision.

---

## 2. Navigation — working hypothesis

`[WISEWATTS-DECISION]` (draft) — mirrors the product-owner's proposed structure, adjusted so energy/environment/assets are reachable both **in site context** and **as cross-cutting areas**.

```text
CUSTOMER EMS
├── Overview                     ← portfolio/org level (multi-site); or redirect to Site Overview (single-site)
├── Sites
│   └── Site
│       ├── Overview
│       ├── Spaces  ──► Space detail
│       └── Assets  ──► Asset detail
├── Energy            (site-scoped by default; portfolio roll-up where supported)
│   ├── Consumption
│   ├── Demand
│   ├── Cost                     ← LATER (Phase 14); hidden until tariffs exist
│   ├── Breakdown
│   └── Power Quality            ← SHOULD (Phase 11/13 depending on scope)
├── Environment
│   ├── Temperature
│   ├── Humidity
│   └── Other Parameters
├── Assets
│   ├── Asset Overview
│   ├── Asset Performance        ← Phase 11
│   └── Asset Measurements
├── Analytics
│   ├── Trends
│   ├── Comparisons
│   └── Correlations             ← curated only, never a free-form query builder
├── Alerts                        ← SHOULD; appearance & config split [OPEN]
└── Reports                       ← Phase 15
```

**Future areas (record only; NOT approved Phase 9 features):**

```text
├── Insights                      (Phase 14 — analytics.insights event log)
├── Recommendations               (Phase 14+ — IMPROVE stage)
├── Sustainability / Carbon       (Phase 14+ — GHG accounting)
└── AI Assistant                  (LATER — no AI before its phase)
```

`[OPEN]` open navigation questions: landing page (#1); portfolio-first vs site-first (#2); is **Space** primary nav or drill-down only (#11); how a customer **selects among multiple sites** (#4); how **Alerts** appear (#6); how **functional categories** slot into nav (#12).

---

## 3. Cross-cutting UX (applies to every screen)

`[ARCH-CONSTRAINT] + [WISEWATTS-DECISION]`

| Element | Behaviour |
|---|---|
| **Context breadcrumb** | Always shows the semantic path: `Organisation ▸ Site ▸ Space/Asset ▸ Parameter`. Clickable to move up. Never shows IDs. |
| **Time-range control** | One shared component. Presets: Today, 7D, 30D, 3M, 1Y (+ custom). Emits `{from, to, resolution}`. Resolution is derived from range and **clamped to what the API supports** (Phase 7 first slice: `raw`, `1h` for measurements). Unsupported combinations are disabled with a reason, never a silent failure. |
| **Site / space / asset selector** | Scope-filtered to the user's access (server-side). Multi-site selection pattern is `[OPEN]` #4. |
| **Data-quality indicator** | The five states — `GOOD / GAP / ESTIMATED / INVALID / PARTIAL` — rendered consistently next to any value or series. `null` quality renders nothing. The product never invents a quality value the API didn't return. |
| **Loading state** | Skeleton/placeholder; never a blank screen or spinner-only. |
| **No-data state** | `[ARCH-CONSTRAINT]` "No data yet" is **normal**, not an error — used for newly-commissioned devices, uncommissioned tiers (e.g. `energy_consumption_5min` on some staging sites), or a range before the sensor existed. Explains *why* where possible ("this space has no environmental sensor", "collection started 3 days ago"). |
| **Empty state** | Distinct from no-data: the query is valid and the entity exists but has nothing to show for structural reasons (e.g. a site with zero spaces defined). Offers the next step (usually "contact your administrator" — configuration lives in the Administration App). |
| **Error state** | For genuine failures (401 → redirect to `/login`; 403 → "you don't have access to this"; 5xx → "something went wrong, retry"). Never leaks stack traces, SQL, table names, or identifiers. |
| **Performance** | `[ZEROWATT-OBSERVED]` Fast page loads are a requirement. Target budgets `[OPEN]`; initial view should be usable on first paint with progressive data fill. |
| **Responsive** | Works at phone width (~400px). Tables/charts scroll within their own container; page body never scrolls horizontally. |
| **Permission-awareness** | Nav items and drill-downs the user cannot access are hidden (UX only); the API still enforces. |

---

## 4. Screen catalogue

Each screen: **Purpose · Customer question · Primary information · Secondary information · Filters · Time context · Drill-down · Empty state · No-data state · Error state · Future considerations**. API dependency status: `LIVE` (Phase 7 first slice), `PLANNED (Phase N)`, `MISSING (needs architecture/API decision)`.

---

### 4.1 Portfolio / Organisation Overview

- **Purpose:** one-glance health of the whole portfolio for a multi-site customer.
- **Customer question:** "How is my organisation doing, and which sites need attention?"
- **Primary information:** per-site status tiles — energy vs. expected (▲/▼), current/peak demand vs. contracted, data-quality/connectivity health; a "sites needing attention" list.
- **Secondary information:** portfolio totals (energy this period), trend sparkline per site, last-updated timestamps.
- **Filters:** site group / region `[OPEN]`; metric shown on tiles (`[OPEN]` which KPI — PO Q3).
- **Time context:** a portfolio-level default period (This month? `[OPEN]`), with the shared time-range control.
- **Drill-down:** tile → that Site Overview.
- **Empty state:** organisation has only one site → **do not show this screen**; route straight to Site Overview `[INFERRED]` (PO Q2 `[OPEN]`).
- **No-data state:** a site with no telemetry yet → "collection not started" on its tile, not an error.
- **Error state:** partial load → show the sites that loaded, mark the rest "couldn't load, retry".
- **Future considerations:** benchmarking sites against each other / best practice (Phase 13); carbon roll-up (Phase 14+); saved portfolio views.
- **API dependency:** `MISSING` — cross-site aggregation surface not defined (gap PA-6). Near term this may be a thin client-side roll-up over per-site calls `[INFERRED]`, `[OPEN]`.

---

### 4.2 Sites (list)

- **Purpose:** choose a site to work in.
- **Customer question:** "Which of my sites do I want to look at?"
- **Primary information:** site name, location/timezone, a single health signal, last data timestamp.
- **Secondary information:** headline energy for the default period; number of spaces / assets.
- **Filters:** search by name; `[OPEN]` grouping.
- **Time context:** the health signal / headline uses the shared default period.
- **Drill-down:** row → Site Overview.
- **Empty state:** user has access to zero sites → "no sites assigned to your account; contact your administrator."
- **No-data state:** a site with no telemetry → listed, health signal shows "no data yet".
- **Error state:** list fails → full-screen retry.
- **Future considerations:** map view; favourites; column chooser.
- **API dependency:** `LIVE` — `GET /api/v1/sites` (name, code, org, timezone). Health signal & headline energy → `PLANNED (Phase 9/10)`.

---

### 4.3 Site Overview  ★ candidate landing page

- **Purpose:** the MONITOR home for a site — "how are we doing?" in one screen, with a path to "why".
- **Customer question:** "How is this facility doing right now / today / this period, compared to what I'd expect?"
- **Primary information:** `[OPEN]` PO Q3 — candidate set (choose ~5): (a) energy this period vs. expected/baseline; (b) current demand and peak demand vs. contracted; (c) cost-to-date vs. budget *(if cost built)*; (d) worst-performing space or system; (e) environmental status (spaces in/out of comfort band); (f) data-quality / connectivity health.
- **Secondary information:** trend sparklines for the headline metrics; a short "notable events" strip (e.g. "demand peak at 14:20"); links into Energy / Environment / Assets.
- **Filters:** none beyond the shared time-range; optionally "compare to previous period".
- **Time context:** default period `[OPEN]` (Today? This month?); shared control changes all headline metrics coherently.
- **Drill-down:** each KPI → its area screen focused on the same period (energy KPI → Energy Consumption; demand KPI → Demand; comfort KPI → Environment; "worst system" → that Asset).
- **Empty state:** site has no spaces/assets defined → show energy-only headline + "no spaces or assets configured yet".
- **No-data state:** site commissioned but no readings in range → "no data yet for this period"; offer the earliest period with data.
- **Error state:** headline metric fails individually → that card shows "couldn't load", the rest render.
- **Future considerations:** "How are we doing?" vs. a computed baseline (Phase 13); an Insights strip (Phase 14); role-specific overview variants (exec vs. engineer).
- **API dependency:** partially `LIVE` (`/sites`, energy consumption). Baseline/expected, demand, "worst system", comfort roll-up → `PLANNED (Phases 9–13)`.

---

### 4.4 Spaces (list)  ·  4.5 Space detail

**Spaces (list)**
- **Purpose:** navigate the site's rooms/areas.
- **Customer question:** "Which spaces exist, and which are outside comfort?"
- **Primary information:** space name (`Site ▸ Building ▸ Floor ▸ Space` context), current environmental snapshot (temperature, humidity, dew point), in/out of comfort band.
- **Secondary information:** assets serving the space (count); last reading time; quality.
- **Filters:** building/floor; "out of band only".
- **Time context:** snapshot = latest; a mini-trend uses the shared range.
- **Drill-down:** row → Space detail.
- **Empty state:** site has no spaces defined → "no spaces configured; ask your administrator".
- **No-data state:** space exists but has no environmental sensor bound → "no environmental data for this space" (explains it's a configuration/coverage fact, not an error).
- **Error state:** list fails → retry.
- **Future considerations:** occupancy/CO₂ when those parameters are wired; per-space energy attribution (with the explicit "shared AHU energy isn't auto-apportioned" caveat from DDS §F).
- **API dependency:** `MISSING` — a "spaces for a site" list endpoint is not in the first slice. `PLANNED (Phase 9)`.

**Space detail**
- **Purpose:** understand one space's environmental behaviour.
- **Customer question:** "What is the temperature/humidity/dew point in Banquet Hall 2, and how has it behaved?"
- **Primary information:** current values with quality; trend chart per parameter over the selected range; comfort band overlay where a target exists (`direction_of_good` / target metadata).
- **Secondary information:** assets serving the space (from `asset_space_relationships`, reverse direction); min/max/avg for the range.
- **Filters:** parameter (Temperature / Humidity / Dew Point / others as wired); resolution (clamped: `raw`, `1h`).
- **Time context:** shared control; `raw` for short ranges, `1h` for longer.
- **Drill-down:** a point on the trend → that timestamp's context; "assets serving this space" → Asset detail.
- **Empty state:** space has no bound sensors → the "no environmental data for this space" message + which assets serve it (still useful).
- **No-data state:** sensor bound but no readings in range → "no readings in this period".
- **Error state:** 404 (space not accessible / not found) → "this space isn't available to your account" (no existence leak); 5xx → retry.
- **Future considerations:** CO₂/occupancy; comfort scoring; correlate with the serving asset's operation.
- **API dependency:** `LIVE` — `GET /api/v1/spaces/{space_id}/measurements` (TEMPERATURE, HUMIDITY, DEW_POINT; DEW_POINT from Phase 6 persisted tier). "Assets serving this space", comfort targets → `PLANNED (Phase 9)`.

---

### 4.6 Assets (list)  ·  4.7 Asset Overview  ·  4.8 Asset Performance  ·  4.9 Asset Measurements

**Assets (list)**
- **Purpose:** navigate the site's equipment and systems.
- **Customer question:** "What equipment do I have, and is any of it a problem?"
- **Primary information:** asset name + type (`Chiller Plant`, `AHU`, `Motor`…), operating status, a health/performance signal, which space(s) it serves.
- **Secondary information:** parent/child (component tree) hint; energy contribution where known.
- **Filters:** asset type; functional category (`[OPEN]` #12); "problems only"; by served space.
- **Time context:** the health signal uses the shared range.
- **Drill-down:** row → Asset Overview.
- **Empty state:** no assets defined → "no assets configured; ask your administrator".
- **No-data state:** asset defined but no bound condition/energy points → "no measurements for this asset yet".
- **Error state:** retry.
- **Future considerations:** running hours, start counts (LATER); category roll-ups.
- **API dependency:** `MISSING` — "assets for a site" list not in first slice. `PLANNED (Phase 9)`.

**Asset Overview**
- **Purpose:** one asset's current picture and its place in the system.
- **Customer question:** "How is this chiller doing, and what's it connected to?"
- **Primary information:** operating status; key parameters (temperatures, power, runtime) with quality; the **component tree** (`asset_relationships`: "AHU-01 → Fan → Motor") and **spaces served** (`asset_space_relationships`).
- **Secondary information:** recent notable events; energy contribution; nameplate/context metadata (non-identifying).
- **Filters:** which parameters to show.
- **Time context:** "current" = latest; mini-trends use the shared range.
- **Drill-down:** a component → that Asset's Overview; a parameter → Asset Measurements; "serves Banquet Hall 2" → Space detail.
- **Empty state:** asset has no relationships and no points → minimal card + "not yet instrumented".
- **No-data state:** points bound, no readings in range → "no readings in this period".
- **Error state:** 404 → "not available to your account"; retry for 5xx.
- **Future considerations:** performance vs. baseline overlay (Phase 13); running hours; comparison to sibling assets of the same type.
- **API dependency:** `MISSING`/`PLANNED (Phase 9 for structure, Phase 11 for condition)`.

**Asset Performance**
- **Purpose:** condition-monitoring and efficiency for one asset.
- **Customer question:** "Is this equipment performing well, and is it degrading?"
- **Primary information:** condition parameters over time (vibration, temperatures, operating status), per-asset efficiency / derived parameters (e.g. COP), status vs. expected.
- **Secondary information:** operating envelope; comparison to same-type assets (fair because calculations are asset-type-scoped).
- **Filters:** parameter set; comparison peer set.
- **Time context:** shared range; longer ranges for degradation trends.
- **Drill-down:** to Asset Measurements; to the specific time window of an anomaly.
- **Empty state:** asset type not condition-monitored → "performance analytics not available for this asset type yet".
- **No-data state:** "no condition data in this period".
- **Error state:** retry.
- **Future considerations:** baseline overlays (Phase 13); start-up detection, running hours (LATER); recommendations (Phase 14+).
- **API dependency:** `PLANNED (Phase 11)` — depends on `asset_health` + derived-parameter tiers.

**Asset Measurements**
- **Purpose:** the honest, contextual list/trend of an asset's measurements — the bottom of the drill-down.
- **Customer question:** "Show me the actual readings behind this."
- **Primary information:** each parameter as a labelled series (friendly name + unit) with quality; value at a chosen time; min/max/avg.
- **Secondary information:** which point/space the value is attributed to (in **semantic** terms — "attributed to Motor A", "unattributed"), resolution, gaps.
- **Filters:** parameter; resolution (clamped); show/hide estimated.
- **Time context:** shared range.
- **Drill-down:** this **is** the leaf. A timestamp can pivot to Environment/Energy at the same time (curated correlation, §4.14).
- **Empty state:** no parameters bound → "no measurements defined for this asset".
- **No-data state:** "no readings in this period".
- **Error state:** retry; 404 handled with no existence leak.
- **Future considerations:** export (Phase 15); digital-logbook manual readings alongside telemetry (LATER).
- **API dependency:** partially `LIVE` shape (measurements series pattern exists for spaces); **asset**-scoped measurements → `PLANNED (Phase 9/11)`.

---

### 4.10 Energy — Consumption

- **Purpose:** the core MONITOR + INVESTIGATE surface for "how much energy, and is it normal?"
- **Customer question:** "Is today's / this month's consumption normal, and when did it deviate?"
- **Primary information:** consumption total for the range + comparison (previous period / expected); consumption trend at an appropriate resolution; contribution of top meter-roles/systems.
- **Secondary information:** min/max interval; period-over-period delta; data-quality coverage for the range.
- **Filters:** site; meter role / functional category (`[OPEN]` #12); resolution (tier ladder: 1min/5min/15min/hourly/daily as supported).
- **Time context:** shared control; resolution auto-selected per range, overridable within supported tiers.
- **Drill-down:** a spike → that time window; a system's slice → Breakdown; → Demand for the same window; → the contributing Asset.
- **Empty state:** site has no energy meters configured → "no energy metering configured for this site".
- **No-data state:** a tier not commissioned (e.g. `energy_consumption_5min` on some sites) → "5-minute data isn't available for this site; showing hourly" — degrade gracefully, don't error.
- **Error state:** retry; 422 for a bad range/resolution shown as a friendly "that combination isn't supported".
- **Future considerations:** cost overlay (Phase 14); baseline/expected band (Phase 13); shift-wise view (LATER); production-normalised KPI (kWh per unit — LATER).
- **API dependency:** `LIVE` — `GET /api/v1/sites/{site_id}/energy/consumption`. Comparison/expected, breakdown-by-role, functional categories → `PLANNED (Phase 10)` / `[OPEN]`.

---

### 4.11 Energy — Demand

- **Purpose:** understand demand, peaks, and their causes vs. contracted demand.
- **Customer question:** "Why did demand peak today, and what was running?"
- **Primary information:** demand trend over the range; **peak demand** with timestamp; contracted/agreed demand line; distance to the limit.
- **Secondary information:** contributing assets/systems at the peak (asset + time context); load-duration curve; number of near-limit events.
- **Filters:** site; period; "peaks above X".
- **Time context:** shared control; peaks highlighted; ability to zoom to a peak event.
- **Drill-down:** peak event → the minute-level window + which assets contributed → those Assets; → Consumption for the same window.
- **Empty state:** no demand data configured → "demand analysis isn't available for this site".
- **No-data state:** "no demand data in this period".
- **Error state:** retry.
- **Future considerations:** maximum-demand analysis with contributing-equipment attribution `[ZEROWATT-OBSERVED]`; demand-charge cost (Phase 14); start-up-driven peaks (LATER); alerts on approaching contracted demand.
- **API dependency:** `PLANNED (Phase 10)` — reads `demand_intervals` / `demand_state` via Phase 7.

---

### 4.12 Energy — Cost  *(LATER — Phase 14; hidden until tariffs exist)*

- **Purpose:** translate energy into money.
- **Customer question:** "What is this costing me, and where is the money going?"
- **Primary information:** cost for the range (rate × consumption, + demand charges); cost vs. budget/previous; cost breakdown by system/time-of-day.
- **Secondary information:** effective tariff; time-of-day rate bands; demand-charge component.
- **Filters:** site; tariff period; category.
- **Time context:** shared control; tariff-aware bucketing.
- **Drill-down:** a costly period → Consumption/Demand for it.
- **Empty state:** no tariff configured → "no tariff configured for this site; ask your administrator" (tariff config lives in the Administration App).
- **No-data state:** tariff exists, no consumption in range → "no cost to show for this period".
- **Error state:** retry.
- **Future considerations:** exact tariff costing incl. ToD + demand charges `[ZEROWATT-OBSERVED]`; tariff optimisation (LATER); cost allocation to spaces/cost-centres.
- **API dependency:** `MISSING` — `config.tariffs` / `analytics.cost_values` are conditional on a real customer requirement (gap PA-3). `[OPEN]` #7.

---

### 4.13 Energy — Breakdown

- **Purpose:** show *where* energy goes, in meaningful groups (not raw meters).
- **Customer question:** "What is consuming the energy — which systems, spaces, or categories?"
- **Primary information:** consumption split by functional category / system / meter role for the range (bar/treemap); each group's share and trend.
- **Secondary information:** period-over-period change per group; "unaccounted" residual made explicit.
- **Filters:** grouping dimension (category / system / space `[OPEN]`); range.
- **Time context:** shared control.
- **Drill-down:** a group → its assets → Asset detail; → Consumption filtered to that group.
- **Empty state:** no groups defined → "no functional categories or systems configured; showing site total only".
- **No-data state:** groups defined, no data in range → "no breakdown data for this period".
- **Error state:** retry.
- **Future considerations:** functional categories `[ZEROWATT-OBSERVED]` (definition `[OPEN]` #12, gap PA-2); per-space attribution with the shared-asset caveat; Sankey/energy-flow view (LATER — "live single-line").
- **API dependency:** `MISSING`/`PLANNED (Phase 10)` + blocked on the functional-category decision (PA-2).

---

### 4.14 Environment — Temperature / Humidity / Other Parameters

- **Purpose:** monitor and investigate comfort/environmental behaviour across the site's spaces.
- **Customer question:** "Which spaces are too hot/humid, and when?"
- **Primary information:** a per-space grid or map of the selected parameter's current value + in/out of band; a trend for a chosen space; site-wide summary (n spaces out of band).
- **Secondary information:** dew point (Phase 6 persisted); min/max/avg per space; quality.
- **Filters:** parameter (Temperature / Humidity / Dew Point / others as wired); building/floor; "out of band only"; resolution (`raw`, `1h`).
- **Time context:** shared control.
- **Drill-down:** a space → Space detail; a time → correlate with the serving asset's operation (curated).
- **Empty state:** site has no environmental sensors → "no environmental monitoring configured for this site".
- **No-data state:** some spaces have no sensor → those cells show "no sensor", not an error; others render.
- **Error state:** retry; per-space failures isolated.
- **Future considerations:** CO₂, occupancy, pressure when wired; comfort scoring; correlation with HVAC operation and with energy.
- **API dependency:** `LIVE` for per-space series (`/spaces/{id}/measurements`). Site-wide environmental summary / "spaces out of band" roll-up → `PLANNED (Phase 9/12)`.

---

### 4.15 Energy — Power Quality  *(SHOULD — scope [OPEN])*

- **Purpose:** high-resolution electrical parameters for engineering-minded customers.
- **Customer question:** "Is my supply healthy — voltage, current balance, power factor, harmonics?"
- **Primary information:** voltage/current per phase, power factor, THD/harmonics where available, at high resolution; out-of-tolerance highlighting.
- **Secondary information:** phase imbalance; events; correlation to demand peaks.
- **Filters:** meter/asset; parameter; phase (`L1/L2/L3/TOTAL` via `qualifier`, shown as friendly phase labels); range.
- **Time context:** shared control; high-resolution windows.
- **Drill-down:** an event → that window; → the affected asset.
- **Empty state:** meters don't report power-quality parameters → "power-quality data isn't available for this site".
- **No-data / Error:** standard.
- **Future considerations:** harmonic spectrum view; alerting on PF/imbalance; tie to equipment start-ups (LATER).
- **API dependency:** `PLANNED` (needs high-resolution electrical parameters exposed via the API; roadmap Phase 11/13 territory). `[ZEROWATT-OBSERVED]` capability #16.

---

### 4.16 Analytics — Trends

- **Purpose:** flexible-but-curated trending of semantic series.
- **Customer question:** "How has this metric moved over time?"
- **Primary information:** one or more **named** series (energy, a space's temperature, an asset parameter) on aligned timelines; period comparison overlay.
- **Secondary information:** min/max/avg, deltas, gaps, quality.
- **Filters:** series picker (from a **curated list of semantic metrics**, not a tag browser); range; resolution (clamped); comparison period.
- **Time context:** shared control; aligned timelines across series `[ZEROWATT-OBSERVED]` (capability #1).
- **Drill-down:** a region → the underlying measurements; → the area screen for that metric.
- **Empty state:** no series selected → prompt with suggested series for the current context.
- **No-data / Error:** per-series no-data shown inline; the chart still renders other series.
- **Future considerations:** saved trend views; annotations; shift/production overlays (LATER).
- **API dependency:** `PLANNED (Phase 9–10)`. **Constraint:** series come from a curated catalogue; **no free-form query builder, no dynamic SQL** (non-goal, gap PA-5).

---

### 4.17 Analytics — Comparisons

- **Purpose:** compare like with like — periods, sites, spaces, or same-type assets.
- **Customer question:** "Is this site/space/asset better or worse than [another / last period / expected]?"
- **Primary information:** side-by-side metric for the chosen comparands; % difference; ranking.
- **Secondary information:** normalisation basis (per m², per unit of production — LATER), fairness note (asset comparisons only within an `asset_type_id`).
- **Filters:** comparison dimension (period / site / space / asset-peer-set); metric; range.
- **Time context:** shared control; same range applied to all comparands.
- **Drill-down:** a comparand → its detail screen.
- **Empty state:** fewer than two valid comparands → "select at least two to compare".
- **No-data / Error:** a comparand with no data is shown as such, not dropped silently.
- **Future considerations:** benchmarking vs. best practice (Phase 13); portfolio league table.
- **API dependency:** `PLANNED (Phase 13)` (cross-asset comparison views), plus period/site comparison earlier.

---

### 4.18 Analytics — Correlations  *(curated only)*

- **Purpose:** show curated relationships, e.g. energy vs. outside temperature, HVAC power vs. space temperature.
- **Customer question:** "Does my energy track the weather / occupancy / production?"
- **Primary information:** two (or few) aligned series with a correlation summary; scatter with time colouring.
- **Secondary information:** lag, R² (labelled as descriptive, not predictive).
- **Filters:** from a **curated set of correlation pairs**, not arbitrary metric-vs-metric; range.
- **Time context:** shared control.
- **Drill-down:** a cluster → the time window → underlying measurements.
- **Empty state:** no curated pairs applicable to this context → hide the screen or show "not available for this site".
- **No-data / Error:** standard.
- **Future considerations:** more curated pairs; degree-day normalisation; automatic "what correlates with your energy" (Phase 14 — IMPROVE stage).
- **API dependency:** `MISSING`/`PLANNED` — curated correlation series. **Constraint:** curated, never free-form (gap PA-5).

---

### 4.19 Alerts  *(SHOULD — appearance & config split [OPEN] #6)*

- **Purpose:** surface conditions that need attention.
- **Customer question:** "What's wrong right now, and what was wrong recently?"
- **Primary information:** active alerts list (severity, subject in semantic terms — "Banquet Hall 2 temperature high", "Chiller Plant approaching contracted demand"), time raised, current value vs. threshold.
- **Secondary information:** history / acknowledged; trend for the alerting metric; link to the relevant screen.
- **Filters:** severity; subject (site/space/asset/energy); status (active/acknowledged/cleared).
- **Time context:** active = now; history uses the shared range.
- **Drill-down:** alert → the metric's screen at the relevant time.
- **Empty state:** no alert rules configured → "no alerts configured; alert rules are set up by your administrator" `[INFERRED]`.
- **No-data state:** rules configured, nothing firing → "no active alerts" (a *good* empty state).
- **Error state:** retry.
- **Future considerations:** self-configurable alert rules `[ZEROWATT-OBSERVED]` (config primarily in the Administration App; gap PA-4); multi-channel delivery — email/mobile/messaging (LATER); alert on approaching contracted demand; start-up-anomaly alerts (LATER).
- **API dependency:** `MISSING` — no alert model/endpoint defined. `[OPEN]` #6. Likely relates to `analytics.insights` (Phase 14) but alerts ≠ insights conceptually `[INFERRED]`.

---

### 4.20 Reports  *(Phase 15)*

- **Purpose:** produce the documents customers must send to others.
- **Customer question:** "Give me the monthly energy report in the format my finance/ESG team expects."
- **Primary information:** report catalogue (templates); a viewer/preview; export (PDF/Excel `[ZEROWATT-OBSERVED]`); schedule management.
- **Secondary information:** last generated; recipients (delivery `[OPEN]`); the exact source metrics used (traceable to what the customer sees on screen — Phase 10 parity).
- **Filters:** template; period; site/portfolio scope.
- **Time context:** report period selection.
- **Drill-down:** a figure in a report → the screen it came from.
- **Empty state:** no templates available → "no report templates configured yet".
- **No-data state:** period has no data → the report generates with explicit "no data" sections, not a failure.
- **Error state:** generation failure → clear message + retry; never a partial silent export.
- **Future considerations:** customer-required Excel/PDF formats `[ZEROWATT-OBSERVED]`; scheduled delivery; branded templates; regulatory/ESG report packs (Phase 14+).
- **API dependency:** `PLANNED (Phase 15)` — report-definition storage + scheduled generation reading **only** through Phase 7.

---

### 4.21 Future areas (record only — NOT Phase 9 features)

| Area | Customer question | Stage | Phase | Notes |
|---|---|---|---|---|
| **Insights** | "What has the system noticed?" | INVESTIGATE→IMPROVE | 14 | Reads `analytics.insights` (narrow evidence-referencing event log). Detection logic lives in app/analytics code, never schema. Each detector ships behind its own approval. |
| **Recommendations** | "What should I do about it?" | IMPROVE | 14+ | Turns findings into suggested actions `[ZEROWATT-OBSERVED]` (#22). No implementation before its phase. |
| **Sustainability / Carbon** | "What are our Scope 1/2/3 emissions?" | IMPROVE/MEASURE | 14+ | Automatic GHG accounting `[ZEROWATT-OBSERVED]` (#25). Conditional on customer requirement. |
| **AI Assistant** | "Ask the system a question" | LATER | — | `[ZEROWATT-OBSERVED]` (#24, "continuous AI insights"). **No AI before its phase.** Explicitly deferred. |
| **Digital Logbook** | "Record a manual reading / note" | LATER | — | `[ZEROWATT-OBSERVED]` (#4). Introduces customer **writes** — needs an audited mechanism (gap PA-4). |
| **Live Single-Line / Energy Flow** | "Show power flowing through my site" | LATER | — | `[ZEROWATT-OBSERVED]` (#6). Real-time SLD; significant, deferred. |
| **Shift Dashboards** | "How did the night shift do?" | LATER | — | `[ZEROWATT-OBSERVED]` (#18). Needs a shift-context model — none exists; `[OPEN]`. |

---

## 5. Screen → journey-stage map

| Stage | Screens |
|---|---|
| **MONITOR** | Portfolio Overview, Sites, Site Overview, Spaces list, Assets list, Environment (grid), Energy Consumption (headline), Demand (headline), Alerts (active) |
| **INVESTIGATE** | Site Overview drill-downs, Space detail, Asset Overview / Performance / Measurements, Energy Consumption (trend/spike), Demand (peak event), Breakdown, Power Quality, Analytics (Trends / Comparisons / Correlations), Alerts (history) |
| **IMPROVE** *(later)* | Insights, Recommendations, benchmarking, Sustainability |
| **MEASURE** *(later)* | Comparisons before/after an action, Reports, baseline re-fit |

---

## 6. Open IA decisions

> **IMPLEMENTATION STATUS UPDATE (2026-09-11):** most of the items below are now resolved by the Product Owner Workshop (Q49–Q101). See `ems-product-definition.md` §12/§13 for the pointer-level detail; only genuinely open items remain unmarked here.

- ~~Landing page after login (#1); portfolio-first vs. site-first (#2).~~ **Resolved:** Q61, Q62, Q88.
- ~~The five headline metrics on Site Overview (#3).~~ **Resolved:** Q70, Q71.
- Multi-site selection pattern (#4) — still an interaction-design detail, not resolved.
- ~~Space as primary nav vs. drill-down (#11).~~ **Resolved:** Q51, Q99 — drill-down.
- ~~How Alerts appear and where they're configured (#6).~~ **Resolved:** Q77, Q78, Q67.
- Functional-category definition and how it drives Breakdown/navigation (#12, gap PA-2) — **still genuinely open**; not addressed by Q49–Q101.
- ~~Which cost capabilities are in scope, if any (#7, gap PA-3).~~ **Resolved at the scope level:** Q73 — in scope wherever accurate/sufficiently configured. The remaining gap is a verified data dependency (no tariff schema exists), not an open scope question — see `ems-requirements-traceability.md` §4.
- ~~How much asset detail customers see (#9).~~ **Resolved:** Q100.
- Required report formats (#10) — partially resolved (Q76 gives the general shape; specific formats undecided).
- Default time period per screen family — still open.
- Performance budgets (first-paint / interaction) — still open (Q92 sets no concrete budget).

---

## 7. Version history

| Version | Date | Change |
|---|---|---|
| 0.1 | 2026-09-10 | Initial working draft. Navigation hypothesis, cross-cutting UX, ~21 screen breakdowns with 12-field template + API-dependency status, journey-stage map, open IA decisions. |
| 0.1.1 | 2026-09-11 | **IMPLEMENTATION STATUS UPDATE.** §6 open-decision items marked resolved/still-open against `ems-product-owner-workshop-baseline.md` Q49–Q101. No screen definition or IA decision was altered. |
