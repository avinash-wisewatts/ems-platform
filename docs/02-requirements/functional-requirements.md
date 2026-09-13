# Functional Requirements Catalogue

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-customer-requirements.md` v0.1 (archived), consolidated here.

> This is an initial catalogue. Priorities are a starting hypothesis. Items
> marked `PO-REVIEW` need product-owner confirmation. See
> [requirements-traceability.md](requirements-traceability.md) for the
> live-verified, MVP-authoritative status of every requirement below —
> several `PLANNED (Phase N)` references here predate the roadmap's v0.2
> re-sequencing into MVP-1..MVP-8 (see [../01-product/roadmap.md](../01-product/roadmap.md)).

See [README.md](README.md) for conventions (`Priority`, `Status`, `Source`).

## Foundation & platform boundary

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-001 | **Separate customer application.** Distinct from the Administration App. | — (product principle) | MUST | PRODUCT_OWNER, ARCHITECTURE | 8 | READY-FOR-DESIGN | PR #44 | See [ADR-006](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md). |
| EMS-REQ-002 | **Analytics-API-only data access.** Never DB / TimescaleDB / Grafana / internal objects. | — | MUST | ARCHITECTURE | 7–8 | READY-FOR-DESIGN | Phase 7 | See [ADR-007](../00-governance/decisions/ADR-007-analytics-api-boundary.md). |
| EMS-REQ-003 | **No implementation identifiers exposed.** No device IDs, logical-point IDs, raw field names, table/column/SQL. | "What am I looking at?" | MUST | PRODUCT_OWNER, ARCHITECTURE | 8+ | READY-FOR-DESIGN | EMS-REQ-002 | Deep-link URLs may use opaque semantic IDs already surfaced by the API. |
| EMS-REQ-004 | **Shared authentication.** Reuse the existing signed session; no parallel auth system. | "Log me in once." | MUST | ARCHITECTURE | 8 | READY-FOR-DESIGN | — | Same-origin delivery so the cookie flows to `/api/v1`. |
| EMS-REQ-005 | **Server-side authorisation is authoritative.** Frontend checks gate UX only. | "Only show me what I'm allowed to see." | MUST | ARCHITECTURE | 7–8 | READY-FOR-DESIGN | — | 404-no-leak for inaccessible resources. |
| EMS-REQ-006 | **Independently deployable & rollbackable.** Without changing the Administration App, Grafana, DB, or energy. | — | MUST | PRODUCT_OWNER, ARCHITECTURE | 8 | READY-FOR-DESIGN | — | `/app` is a routing detail. |
| EMS-REQ-007 | **Grafana stays OPS/engineering.** Migrates only via Phase 17 per-workflow parity. | — | MUST | ARCHITECTURE, ROADMAP | 10–17 | READY-FOR-DESIGN | Phase 10 parity, Phase 17 | See [ADR-008](../00-governance/decisions/ADR-008-grafana-ops-role.md). |
| EMS-REQ-008 | **No Phase 7 contract change without an explicit architecture decision.** | — | MUST | ARCHITECTURE | 7+ | READY-FOR-DESIGN | — | |

## Navigation & context

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-010 | **Organisation / portfolio context.** Top of navigation. | "Which of my facilities?" | MUST | PRODUCT_OWNER, ROADMAP | 8–9 | READY-FOR-DESIGN | `GET /api/v1/sites` (LIVE) | Grouping/region open. |
| EMS-REQ-011 | **Site context & selection.** All site-scoped screens follow the selection. | "Take me to Radisson Blu." | MUST | PRODUCT_OWNER | 8–9 | PO-REVIEW | EMS-REQ-010 | Multi-site selection pattern still open. |
| EMS-REQ-012 | **Portfolio vs. site landing.** Multi-site users land at portfolio or a site; single-site users skip portfolio. | "Where do I start?" | MUST | PRODUCT_OWNER | 9 | Resolved — see Workshop Q61/Q62 | EMS-REQ-010 | Design supports both. |
| EMS-REQ-013 | **Semantic breadcrumb.** `Organisation ▸ Site ▸ Space/Asset ▸ Parameter`, clickable, no IDs. | "Where am I?" | MUST | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | 8–9 | READY-FOR-DESIGN | EMS-REQ-003 | The "no raw-tag overload" principle. |
| EMS-REQ-014 | **Spaces navigation.** Browse a site's spaces; open a space's environmental detail. | "What's the temperature in Banquet Hall 2?" | MUST | PRODUCT_OWNER, ARCHITECTURE | 9 | READY-FOR-DESIGN | "spaces for a site" endpoint (MVP-1); `/spaces/{id}/measurements` (LIVE) | Resolved: drill-down, not primary nav (Q51/Q99). |
| EMS-REQ-015 | **Assets navigation.** Browse a site's assets/systems; open an asset. | "Show me my chillers." | MUST | PRODUCT_OWNER, ARCHITECTURE | 9 | READY-FOR-DESIGN | "assets for a site" endpoint (MVP-1) | |
| EMS-REQ-016 | **Asset component tree.** Navigate `AHU-01 → Fan → Motor` via `asset_relationships`. | "What's this made of?" | SHOULD | ARCHITECTURE, ZEROWATT_TECHNICAL_REFERENCE | 9 | READY-FOR-DESIGN | Phases 2/9; asset-relationship read object | Deferred — see [ADR-013](../00-governance/decisions/ADR-013-deferred-asset-component-tree.md). |
| EMS-REQ-017 | **Spaces served by an asset / assets serving a space.** Bidirectional `asset_space_relationships`. | "What conditions this room?" | SHOULD | ARCHITECTURE | 9 | READY-FOR-DESIGN | Phases 2/9 | |
| EMS-REQ-018 | **Functional categories in navigation.** Group meters/assets (HVAC, Lighting, Process). | "Show me HVAC vs. Process." | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | 10 | BLOCKED | PA-2 (still genuinely open) | No clean home in the frozen model yet. |
| EMS-REQ-019 | **Deep-linkable screens.** URLs encode semantic context for sharing/bookmarking. | "Send my colleague this exact view." | SHOULD | INFERENCE | 9+ | DRAFT | EMS-REQ-003 | Opaque semantic IDs only. |

## MONITOR — "How are we doing?"

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-020 | **Site Overview.** A single MONITOR screen per site with headline KPIs + a path to "why". | "How is this facility doing?" | MUST | PRODUCT_OWNER | MVP-3 | Resolved — see Workshop Q61/Q70 | EMS-REQ-021..025 | Landing page — see [ADR-004](../00-governance/decisions/ADR-004-site-overview-primary-destination.md). |
| EMS-REQ-021 | **Energy vs. expected/baseline.** Comparison to previous period; baseline once it exists. | "Is today's consumption normal?" | MUST | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | MVP-2 | READY-FOR-DESIGN | `energy/consumption` (LIVE); comparison (MVP-2) | |
| EMS-REQ-022 | **Current & peak demand vs. contracted.** Demand now, peak in period, contracted limit. | "Are we near our demand limit?" | MUST | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | MVP-2 | BLOCKED→MVP-2 | demand series via Phase 7 (planned) | Analytics layer verified LIVE; API+UI missing. |
| EMS-REQ-023 | **Environmental status roll-up.** Count/list of spaces in vs. out of comfort band. | "Are any rooms uncomfortable?" | MUST | PRODUCT_OWNER | MVP-1/3 | READY-FOR-DESIGN | `/spaces/{id}/measurements` (LIVE); site roll-up (planned) | |
| EMS-REQ-024 | **Data-quality / connectivity health.** A single honest signal: is the data trustworthy and current? | "Can I trust these numbers?" | MUST | PRODUCT_OWNER, ARCHITECTURE | MVP-4 | READY-FOR-DESIGN | `device_telemetry_state` via Phase 7 (planned) | Quality scaffolding exists. |
| EMS-REQ-025 | **Cost-to-date vs. budget.** Money view on the overview. | "What has this cost so far?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | Financial track | BLOCKED | PA-3; `config.tariffs` (verified: does not exist) | Only if tariffs are built. |
| EMS-REQ-026 | **Portfolio Overview.** Multi-site health tiles + "sites needing attention". | "Which site should I worry about?" | SHOULD | PRODUCT_OWNER | MVP-8 | Resolved (lowest priority) — Q63/Q64 | PA-6 | Cross-site aggregation surface undefined. |
| EMS-REQ-027 | **Period comparison.** Any headline metric shown against the equivalent prior period. | "Better or worse than last month?" | MUST | PRODUCT_OWNER | MVP-2 | READY-FOR-DESIGN | EMS-REQ-021 | |
| EMS-REQ-028 | **Notable-events strip.** Short list of period highlights. | "What happened today?" | SHOULD | INFERENCE, ZEROWATT_DEMO | MVP-2/3 | DRAFT | EMS-REQ-022, EMS-REQ-023 | Not "insights"; deterministic period facts. |

## INVESTIGATE — "Why is this happening?"

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-030 | **Progressive drill-down.** Time → system → asset → space → underlying measurement. | "Why did this number move?" | MUST | PRODUCT_OWNER | MVP-1..3 | PO-REVIEW | EMS-REQ-016/017 | The core INVESTIGATE loop. |
| EMS-REQ-031 | **Energy consumption trend + spike inspection.** Click a spike to zoom to its window. | "When did consumption deviate, and by how much?" | MUST | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | MVP-2 | READY-FOR-DESIGN | `energy/consumption` (LIVE) | Resolution ladder 1min–daily as supported. |
| EMS-REQ-032 | **Demand peak investigation.** Zoom to a peak; see contributing assets/systems. | "Why did demand peak, and what was running?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | MVP-2/Post-MVP | BLOCKED | demand series; contributing-equipment attribution | |
| EMS-REQ-033 | **Energy breakdown.** Split by functional category/system/meter role. | "Where is the energy going?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | 10 | BLOCKED | PA-2 | |
| EMS-REQ-034 | **Space environmental trend with comfort band.** Per-parameter trend; target overlay where present. | "Was the room too hot, and for how long?" | MUST | PRODUCT_OWNER, ARCHITECTURE | MVP-1 | READY-FOR-DESIGN | `/spaces/{id}/measurements` (LIVE); comfort targets (planned) | Dew point from persisted tier only. |
| EMS-REQ-035 | **Asset measurements (leaf view).** Contextual list/trend of an asset's parameters with attribution. | "Show me the actual readings." | SHOULD | ARCHITECTURE, ZEROWATT_TECHNICAL_REFERENCE | MVP-1/Post-MVP | DRAFT | asset-scoped measurements (planned) | Semantic attribution, not device IDs. |
| EMS-REQ-036 | **Curated correlations.** Pre-defined pairs (energy vs. outside temp; HVAC power vs. space temp). | "Does my energy track the weather?" | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | Post-MVP | DRAFT | PA-5 | **Curated only** — never free-form. |
| EMS-REQ-037 | **Trends (curated multi-series).** Several named semantic series on aligned timelines. | "How have these moved together?" | MUST | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | MVP-2 | READY-FOR-DESIGN | curated series catalogue | No tag browser. |
| EMS-REQ-038 | **Comparisons (like-for-like).** Periods, sites, spaces, or same-type assets. | "Is this better or worse than X?" | SHOULD | PRODUCT_OWNER | Post-MVP | DRAFT | cross-asset comparison views | Fairness rule: only within one `asset_type_id`. |

## Energy detail

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-040 | **Energy consumption workflow (parity with Grafana).** Numerically identical to existing dashboards. | "How much energy did we use?" | MUST | ROADMAP | MVP-2 | READY-FOR-DESIGN | Phase 10 parity gate | Grafana remains system of record until Phase 17 acceptance. |
| EMS-REQ-041 | **Demand workflow (parity).** Trend, peak, load-duration. | "What was our demand profile?" | MUST/SHOULD | ROADMAP | MVP-2 | BLOCKED→MVP-2 | demand via Phase 7 (planned) | |
| EMS-REQ-042 | **Multi-utility monitoring.** Energy plus water/gas/thermal on aligned timelines. | "Show energy and water together." | SHOULD | ZEROWATT_TECHNICAL_REFERENCE | Post-MVP | DRAFT | `water_measurements` wired to loaders (DDS Phase 3+) | |
| EMS-REQ-043 | **Power-quality analysis.** Voltage, current, PF, harmonics; imbalance highlighting. | "Is my supply healthy?" | SHOULD | ZEROWATT_TECHNICAL_REFERENCE | MVP-2 | DRAFT | high-res electrical params via Phase 7 | Phase labels shown as friendly `L1/L2/L3`. |
| EMS-REQ-044 | **Exact tariff costing.** Rate × consumption incl. time-of-day rates and demand charges. | "What did that cost, exactly?" | SHOULD/LATER | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | Financial track | BLOCKED | PA-3; `config.tariffs`/`analytics.cost_values` | Rate model, not a billing engine. |
| EMS-REQ-045 | **Custom process KPIs.** e.g. energy per unit of production. | "What's our kWh per tonne?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | Post-MVP | DRAFT | production data source (none today) | |
| EMS-REQ-046 | **Automatic running hours.** Computed from telemetry. | "How long did the compressor run?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | derived-parameter calc; not scheduled | |
| EMS-REQ-047 | **Start-up detection.** Identify equipment starts and abnormal behaviour. | "Did the chiller short-cycle?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | detection logic; not scheduled | |
| EMS-REQ-048 | **Shift-wise views.** Energy/production framed by shift context. | "How did the night shift do?" | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | no shift-context model exists | |
| EMS-REQ-049 | **Live single-line / energy-flow view.** Visualise power flow and energy balance. | "Show power flowing through my site." | LATER | ZEROWATT_TECHNICAL_REFERENCE | — | DRAFT | real-time model | Significant; deferred. |

## Environment

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-050 | **Environmental measurements per space.** Temperature, humidity, dew point with quality. | "What are the conditions in this space?" | MUST | PRODUCT_OWNER, ARCHITECTURE | MVP-1 | READY-FOR-DESIGN | `/spaces/{id}/measurements` (LIVE) | DEW_POINT = persisted tier. |
| EMS-REQ-051 | **Site-wide environmental grid/map.** All spaces' current value for a parameter; in/out of band. | "Which rooms are out of comfort?" | MUST | PRODUCT_OWNER | MVP-1 | READY-FOR-DESIGN | site environmental roll-up (planned) | |
| EMS-REQ-052 | **Comfort band overlay.** Target/tolerance band on environmental trends. | "Was it within target?" | SHOULD | ARCHITECTURE | MVP-1/Post-MVP | DRAFT | `direction_of_good`/target metadata | |
| EMS-REQ-053 | **Additional environmental parameters.** CO₂, occupancy, pressure as wired. | "What about air quality?" | COULD | ARCHITECTURE, ZEROWATT_TECHNICAL_REFERENCE | Post-MVP | DRAFT | `space_points` for those parameters | |
| EMS-REQ-054 | **Environment ↔ energy correlation (curated).** e.g. HVAC energy vs. space temperature. | "Is HVAC working harder than it should?" | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | Post-MVP | DRAFT | PA-5 | |

## Assets & performance

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-060 | **Asset Overview.** Status, key parameters, component tree, spaces served, recent events. | "How is this chiller doing?" | MUST | PRODUCT_OWNER, ARCHITECTURE | MVP-1/Post-MVP | READY-FOR-DESIGN | EMS-REQ-015/016/017 | |
| EMS-REQ-061 | **Asset Performance / condition monitoring.** Runtime, vibration, temperatures, per-asset efficiency. | "Is this equipment degrading?" | SHOULD | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | Post-MVP | DRAFT | `asset_health` + derived params via Phase 7 | Motor domain first (DDS Phase 11). |
| EMS-REQ-062 | **Derived efficiency parameters (e.g. COP).** Consumed, never computed in-browser. | "What's the plant efficiency?" | SHOULD | ARCHITECTURE | Post-MVP | DRAFT | `parameter_calculations`/`derived_parameter_values` | |
| EMS-REQ-063 | **Baseline / expected-performance overlays.** "Compared to what?" bands. | "Is this normal for these conditions?" | SHOULD | ROADMAP | Post-MVP | DRAFT | baseline as `parameter_calculations` specialization | Probabilistic; bake-in before exposure. |
| EMS-REQ-064 | **Cross-asset comparison.** Assets sharing an `asset_type_id`. | "Which of my 5 AHUs is worst?" | SHOULD | ROADMAP, ARCHITECTURE | Post-MVP | DRAFT | cross-asset comparison views | Fairness rule enforced. |
| EMS-REQ-065 | **Operating envelope view.** Asset's operation against its normal envelope. | "Is it operating outside its normal range?" | COULD | ROADMAP | Post-MVP | DRAFT | EMS-REQ-063 | |

## Data quality & real-time

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-070 | **Consistent quality indicators.** `GOOD/GAP/ESTIMATED/INVALID/PARTIAL`; `null` renders nothing. | "How good is this reading?" | MUST | ARCHITECTURE, PRODUCT_OWNER | 8/MVP-4 | READY-FOR-DESIGN | — | Never invent a quality value the API didn't return. |
| EMS-REQ-071 | **No-data as a normal state.** Never an error. | "Why is this empty?" | MUST | ARCHITECTURE | 8 | READY-FOR-DESIGN | — | See [ADR-011](../00-governance/decisions/ADR-011-insufficient-data-not-healthy.md). |
| EMS-REQ-072 | **Graceful resolution degradation.** Fall back to a coarser tier with a note. | "Why only hourly here?" | SHOULD | INFERENCE, ARCHITECTURE | MVP-2/4 | DRAFT | — | Known staging commissioning gap. |
| EMS-REQ-073 | **Customer-facing connectivity / freshness view.** Live status, last-seen, communication health. | "Is anything offline?" | SHOULD | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | MVP-4 | DRAFT | `device_telemetry_state` via Phase 7 | Not the ops SQL playbook. |
| EMS-REQ-074 | **High-resolution + aggregated views.** Detailed and hourly/daily/weekly/monthly aggregation. | "Zoom into the second; zoom out to the month." | MUST | ZEROWATT_TECHNICAL_REFERENCE | MVP-1/2 | READY-FOR-DESIGN | resolution ladder; API resolution params | Clamped to API-supported resolutions. |

## Alerts

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-080 | **View active & historical alerts.** Semantic subject, severity, value vs. threshold, time, status. | "What's wrong right now?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | MVP-7 | Resolved (scope) — Q77/Q78 | no alert model/endpoint defined | Alerts ≠ insights conceptually. |
| EMS-REQ-081 | **Alert → context navigation.** Jump to the metric's screen at the relevant time. | "Show me what triggered this." | SHOULD | INFERENCE | MVP-7 | DRAFT | EMS-REQ-080, EMS-REQ-030 | |
| EMS-REQ-082 | **Self-configurable alert rules.** Customers/plant users define alert rules. | "Alert me if the freezer goes above −18 °C." | LATER | ZEROWATT_TECHNICAL_REFERENCE | Post-MVP | BLOCKED | PA-4; config stays in Administration App per Q67 | |
| EMS-REQ-083 | **Demand-approaching alerts.** Warn when demand nears the contracted limit. | "Are we about to exceed contracted demand?" | COULD | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | MVP-7 | DRAFT | EMS-REQ-022, EMS-REQ-080 | |
| EMS-REQ-084 | **Multi-channel notification.** Email / mobile / messaging delivery. | "Text me when it happens." | LATER | ZEROWATT_TECHNICAL_REFERENCE | Post-MVP | DRAFT | Email is MVP (Q78); other channels deferred | |

## Reporting

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-090 | **Report catalogue + viewer.** Templated reports with preview. | "Give me the monthly energy report." | SHOULD | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | MVP-6 | DRAFT | report-definition storage; reads only via Phase 7 | |
| EMS-REQ-091 | **Familiar export formats.** PDF and Excel. | "In the format finance expects." | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | MVP-6 | BLOCKED | specific formats undecided (Q76 gives shape only) | |
| EMS-REQ-092 | **Scheduled report generation & delivery.** Runs unattended on a schedule. | "Send it automatically every month." | SHOULD | ROADMAP | MVP-6/Post-MVP | DRAFT | existing job-scheduling conventions | Not MVP per Q76 (no scheduling in MVP). |
| EMS-REQ-093 | **Report figures traceable to on-screen numbers.** Matches Phase 10 parity. | "Does the report match the dashboard?" | MUST (of reporting) | ROADMAP | MVP-6 | DRAFT | Phase 10 parity | |

## Priority summary

**MUST (near-term):** 001–008, 010–015, 020–024, 027, 030, 031, 034, 037,
040, 050, 051, 060, 070, 071, 074. (+ 041/022 as MUST/SHOULD depending on the
demand-endpoint schedule.) See
[non-functional-requirements.md](non-functional-requirements.md) for the
cross-cutting MUST set (100–105, 109).

**SHOULD:** 016–019, 025, 026, 028, 032, 033, 035, 036, 038, 041–043, 052,
054, 061–064, 072, 073, 080, 081, 090–093.

**COULD:** 053, 065, 083, 106 (see non-functional).

**LATER:** 044–049, 082, 084 — see also
[scope-and-deferred-functionality.md](scope-and-deferred-functionality.md)
for the later-intelligence and NOT-IN-SCOPE catalogues.

## Reference-product cross-check (context, not a requirements source)

Of a reference competitive product's 25 observed capabilities, this
catalogue classifies roughly 4 as MUST-adjacent (unified monitoring,
high-res+aggregated, context-aware, role-based), ~9 as SHOULD, and ~12 as
LATER. **Observing a capability in a reference product does not make it a
WiseWatts requirement** — every `ZEROWATT_TECHNICAL_REFERENCE`/
`ZEROWATT_DEMO`-sourced row above is a WiseWatts draft classification, not
an accepted commitment.
