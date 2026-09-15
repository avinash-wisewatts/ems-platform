# Information Architecture — Screen Catalogue

Status: CURRENT (working hypothesis) · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-information-architecture.md` v0.1.1 §4 (archived), consolidated here.

Each screen: **Purpose · Customer question · Primary/secondary information ·
Filters · Time context · Drill-down · Empty/no-data/error states · Future
considerations · API dependency**. API status: `LIVE` (Phase 7 first slice),
`PLANNED (MVP-n)`, or `MISSING` (needs an architecture/API decision). See
[interaction-patterns.md](interaction-patterns.md) for the rules common to
every screen (breadcrumb, time-range, quality indicator, states) — not
repeated below.

## Portfolio / Organisation Overview

- **Purpose:** one-glance health of the whole portfolio for a multi-site customer.
- **Customer question:** "How is my organisation doing, and which sites need attention?"
- **Primary:** per-site status tiles (energy vs. expected, current/peak demand vs. contracted, data-quality/connectivity health); a "sites needing attention" list.
- **Secondary:** portfolio totals for the period, trend sparkline per site, last-updated timestamps.
- **Drill-down:** tile → that Site Overview.
- **Empty state:** organisation has only one site → route straight to Site Overview instead of showing this screen (Workshop Q62).
- **API dependency:** `MISSING` — cross-site aggregation surface not defined (gap PA-2/PA-6). MVP-8, lowest MVP priority (Workshop Q63/Q64).

## Sites (list)

- **Purpose:** choose a site to work in.
- **Primary:** site name, location/timezone, a single health signal, last data timestamp; headline energy for the default period.
- **Drill-down:** row → Site Overview.
- **API dependency:** `LIVE` — `GET /api/v1/sites`. Health signal/headline energy → `PLANNED (MVP-1/2)`.

## Site Overview  ★ MVP landing page

See [ADR-003](../00-governance/decisions/ADR-003-mvp-information-model.md)
and [ADR-004](../00-governance/decisions/ADR-004-site-overview-primary-destination.md).

- **Purpose:** the MONITOR home for a site — "how are we doing?" with a path to "why."
- **Primary (decided, Workshop Q70):** Overall Site Health/Status → Attention/Exceptions → Energy Performance vs. baseline → Maximum Demand vs. contracted → Power Quality → investigation paths into Space/Asset.
- **Secondary:** trend sparklines for headline metrics; a short "notable events" strip; links into Energy/Environment/Assets.
- **Site states (Workshop Q79/Q80):** Healthy · Needs Attention · Insufficient Data — see [ADR-011](../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md).
- **Drill-down:** each KPI → its area screen focused on the same period.
- **API dependency:** partially `LIVE` (`/sites`, energy consumption). Baseline/expected, demand, comfort roll-up, Attention → `PLANNED (MVP-2/3)`.

## Spaces (list) · Space detail

**Spaces (list)** — navigate the site's rooms/areas.
- **Primary:** space name in `Site ▸ Building ▸ Floor ▸ Space` context; current environmental snapshot; in/out of comfort band.
- **API dependency:** `MISSING` — a "spaces for a site" list endpoint is not in the first slice. `PLANNED (MVP-1)`.

**Space detail** — one space's environmental behaviour.
- **Primary:** current values with quality; trend chart per parameter; comfort band overlay where a target exists.
- **API dependency:** `LIVE` — `GET /api/v1/spaces/{space_id}/measurements` (TEMPERATURE, HUMIDITY, DEW_POINT). "Assets serving this space," comfort targets → `PLANNED (MVP-1)`.

## Assets (list) · Asset Overview · Asset Performance · Asset Measurements

**Assets (list)** — navigate the site's equipment.
- **Primary:** asset name + type, operating status, a health/performance signal, which space(s) it serves.
- **API dependency:** `MISSING` — "assets for a site" list not in first slice. `PLANNED (MVP-1)`.

**Asset Overview** — one asset's current picture and its place in the system.
- **Primary:** operating status; key parameters with quality; component tree and spaces served (deferred UI — see [ADR-013](../00-governance/decisions/ADR-013-deferred-asset-component-tree.md)).
- **API dependency:** `MISSING`/`PLANNED (MVP-1 for structure)`.

**Asset Performance** — condition-monitoring and efficiency for one asset.
- **Purpose:** "Is this equipment performing well, and is it degrading?"
- **API dependency:** `PLANNED (Post-MVP)` — depends on `asset_health` + derived-parameter tiers (DDS Phase 11).

**Asset Measurements** — the honest, contextual list/trend of an asset's measurements.
- **Primary:** each parameter as a labelled series with quality; attribution in semantic terms ("attributed to Motor A," "unattributed").
- **API dependency:** partially `LIVE` shape (measurements pattern exists for spaces); asset-scoped measurements → `PLANNED (MVP-1/Post-MVP)`.

## Energy — Consumption

- **Purpose:** the core MONITOR + INVESTIGATE surface for "how much energy, and is it normal?"
- **Primary:** consumption total + comparison (previous period/expected); trend at appropriate resolution; contribution of top meter-roles/systems.
- **No-data state:** a tier not commissioned (e.g. `energy_consumption_5min`) → degrade gracefully to hourly with a note, never error.
- **API dependency:** `LIVE` — `GET /api/v1/sites/{site_id}/energy/consumption`. Comparison/expected, breakdown-by-role, functional categories → `PLANNED (MVP-2)`/`MISSING (PA-2)`.

## Energy — Demand

- **Purpose:** understand demand, peaks, and their causes vs. contracted demand.
- **Primary:** demand trend; **peak demand** with timestamp; contracted/agreed demand line; distance to the limit.
- **API dependency:** `PLANNED (MVP-2)` — reads `demand_intervals`/`demand_state` via Phase 7; underlying analytics already `LIVE`.

## Energy — Cost  *(deferred — hidden until tariffs exist)*

- **Purpose:** translate energy into money.
- **Empty state:** no tariff configured → "no tariff configured for this site; ask your administrator" (tariff config lives in the Administration App).
- **API dependency:** `MISSING` — `config.tariffs`/`analytics.cost_values` conditional on a real customer requirement (gap PA-3; verified: no such table exists anywhere in the schema).

## Energy — Breakdown

- **Purpose:** show *where* energy goes, in meaningful groups (not raw meters).
- **API dependency:** `MISSING`/`PLANNED (MVP-2/Post-MVP)` — blocked on the functional-category decision (PA-2, still genuinely open).

## Environment — Temperature / Humidity / Other Parameters

- **Purpose:** monitor and investigate comfort/environmental behaviour across the site's spaces.
- **Primary:** a per-space grid/map of the selected parameter's current value + in/out of band; site-wide summary (n spaces out of band).
- **API dependency:** `LIVE` for per-space series (`/spaces/{id}/measurements`). Site-wide roll-up → `PLANNED (MVP-1/3)`.

## Energy — Power Quality  *(SHOULD — scope open)*

- **Purpose:** high-resolution electrical parameters.
- **Primary:** voltage/current per phase, power factor, THD/harmonics where available; out-of-tolerance highlighting.
- **API dependency:** `PLANNED (MVP-2)` — needs high-resolution electrical parameters exposed via the API; underlying telemetry already `LIVE`.

## Analytics — Trends · Comparisons · Correlations  *(curated only)*

- **Trends:** one or more **named** semantic series on aligned timelines; series come from a curated catalogue — never a free-form query builder. `PLANNED (MVP-2)`.
- **Comparisons:** periods, sites, spaces, or same-type assets — fairness rule: asset comparisons only within one `asset_type_id`. `PLANNED (Post-MVP)`.
- **Correlations:** curated pairs only (e.g. energy vs. outside temperature) — never arbitrary metric-vs-metric. `MISSING`/`PLANNED (Post-MVP)`.

## Alerts  *(SHOULD — MVP-7, implemented 2026-09-14, staging validation pending)*

- **Purpose:** notify the customer of existing, already-computed Attention
  conditions — not a new detection mechanism. Every qualifying Attention
  condition auto-generates an alert per affected context; there is no
  customer-facing alert-rule-authoring layer.
- **Delivery — in-product only.** A header notification indicator (count of
  currently Active alerts, scoped to the selected Site/context) and a
  dedicated Alerts area in main navigation. **No email, SMS, WhatsApp, or
  sharing** — this corrects the archived Workshop Q78 statement that email
  was included; see
  [ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md)
  "Source-of-truth correction."
- **Lifecycle:** a condition must be continuously true for 5 minutes
  (gap-resetting) before an alert qualifies. Active while the condition
  remains true; Resolved after 1 minute continuously false (gap-resetting)
  — the condition actually cleared. Ended covers two distinct causes
  (Ended is never presented as Resolved, for either): the underlying
  Attention configuration is disabled or changed while Active (creates a
  new alert identity, requires fresh qualification), or — added
  2026-09-15 — an Active alert recovers from a data-unavailable gap while
  the condition is still true (see below).
- **Data-unavailable-while-Active:** the alert stays Active
  ("Unable to evaluate — data unavailable" / "Latest value: Data
  unavailable"); on recovery, a no-longer-true condition follows the
  normal Resolved path unchanged; a still-true condition **Ends** the
  prior alert (a distinct, controlled reason from the configuration-change
  cause above — not free text) and requires fresh 5-minute qualification
  before a new alert is generated — the prior alert is not silently
  continued. **Status: implemented and locally tested (migration 242,
  2026-09-15) — static contract, live-execution disposable-database, and
  API/frontend tests all pass; not yet deployed to staging/production, not
  yet observed against real data.**
- **Content:** existing EMS terminology, thresholds, and number formatting
  only — no alert-specific vocabulary and no new severity taxonomy. List
  shows condition + context + triggered time; detail adds hierarchy
  context, current state, trigger/latest/resolution values,
  threshold/reference, and a recurrence summary ("Previous occurrences: N"
  / "Most recent: <time>"); Ended alerts add ended time + reason. No
  analytical deep links to other screens in MVP-7, and no internal
  identifiers (device/point IDs) are ever exposed.
- **History and retention:** historical records are immutable. Resolved and
  Ended alerts remain visible for 90 days from resolution/ending; Active
  alerts remain visible indefinitely while true.
- **Filtering/ordering:** cascading Site→Space→Asset filters, a
  single-select Condition/Metric filter, status-appropriate date filtering
  (90-day defaults), infinite scroll. Ordered by existing Attention
  materiality, then recency — materiality is used for ordering only, never
  shown as a customer-facing severity label.
- **Empty state (good):** "no active alerts" is a *good* empty state,
  distinct from no conditions configured.
- **Authorization:** follows existing EMS authorization; no alert-specific
  recipient/permission model. Configuration remains exclusively in the
  Administration App (Q67).
- **Full decision record:**
  [ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md);
  requirements:
  [functional-requirements.md §Alerts](../02-requirements/functional-requirements.md#alerts)
  (`EMS-REQ-080`–`084`, `EMS-REQ-117`–`127`).
- **API dependency:** `LIVE` — `GET /api/v1/sites/{site_id}/alerts`, `GET
  /api/v1/alerts/{alert_id}` (migration 239). Architecture (ADR-017):
  evaluation via a TimescaleDB-native background job; `Alert` is the DDS's
  11th core concept. Implemented 2026-09-14, staging validation pending —
  see [docs/07-features/alerts/README.md](../07-features/alerts/README.md).

## Export  *(MVP-6 — decided 2026-09-14, amended 2026-09-15; Energy contextual export implemented and corrected 2026-09-15, not yet deployed; dedicated Export area and Demand/Power Quality remain not implemented)*

- **Purpose:** provide the underlying data behind an on-screen figure, for use outside WiseWatts — distinct from Reports below (Workshop Q76: "Report = communicate the important story; Export = provide the underlying data").
- **Content:** the aggregated analytical figure(s) already shown on screen (e.g. a period's total consumption, peak demand, PF/THD summary) — not genuinely raw/sub-interval time-series measurements. **For Energy's contextual export specifically (2026-09-15 amendment — see [ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md#amendment-2026-09-15--decision-1-narrowed-energy-chart-series-now-in-scope)), this includes the Energy Trend chart's own already-displayed, already-aggregated per-bucket series — export is one row per chart point, not a single summary figure.** This clarification is Energy-specific; Demand/Power Quality export remains unimplemented and undecided at this level of detail.
- **Context fields:** Site/hierarchy context, selected time range, comparison/baseline basis (mirroring exactly what's displayed on screen, including any shown difference), metric name and unit, and data-quality/freshness information where relevant to interpreting the figure.
- **Format:** CSV.
- **Delivery:** immediate download for smaller exports; background generation for larger exports. No specific size threshold between the two is decided.
- **Availability:** contextually, from the relevant analytical screen (Energy, Demand, Power Quality, etc.), scoped to whatever hierarchy level (Site/Space/Asset) is currently being viewed; and through a dedicated Export area, which additionally supports multi-metric export across Energy, Demand, and Power Quality together and lets the customer select the desired hierarchy level directly.
- **Time range:** selectable range is bounded by the specific site's actual minimum/maximum data-available dates.
- **Data completeness:** gaps within the selected range retain their applicable data-quality/freshness state rather than being silently omitted; a selected metric with no usable data is still represented, with its applicable data-quality state and no fabricated value.
- **Full decision record:** [ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md); requirements: [functional-requirements.md §Export](../02-requirements/functional-requirements.md#export) (`EMS-REQ-094`–`EMS-REQ-099`).
- **API dependency:** `PLANNED (MVP-6)` — no endpoint exists; Increment 1's CSV is built entirely client-side from data the existing Energy endpoints already return (mirrors the Site Performance Report's client-side-generation precedent), so this remains unbuilt regardless of Increment 1.
- **Implementation note (2026-09-15):** an "Export CSV" action exists on the Energy screen only (`web/src/routes/energy/EnergyOverview.tsx`), immediate client-side download, single hierarchy level (whatever the screen is currently scoped to), no size tiering. It was first implemented as a single period-summary row (see [requirements-traceability.md §11](../02-requirements/requirements-traceability.md#11-status-update-2026-09-15--q75-increment-1-energy-contextual-csv-export-implemented-not-deployed)) and **corrected the same day** to export one row per Energy Trend chart point instead (see [§12](../02-requirements/requirements-traceability.md#12-status-update-2026-09-15--q75-energy-chart-data-export-decided-correcting-increment-1)) — the single-row description is superseded. Demand, Power Quality, and the dedicated multi-metric Export area described above remain entirely unimplemented.

## Reports  *(MVP-6 — one report type decided and implemented 2026-09-14, not yet deployed)*

- **Purpose:** produce the documents customers must send to others.
- **Primary:** report catalogue (templates); a viewer/preview; the exact source metrics traceable to what the customer sees on screen (parity discipline).
- **MVP scope (Workshop Q76):** deliberately simple — no scheduling, no report builder, no automated narratives.
- **API dependency:** `PLANNED (MVP-6)` — no new API; the decided report type composes existing, already-live endpoints (see below), not a new report-generation backend.
- **Status (2026-09-14):** one report type is decided and being implemented — the **Site Performance Report**. See `EMS-REQ-090`–`EMS-REQ-093` and `EMS-REQ-110`–`EMS-REQ-116` (`READY-FOR-DESIGN`), and
  [ADR-015](../00-governance/decisions/ADR-015-q76-site-performance-report.md).
  The rest of Q76 (Excel format, any additional report type, a general
  report-definition storage mechanism) remains undecided.

### Site Performance Report  *(the one decided and implemented MVP-6 report type, not yet deployed)*

- **Access:** Reports area only — not reachable contextually from other screens (unlike Export).
- **Configuration:** hierarchy context (Site/Space/Asset) + reporting period (current-calendar Weekly/Monthly/Quarterly/Yearly, or Custom — no data-availability bound enforced; see ADR-015 gap resolution 2).
- **Generation:** in-app, on demand. Title: "Performance Report — [context name]".
- **Structure**, reusing `SiteOverview.tsx`'s own Q70 order (ADR-003/ADR-004) and data — **not a new computation path**: Overall Site Health/Status → Attention/Exceptions → Energy Performance → Maximum Demand → Power Quality → Investigation paths. Existing metrics/comparisons/deterministic rules only; no new analytics, thresholds, or AI/LLM narrative reasoning; per-domain `Data unavailable` preserved; no new overall report status beyond the existing three-state Site Health signal.
- **Hierarchy scope caveat:** selecting a Space or Asset changes the title and the Investigation-section target only — report content is always the selected Site's own data, because no Space/Asset-scoped equivalent of Energy/Demand/PQ/Attention/Health exists anywhere in the platform (ADR-015 gap resolution 1 — a genuine capability gap, not a design choice).
- **Site Health/Attention availability caveat:** these two lead sections require the Slice C typical-reference endpoint's exact whole-day window (1/7/30/90/365 days, enforced server-side); a current-calendar to-date period essentially never satisfies this, so Site Health and Attention legitimately read "unavailable" for most generated reports. Energy's own current value and a Previous-Period comparison remain available regardless (ADR-015 gap resolution 6 — a genuine platform limitation, verified at the backend source of truth, not a defect).
- **PDF:** optional, generated client-side from the rendered in-app report; same content, PDF-specific layout. No server-side report-generation job exists or is introduced — see ADR-015 gap resolutions 4-5 for the explicit "immediate where practical" interpretation.
- **Not included:** report history, email delivery, share links, scheduling.
- **Extensibility:** this structure is the implemented baseline for a later UX/design refinement, not frozen — see ADR-015 Consequences.

> **Contradiction resolved (2026-09-14)** — this section's "Primary"
> bullet, per [source-of-truth.md](../00-governance/source-of-truth.md)'s
> recording format:
>
> **CURRENT IMPLEMENTATION:** the "Primary" bullet above lists report
> catalogue, viewer/preview, and on-screen-parity traceability only. Export
> of underlying data is documented separately, in the "Export" section
> above this one.
>
> **HISTORICAL / DOCUMENTED EXPECTATION:** this bullet previously read
> "report catalogue (templates); a viewer/preview; export; the exact
> source metrics traceable..." — bundling "export" into Reports' own
> primary content, with no separate Export section existing anywhere in
> this document at that time.
>
> **CHANGE:** the MVP-6 Product Decision Workshop (2026-09-14) resolved
> Export (Q75) as its own, fully specified capability — see the "Export"
> section above and [ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md).
> Per Q76's own text, *"Report = communicate the important story; Export =
> provide the underlying data,"* the two were always meant to be distinct;
> this document simply hadn't reflected that split before Export had its
> own decision record to document. The word "export" was removed from this
> bullet accordingly — no other change was made to Reports' content or
> status.
>
> **VERIFICATION:** confirmed by re-reading Workshop baseline §108
> (`docs/99-archive/superseded-product/ems-product-owner-workshop-baseline.md`)
> for the Report-vs-Export distinction, and by confirming Reports' own
> decided scope (catalogue, viewer/preview, parity) makes no independent
> claim about export behavior beyond that one now-removed word.

## Future areas (record only — not MVP features)

| Area | Customer question | Stage | Notes |
|---|---|---|---|
| **Insights** | "What has the system noticed?" | INVESTIGATE→IMPROVE | Reads `analytics.insights`; each detector ships behind its own approval — see [ADR-012](../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md). |
| **Recommendations** | "What should I do about it?" | IMPROVE | No implementation before its phase. |
| **Sustainability / Carbon** | "What are our emissions?" | IMPROVE/MEASURE | Conditional on customer requirement. |
| **AI Assistant** | "Ask the system a question" | Deferred | **No AI before its phase.** |
| **Digital Logbook** | "Record a manual reading" | Deferred | Needs a customer-write mechanism (gap PA-4). |
| **Live Single-Line / Energy Flow** | "Show power flowing through my site" | Deferred | Real-time single-line diagram; significant, deferred. |
| **Shift Dashboards** | "How did the night shift do?" | Deferred | Needs a shift-context model — none exists. |
