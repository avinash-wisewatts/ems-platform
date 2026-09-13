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

## Alerts  *(SHOULD)*

- **Purpose:** surface conditions that need attention.
- **Primary:** active alerts list (severity, semantic subject, time raised, value vs. threshold).
- **Empty state (good):** "no active alerts" is a *good* empty state, distinct from no rules configured.
- **API dependency:** `MISSING` — no alert model/endpoint defined. Scope resolved (Workshop Q77/Q78 — basic, measurable-condition alerts, in-product + email delivery); shape/schema still `PLANNED (MVP-7)`.

## Reports  *(MVP-6)*

- **Purpose:** produce the documents customers must send to others.
- **Primary:** report catalogue (templates); a viewer/preview; export; the exact source metrics traceable to what the customer sees on screen (parity discipline).
- **MVP scope (Workshop Q76):** deliberately simple — no scheduling, no report builder, no automated narratives.
- **API dependency:** `PLANNED (MVP-6)` — report-definition storage + generation reading only through Phase 7.

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
