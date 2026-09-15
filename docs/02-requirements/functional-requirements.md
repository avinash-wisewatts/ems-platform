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

Fully specified at the product/UX level by the Q77/MVP-7 Product Decision
handoff (2026-09-14) — see
[ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md).
Architecture decided 2026-09-14 — see
[ADR-017](../00-governance/decisions/ADR-017-mvp7-alert-architecture.md)
(evaluation mechanism, `Alert` domain model, single-source-of-truth
arrangement for the materiality rule). **`READY-FOR-DESIGN` where noted,
implemented 2026-09-14, staging validation pending** — see
[requirements-traceability.md §10](requirements-traceability.md) and
[docs/07-features/alerts/README.md](../07-features/alerts/README.md) for
exact status; Site-level Energy Attention only, Space/Asset alerts await a
separate condition decision.

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-080 | **View active & historical alerts.** Semantic subject, value vs. threshold, time, status. | "What's wrong right now?" | SHOULD | PRODUCT_OWNER, ZEROWATT_TECHNICAL_REFERENCE | MVP-7 | READY-FOR-DESIGN | no alert model/endpoint defined; ADR-016 | Alerts ≠ insights conceptually. "Severity" removed from this row's description 2026-09-14 — see the contradiction record below. Full lifecycle/state/content detail: `EMS-REQ-117`–`127`. |
| EMS-REQ-081 | **Alert list/detail (no analytical deep link in MVP-7).** Alert detail shows full context (hierarchy, values, threshold) in place; it does not jump to the metric's own analytical screen. | "Show me what triggered this." | SHOULD | INFERENCE | MVP-7 | READY-FOR-DESIGN | EMS-REQ-080, EMS-REQ-124 | 2026-09-14: narrowed from the original "jump to the metric's screen" framing — ADR-016 decision 12 explicitly excludes analytical deep links from MVP-7 alerts. See the contradiction record below. |
| EMS-REQ-082 | **Self-configurable alert rules.** Customers/plant users define alert rules. | "Alert me if the freezer goes above −18 °C." | LATER | ZEROWATT_TECHNICAL_REFERENCE | Post-MVP | BLOCKED | PA-4; config stays in Administration App per Q67 | Unaffected by ADR-016 — MVP-7 alerts are generated automatically from existing Attention conditions with no customer-facing rule-authoring layer (ADR-016 decision 2). |
| EMS-REQ-083 | **Demand-approaching alerts.** Warn when demand nears the contracted limit. | "Are we about to exceed contracted demand?" | COULD | ZEROWATT_TECHNICAL_REFERENCE, INFERENCE | MVP-7 | BLOCKED | EMS-REQ-022, EMS-REQ-080; no contracted-demand threshold exists anywhere in the schema | Unaffected by ADR-016 — MVP-7 alerts fire only from Attention conditions that already exist (currently Energy only, ADR-010); a demand-proximity condition would need its own threshold/materiality decision first, then would flow through the same ADR-016 lifecycle. |
| EMS-REQ-084 | **Multi-channel notification.** Mobile / messaging / email delivery. | "Text me when it happens." | LATER | ZEROWATT_TECHNICAL_REFERENCE | Post-MVP | DRAFT | ADR-016 (email removed from MVP-7) | 2026-09-14: **email is no longer MVP scope** — ADR-016 supersedes the archived Q78 "email is turned on for MVP" statement; all channels (email included) are now deferred alongside SMS/WhatsApp/sharing, not partially landed. See the contradiction record below. |
| EMS-REQ-117 | **Alert generation from Attention conditions.** Every qualifying Attention condition auto-generates an alert per affected context; no separate rule-selection layer; qualifies after 5 minutes continuously true, timed from first true observation, reset by any evaluation/data gap. | "Tell me when something needs attention, automatically." | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | ADR-016 decision 2; depends on Architecture Question A (no evaluation mechanism exists) | No customer-visible pending state before qualification. |
| EMS-REQ-118 | **Alert lifecycle states.** Active (condition true) → Resolved (continuously false for 1 minute, gap-reset) or Ended (two causes: configuration disabled/changed, or the condition was still true when data recovered from an unavailable-data gap — added 2026-09-15, see EMS-REQ-119) — Ended is never presented as Resolved. | "Is this still a problem?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-117, EMS-REQ-119; ADR-016 decisions 3, 4, 7 | |
| EMS-REQ-119 | **Data-gap handling.** An Active alert whose data becomes unavailable stays Active ("Unable to evaluate — data unavailable"), not auto-resolved; on data recovery, a still-true condition requires a fresh 5-minute qualification before a new alert is generated. | "What happens if the sensor drops out?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-118; ADR-016 decision 4 | |
| EMS-REQ-120 | **Configuration-change transitions.** Disabling a condition Ends its Active alert; changing threshold/scope Ends the existing alert and requires fresh 5-minute qualification under the new configuration with a new alert identity; simultaneous clear+change classifies as Ended, not Resolved; a change with no Active alert takes effect immediately with no transition record. | "What happens to an active alert if the admin changes the rule?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-118; ADR-016 decision 8; config stays in Administration App per Q67 | |
| EMS-REQ-121 | **Restart and persistence-failure resilience.** Active/Resolved/Ended records survive restart/deployment without loss or duplication (in-progress timers reset); a persistence failure at qualification retries for up to 30 minutes preserving original trigger info, then discards with an operational record if still unsuccessful — never exposed as a customer-visible alert. | "Will I lose alert history if the system restarts?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-117; ADR-016 decisions 5-6; ADR-017 (evaluation mechanism) | 2026-09-14: mechanism decided (TimescaleDB background job, ADR-017) — restart-survival follows from the job pattern's own persistence. Exact candidate-tracking design and how the 30-minute per-occurrence retry composes with the job's own retry semantics remain implementation-design questions (ADR-017 "Remaining unresolved"). |
| EMS-REQ-122 | **Historical immutability and retention.** Historical alert records never change after the fact; Resolved/Ended alerts remain customer-visible for 90 days from resolution/ending; Active alerts remain visible indefinitely while true. | "How long can I see past alerts?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-118; ADR-016 decision 9; depends on Architecture Question B (no Alert entity exists) | |
| EMS-REQ-123 | **Recurrence tracking.** A recurrence shares exact context + condition/metric + threshold/reference identity (a configuration change creates a new identity); alert detail shows "Previous occurrences: N" / "Most recent: <time>" (by triggered time), limited to the 90-day retained window, unvaried by status, no per-occurrence list. | "Has this happened before?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-122; ADR-016 decision 10 | |
| EMS-REQ-124 | **Alert content and detail view.** Existing EMS terminology/number formatting only; list shows condition + context + triggered time; detail adds hierarchy context, current state, trigger/latest/resolution values, threshold/reference, previous occurrences (Ended alerts add ended time + reason); never exposes device IDs, point IDs, or other internal identifiers. | "What exactly triggered, and where?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-118, EMS-REQ-123; ADR-016 decision 11 | |
| EMS-REQ-125 | **Alert navigation and delivery — in-product only.** Header indicator shows the count of currently Active alerts scoped to the selected Site/context (visible with no number at zero; no count with no context selected); dedicated Alerts area lists Active/Resolved/Ended; no email/SMS/WhatsApp/sharing; no analytical deep links. | "Where do I see my alerts?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-080; ADR-016 decisions 1, 12 | Supersedes the archived Q78 "in-product + email" statement — see the contradiction record below. |
| EMS-REQ-126 | **Filtering and ordering.** Cascading Site→Space→Asset filters; single-select Condition/Metric filter; date filter keyed to the status-appropriate timestamp with 90-day defaults; explicit "Apply filters"/"Clear filters"; infinite scroll; ordering by existing Attention materiality then recency, unchanged by filters, never exposed as a new severity taxonomy. | "Can I find the alert I'm looking for?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | EMS-REQ-080; ADR-016 decision 13 | |
| EMS-REQ-127 | **Authorization.** Alert visibility follows existing EMS authorization; no alert-specific recipient/permission configuration or new Admin role; configuration remains exclusively in the Administration App. | "Who can see or configure alerts?" | SHOULD | PRODUCT_OWNER | MVP-7 | READY-FOR-DESIGN | Q67; ADR-016 decision 14; ADR-017 (verified against `_require_portal_user`/three-role scope model) | Space/Asset-level Attention is product-specified (Q99/Q100, "where supported") but not yet built — MVP-3 explicitly narrowed its own increment to Site-level Energy only (commit `19c09d7`). A sequencing dependency, not a contradiction: MVP-7 alerts are Site-level-Energy-only until that extension is built. See `requirements-traceability.md` §3/§9. |

> **Contradiction resolved (2026-09-14)** — three Alerts rows corrected per
> [source-of-truth.md](../00-governance/source-of-truth.md)'s recording
> format, following the Q77/MVP-7 discovery handoff and
> [ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md):
>
> **CURRENT IMPLEMENTATION:** no code exists for any Alerts row; this is a
> documentation-only correction of decided scope.
>
> **HISTORICAL / DOCUMENTED EXPECTATION:**
> 1. `EMS-REQ-080` described alerts as showing "severity."
> 2. `EMS-REQ-081` described "alert → context navigation... jump to the
>    metric's screen at the relevant time."
> 3. `EMS-REQ-084`'s Notes read "Email is MVP (Q78); other channels
>    deferred."
>
> **CHANGE:** (1) ADR-016 decision 13 uses Attention materiality for
> ordering only and explicitly rejects exposing it as a new
> High/Medium/Low severity taxonomy — "severity" removed from
> `EMS-REQ-080`'s description. (2) ADR-016 decision 12 explicitly excludes
> analytical deep links from an alert to other screens in MVP-7 —
> `EMS-REQ-081` retitled to describe in-place detail content instead of
> navigation to the metric's own screen. (3) ADR-016's source-of-truth
> correction supersedes the archived Q78 "email notifications are turned on
> for MVP" statement — email is now fully out of MVP-7 scope, not partially
> landed; `EMS-REQ-084`'s Notes corrected accordingly.
>
> **VERIFICATION:** confirmed directly against the Q77/MVP-7 discovery
> handoff text (§1, §12/§36, §48 in ADR-016's Decision section) transferred
> into this session 2026-09-14; no inference was required.

## Reporting

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-090 | **Report catalogue + viewer.** Templated reports with preview. | "Give me the monthly energy report." | SHOULD | ROADMAP, ZEROWATT_TECHNICAL_REFERENCE | MVP-6 | READY-FOR-DESIGN | report-definition storage; reads only via Phase 7 | 2026-09-14: catalogue decided as exactly one report type (Site Performance Report) — see [EMS-REQ-110](#site-performance-report)/[ADR-015](../00-governance/decisions/ADR-015-q76-site-performance-report.md). "Report-definition storage" dependency does not apply to this report — it is composed live from existing endpoints, not stored. |
| EMS-REQ-091 | **Familiar report formats.** PDF and Excel. | "In the format finance expects." | SHOULD | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | MVP-6 | PARTIALLY READY-FOR-DESIGN | PDF decided 2026-09-14 for the Site Performance Report ([EMS-REQ-114](#site-performance-report)); Excel remains undecided | Report (Q76) output format. PDF is now decided, for this one report type only — see [ADR-015](../00-governance/decisions/ADR-015-q76-site-performance-report.md). Excel is not addressed by that decision and stays `BLOCKED`. See the contradiction record below for why this row's title changed, and `EMS-REQ-096`/[ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md) for the distinct Export (Q75) format (CSV). |
| EMS-REQ-092 | **Scheduled report generation & delivery.** Runs unattended on a schedule. | "Send it automatically every month." | SHOULD | ROADMAP | MVP-6/Post-MVP | DRAFT | existing job-scheduling conventions | Not MVP per Q76 (no scheduling in MVP). Confirmed unaffected 2026-09-14 — the Site Performance Report has no scheduling/email/history ([EMS-REQ-115](#site-performance-report)). |
| EMS-REQ-093 | **Report figures traceable to on-screen numbers.** Matches Phase 10 parity. | "Does the report match the dashboard?" | MUST (of reporting) | ROADMAP | MVP-6 | READY-FOR-DESIGN | Phase 10 parity | 2026-09-14: satisfied by construction for the Site Performance Report — it reuses `SiteOverview.tsx`'s own data-fetching functions rather than a second computation path. See [ADR-015](../00-governance/decisions/ADR-015-q76-site-performance-report.md) Rationale. |

> **Contradiction resolved (2026-09-14)** — `EMS-REQ-091`'s title, per
> [source-of-truth.md](../00-governance/source-of-truth.md)'s recording
> format:
>
> **CURRENT IMPLEMENTATION:** `EMS-REQ-091`'s title reads "Familiar report
> formats" and its row describes Q76's (Reporting) output format only,
> which remains `BLOCKED`/undecided.
>
> **HISTORICAL / DOCUMENTED EXPECTATION:** this row was originally titled
> "Familiar export formats" — wording that, read on its own, could be
> mistaken for specifying Q75's (Export) raw-data file format, even though
> the row's own Notes column already said "Q76 gives shape only" and the
> row sits under the "Reporting" heading, not a separate Export one (which
> did not yet exist).
>
> **CHANGE:** the MVP-6 Product Decision Workshop (2026-09-14) decided
> Q75's Export format is CSV (`EMS-REQ-096`,
> [ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md)).
> Because that is a different, now-decided format from Q76's still-open
> Report format, `EMS-REQ-091`'s title was corrected from "export" to
> "report" so it no longer reads as if it named the Export format. No
> status, priority, or decision content in the row changed — only the two
> words in its title.
>
> **VERIFICATION:** confirmed by re-reading `EMS-REQ-091`'s own
> pre-existing Notes column ("specific formats undecided (Q76 gives shape
> only)") and Workshop baseline §108
> (`docs/99-archive/superseded-product/ems-product-owner-workshop-baseline.md`):
> *"Report = communicate the important story; Export = provide the
> underlying data"* — both already establish this row was always about
> Reporting, not Export; the title alone was misleading.

## Export

Decided by the MVP-6 Product Decision Workshop (2026-09-14) — see
[ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md)
for full context, rationale, and evidence. Distinct from Reporting above
per Q76's own framing: *"Report = communicate the important story; Export
= provide the underlying data."* **`READY-FOR-DESIGN`** — per this
document's own Status convention (`READY-FOR-DESIGN` = "agreed enough to
design against", [README.md](README.md#conventions)); this Status column
tracks decision readiness, not implementation, per
[requirements-traceability.md](requirements-traceability.md) (the
implementation-status-authoritative view).
>
> **Implementation note (2026-09-15):** a first increment had code — a
> contextual CSV export of the Energy Consumption figure
> (`web/src/energy/energyExportCsv.ts`, wired into `EnergyOverview.tsx`),
> covering `EMS-REQ-094`/`095`/`096`/`099` for the Energy screen only. No
> other row below has any implementation: Demand/Power Quality export,
> the dedicated Export area (`EMS-REQ-098`), and size-tiered/background
> delivery (`EMS-REQ-097`) remain uncoded. See
> [requirements-traceability.md §11](requirements-traceability.md#11-status-update-2026-09-15--q75-increment-1-energy-contextual-csv-export-implemented-not-deployed)
> for the full record. Not deployed to staging or production.
>
> **Correction (2026-09-15, later the same day):** the increment note
> above described a single period-summary row per export. This
> interpretation of `EMS-REQ-094` is **superseded** by a Product Owner
> decision recorded in
> [ADR-014's dated amendment](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md#amendment-2026-09-15--decision-1-narrowed-energy-chart-series-now-in-scope):
> for the Energy contextual export, "the on-screen aggregated analytical
> figure" in `EMS-REQ-094`'s own description below includes the Energy
> Trend chart's own already-displayed, already-aggregated per-bucket
> series (`current.series` — `bucket_start`/`import_kwh`, at the
> response-level resolution) — this is distinct from, and `EMS-REQ-094`'s
> exclusion of "the underlying raw time-series" still means, genuinely raw
> sub-interval telemetry, which remains out of scope. `EMS-REQ-094`'s
> table text below is intentionally left unedited (historical record of
> the 2026-09-14 decision); this note is the correction. See
> [requirements-traceability.md §12](requirements-traceability.md#12-status-update-2026-09-15--q75-energy-chart-data-export-decided-correcting-increment-1)
> for the full record.

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-094 | **Export content — aggregated figures, not raw series.** The on-screen aggregated analytical figure (e.g. period total, peak demand, PF/THD summary), not the underlying raw time-series. | "Give me the numbers I'm looking at." | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q75; ADR-014 decision 1 | Narrows Q75's original "relevant measurements" wording — see ADR-014 Rationale. |
| EMS-REQ-095 | **Export context fields.** Site/hierarchy context, selected time range, comparison/baseline basis (where the metric has one), metric name and unit, and data-quality/freshness information where relevant to interpreting the figure. | "What am I looking at, and can I trust it?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q75; ADR-014 decisions 2-3, 8 | Comparison/baseline fields mirror exactly what's shown on-screen, including any displayed difference — not a separately-computed comparison. |
| EMS-REQ-096 | **Export format — CSV.** | "What file do I get?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q75; ADR-014 decision 4 | Distinct from Report format (EMS-REQ-091), which remains `BLOCKED`/undecided. |
| EMS-REQ-097 | **Export delivery — size-tiered.** Immediate download for smaller exports; background generation for larger exports. | "How do I get a big export?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q75; ADR-014 decision 5 | The two-tier delivery *model* is agreed enough to design against; the specific size/row/byte threshold between the tiers is not decided — deliberately not invented (see ADR-014 decision 5). |
| EMS-REQ-098 | **Export availability — contextual and dedicated.** Available from relevant analytical screens (Energy, Demand, Power Quality, etc.) in context, and through a dedicated Export area. The dedicated area supports multi-metric export across Energy, Demand, and Power Quality together; the contextual path is single-screen. | "Where do I export from?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q75; ADR-014 decisions 6-7 | |
| EMS-REQ-099 | **Export time range, hierarchy scoping, and data completeness.** Selectable time range is bounded by the site's actual min/max data-available dates. Contextual export follows the hierarchy level currently being viewed (Site/Space/Asset); the dedicated Export area lets the customer select the desired hierarchy level. Data gaps within the range retain their applicable data-quality/freshness state rather than being omitted; a metric with no usable data is still represented, with its applicable data-quality state and no fabricated value. | "Can I trust the range, and what happens with gaps?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q75; ADR-014 decisions 9-12; ADR-011 (no-data ≠ fabricated value, same discipline extended here) | |

## Site Performance Report

Decided and implemented, not yet deployed, per the Q76 Product Decision
Workshop (2026-09-14) — see
[ADR-015](../00-governance/decisions/ADR-015-q76-site-performance-report.md)
for full context, rationale, gap resolutions, and evidence. IDs start at
`110`, not `100`, because `100`–`109` belong to
[non-functional-requirements.md](non-functional-requirements.md) in this
shared `EMS-REQ` numbering space.

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-110 | **Report catalogue — one type.** Exactly one report type for MVP-6: the Site Performance Report. Reports area only — no contextual generation from other screens. | "What reports can I generate?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q76; ADR-015 Decision (catalogue, access) | |
| EMS-REQ-111 | **Report configuration.** Hierarchy context (Site/Space/Asset) and reporting period: predefined current-calendar Weekly/Monthly/Quarterly/Yearly, or Custom (any dates). | "Which site/space/asset, and what period?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q76; ADR-015 Decision (configuration inputs); ADR-015 gap resolutions 1-3 | Custom period does not enforce a data-availability bound — no such API exists (ADR-015 gap resolution 2). Predefined periods are a new calendar-aligned concept, distinct from the existing `TimeRangePicker` rolling-window presets (ADR-015 gap resolution 3). |
| EMS-REQ-112 | **In-app generation.** Generated on demand, in-app. Title: "Performance Report — [context name]". | "Show me the report." | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q76; ADR-015 Decision (generation, title) | |
| EMS-REQ-113 | **Report structure.** Overall Site Health/Status → Attention/Exceptions → Energy Performance → Maximum Demand → Power Quality → Investigation paths, in that order — the same structure and order as `SiteOverview.tsx` (ADR-003/ADR-004). Only existing EMS metrics, comparisons/baselines, and deterministic rules — no new analytics, thresholds, metrics, or AI/LLM narrative reasoning. Per-domain `Data unavailable` states are preserved; one domain's absence never blocks the others. No overall report status beyond the existing three-state Site Health signal. | "What does the report contain, and can I trust it?" | MUST (of this report) | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q76; ADR-015 Decision (report structure, data rules, no overall status); ADR-015 gap resolutions 1, 6 | Report content is always the selected Site's own data — Space/Asset hierarchy selection changes the title and Investigation-section target only, never the Health/Attention/Energy/Demand/PQ figures, because no Space/Asset-scoped equivalent of those analytics exists anywhere in the platform (ADR-015 gap resolution 1). Site Health/Attention require the Slice C typical-reference endpoint's exact whole-day window (1/7/30/90/365 days) and so are legitimately unavailable for most calendar-to-date periods (ADR-015 gap resolution 6) — Energy's current value and Previous-Period comparison remain available regardless. Structure is the **implemented baseline, not frozen** — a later UX/design refinement may change presentation without a new product decision, provided the six-section composition and existing-metrics-only rule are preserved. |
| EMS-REQ-114 | **Optional PDF.** Generated from the already-rendered in-app report; same underlying content, PDF-specific layout. Immediate where practical; background-generated for larger reports (no size/row/byte threshold invented). | "Can I get a PDF?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q76; ADR-015 Decision (PDF); ADR-015 gap resolutions 4-5 | No server-side report-generation job/queue exists anywhere in the repository and none is invented here; PDF is generated client-side. "Background-generated for larger reports" is therefore approximated (never blocks the in-app report), not a literal separate job state — see ADR-015 gap resolutions 4-5 for the full, explicit limitation. |
| EMS-REQ-115 | **No history, email, or sharing.** No report history is retained; no email delivery; no share links. "Change" (return to configuration) and "Generate another report" controls exist. | "Can I go back and try a different report?" | SHOULD | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q76; ADR-015 Decision (controls, non-goals) | |
| EMS-REQ-116 | **Error handling.** A clear generation-error state with retry. A PDF-generation failure leaves the already-generated in-app report intact — it is never discarded or invalidated by a failed PDF attempt. | "What happens if generation fails?" | MUST (of this report) | PRODUCT_OWNER | MVP-6 | READY-FOR-DESIGN | Q76; ADR-015 Decision (error handling); ADR-011 (no-data/error discipline extended here) | |

## Priority summary

**MUST (near-term):** 001–008, 010–015, 020–024, 027, 030, 031, 034, 037,
040, 050, 051, 060, 070, 071, 074. (+ 041/022 as MUST/SHOULD depending on the
demand-endpoint schedule.) See
[non-functional-requirements.md](non-functional-requirements.md) for the
cross-cutting MUST set (100–105, 109).

**SHOULD:** 016–019, 025, 026, 028, 032, 033, 035, 036, 038, 041–043, 052,
054, 061–064, 072, 073, 080, 081, 090–093, 094–099, 110–116.

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
