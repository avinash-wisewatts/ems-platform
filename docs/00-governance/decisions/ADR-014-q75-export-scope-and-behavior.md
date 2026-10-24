# ADR-014: MVP-6 Export scope, content, format, and behavior (Q75)

Status: Decided; amended 2026-09-15 (see "Amendment" below) — Energy
contextual chart-data export implemented, not deployed; Amendment 2
(2026-10-24) — dedicated Reports-tab site measurement export implemented
(migration 309), deployed to staging 2026-10-24, not deployed to production;
Reports UI acceptance testing outstanding (see 07-features/export); Amendment 3
(2026-10-24) — asset selection (at most 10) and 14-day 1-minute exports
(migration 312) implemented, not merged or deployed
Date: 2026-09-14 (MVP-6 Product Decision Workshop); amended 2026-09-15
Decision owners: Product Owner
Related requirements: EMS-REQ-094 through EMS-REQ-099
Related features: Export (no dedicated feature document yet — see
[07-features/README.md](../../07-features/README.md); created once the
underlying capability exists to document)

## Context

Workshop Q75 (`docs/99-archive/superseded-product/ems-product-owner-workshop-baseline.md`
§107) established that MVP includes export of underlying analytical data
and context, explicitly **not** a general-purpose BI/query-builder tool,
and listed illustrative content ("may include": Portfolio/Site/Space/Asset
context, selected time range, relevant energy/demand/PQ measurements,
comparison period/baseline, applicable calculated metrics, data-quality
indicators). `docs/01-product/roadmap.md` classifies this as MVP-6,
depending on MVP-2 (the figures exported) and MVP-3 (the reporting/
overview source). As of the 2026-09-14 MVP-6 discovery pass (see
[requirements-traceability.md §6](../../02-requirements/requirements-traceability.md)),
zero export implementation existed anywhere in the codebase, and every
concrete question below (format, delivery, scope, time-range bounds,
data-gap handling) was `OPEN`, `BLOCKED`, or `UNKNOWN` per that discovery's
workshop brief.

This ADR is the record of the MVP-6 Product Decision Workshop
(2026-09-14) that resolved those Export (Q75) questions. It refines and
narrows Q75's original archived list into a fully specified content and
behavior model; it does not contradict Q75 — the decisions below are a
subset/specification of what Q75's "may include" list already permitted.
Reporting (Q76) is explicitly out of scope for this record — see
[07-features/README.md](../../07-features/README.md) note above and the
Q76 discussion in [requirements-traceability.md](../../02-requirements/requirements-traceability.md);
Q76's format, catalogue, and storage-shape questions remain `OPEN`/
`BLOCKED`, unresolved by this decision.

## Decision

**1. Content — aggregated figures, not raw time-series.** Export contains
the aggregated analytical figures already presented in the EMS (e.g. a
period's total consumption, a peak-demand figure, a PF/THD summary value)
— not the raw/underlying time-series measurements behind them. This is a
narrowing of Q75's original "relevant energy/demand/PQ measurements"
wording to the on-screen, already-computed figures specifically.

**2. Context fields.** Every export includes: Site/hierarchy context (see
decision 12), the selected time range, the comparison/baseline basis
(where the metric has one), and the metric's name and unit.

**3. Data-quality/freshness inclusion.** Data-quality/freshness
information is included wherever it is relevant to interpreting the
exported figure — mirroring the on-screen presentation, not a separate
export-only quality model.

**4. Format — CSV.** The export file format is CSV. No other format is
decided for MVP-6 export (distinct from, and not to be confused with,
Q76's still-undecided report output format — see the note added to
`EMS-REQ-091`).

**5. Delivery — size-tiered, no invented threshold.** Smaller exports
support immediate download. Larger exports support background generation
instead. **No specific size/row/byte threshold between the two is decided
here** — that boundary is left open for implementation-time or a future
decision; this ADR records only that both delivery modes are required.

**6. Availability — contextual and dedicated.** Export is available two
ways: contextually, from the relevant analytical screens (Energy, Demand,
Power Quality, and wherever else an exportable figure is already shown),
and through a dedicated Export area.

**7. Dedicated Export area — multi-metric.** The dedicated Export area
supports exporting multiple metrics together, across Energy, Demand, and
Power Quality in one export — unlike the contextual, single-screen export
path.

**8. Comparison/baseline fields mirror on-screen display.** Comparison/
baseline fields in an export follow exactly what is actually displayed
on-screen for that metric — including any displayed difference/delta —
rather than exporting a different or more extensive comparison basis than
the customer already sees.

**9. Time-range bounds — site data availability.** The selectable time
range for an export is constrained to the minimum and maximum dates for
which the specific site actually has data available — not an arbitrary or
universal bound.

**10. Data gaps — retained, not silently omitted.** Data gaps within the
selected, site-specific range are retained in the export with their
applicable EMS data-quality/freshness state, rather than being silently
dropped from the output.

**11. No-usable-data metrics — represented, not fabricated.** A selected
metric that has no usable data for the requested range is still
represented as a row/entry in the export, carrying its applicable
data-quality state and explicitly no usable value — never omitted and
never a fabricated number.

**12. Hierarchy-level scoping.** Contextual export follows whatever
hierarchy level the customer is currently viewing — Site, Space, or Asset.
The dedicated Export area additionally lets the customer select the
desired hierarchy level directly, rather than being limited to whatever
level they last navigated to.

## Amendment (2026-09-15) — Decision 1 narrowed: Energy chart series now in scope

**This amendment does not delete or edit decision 1 above — that text is
preserved verbatim as the historical record of what was decided
2026-09-14, per this documentation set's no-silent-rewrite rule
([source-of-truth.md](../source-of-truth.md)).** It records a
**subsequent** Product Owner decision (2026-09-15) that narrows decision
1's scope for one specific case.

**Context for the amendment.** A read-only requirements reconciliation
(2026-09-15, recorded in [requirements-traceability.md §12](../../02-requirements/requirements-traceability.md))
found that decision 1's exclusion of "the raw/underlying time-series
measurements behind" an aggregated figure is genuinely ambiguous as
applied to the Energy Trend chart's own series: `current.series`
(`bucket_start`/`import_kwh`, at the response-level `resolution`) is
simultaneously (a) the data that `sum()`s into the period-total figure
decision 1's own example describes, and (b) an aggregated analytical
series **already presented on screen** (`Q94`, workshop baseline §127,
"Underlying analytical time-series inspection") — matching decision 1's
own affirmative definition ("aggregated analytical figures already
presented in the EMS") at least as well as it matches the exclusion.
This ADR's own "Alternatives considered" section already flagged that
whether a raw-series alternative was explicitly discussed and rejected,
as opposed to simply not chosen, was never recorded.

**Decision.** The Product Owner has now resolved this ambiguity: the
Energy contextual export (the "Export CSV" action on the Energy screen)
**must export the analytical data points that make up the currently
displayed Energy chart** — `current.series`, one CSV row per point
(`bucket_start` as timestamp, `import_kwh` as value), in chart order, at
the chart's own resolution. This supersedes the interpretation used by
the first implementation of this export, which produced a single
period-summary row instead.

**What remains unchanged, explicitly.** This amendment is narrow. It does
**not** reopen or decide:
- Comparison-period point-by-point export — still excluded. The
  comparison period's own series is not displayed on the Energy chart
  (only its total/delta, per decision 8), so decision 8 continues to keep
  comparison summary/contextual only.
- `export_kwh`, `source_interval_count`, or per-point evidence/quality
  fields — these exist on the underlying API responses but are not
  rendered by the chart either; still explicitly out of scope/undecided,
  not authorized by this amendment.
- Demand or Power Quality export, the dedicated multi-metric Export area
  (decisions 6-7), and size-tiered/background delivery (decision 5) — all
  unchanged, still unimplemented, still governed by their original
  decision text above.
- Genuinely raw/sub-interval telemetry (i.e. data finer-grained than the
  chart's own resolution) — decision 1's exclusion of this remains fully
  in force; this amendment narrows decision 1 only for the chart's own
  already-displayed series, not for raw telemetry generally.

## Amendment 2 (2026-10-24) — dedicated Reports-tab site measurement export

**Source.** An explicit Product request in the 2026-10-23/24 engineering
session (the request text is the durable source; no separate workshop):
add a **Reports** entry directly below **Alerts** in the EMS Web App
primary navigation that exports **all available measurement data for every
asset of a selected site** over a chosen date/time range, as **one ZIP
with one CSV per asset** (`Timestamp (UTC)`, `Timestamp (Site Local)`, then
every data point), immediate download for small exports and a background
job with in-app completion notification for large ones. Decisions above
are not edited; this records how that request relates to them.

**Relationship to the decisions above (no silent reconciliation):**

| Decision | Status for the Reports-tab export |
|---|---|
| 1 (aggregated, not raw) | **Narrowed further, by the request.** Each CSV column is an Analytics series exactly as the Analytics page displays it (ADR-022: bucket mean for measurements, bucket sum for Energy, at the chosen resolution `auto`/1m/15m/30m/1h/1d with the ADR-019 maximum windows). Still never finer than an Analytics resolution, i.e. no sub-minute raw telemetry. |
| 2 (context fields) | Partly: site and time range are in the ZIP/CSV file names, metric name and unit in each column header. No comparison/baseline (none is displayed by Analytics). |
| 3, 10, 11 (quality state for gaps / no-data) | **Open — not met.** A gap is a row with an empty cell; an asset with no data in range is a header-only CSV (never omitted, never a fabricated value). Per-cell data-quality state is **not** exported, because the requested column layout has none. Product decision needed: add quality columns, or accept empty cells. |
| 4 (CSV) | Met (CSV files inside a ZIP container). |
| 5 (size-tiered delivery) | Met. Threshold is an implementation default, configurable, not a product decision: estimated buckets x columns <= `EMS_REPORT_EXPORT_IMMEDIATE_MAX_CELLS` (150,000) downloads immediately; <= `EMS_REPORT_EXPORT_MAX_CELLS` (3,000,000) runs in the background; larger is refused with guidance. |
| 6, 7 (dedicated area, multi-metric) | Met for measurements: every data point confirmed for the asset in its Analytics catalogue (`metadata.asset_points`), each assigned qualifier one column — the Analytics chart data points (Energy, Energy Export, Power, Reactive Power, Current, Voltage, Line to Line Voltage, Power Factor, Frequency; System and per-phase) and every other confirmed point (e.g. Temperature, Relative Humidity, Occupancy Activity, Illuminance, Apparent Power/Energy, Current THD, Phase Angle, Neutral current). Corrected 2026-10-24: the first implementation exported only the nine chart data points (see [07-features/export](../../07-features/export/README.md) "Fix history"). Demand intervals are not catalogue data points and are not included. |
| 9 (site-bounded range) | Met: the date picker is bounded by the site catalogue's earliest data (the Analytics rule). |
| 12 (hierarchy level) | Site level only, by the request (every asset of the site). |

Implementation and operations are described in
[07-features/export/README.md](../../07-features/export/README.md).

## Rationale

Decision 1 (aggregated, not raw) keeps Export aligned with Q75's own
"not a BI/query-builder tool" constraint — raw time-series export invites
query-builder-style usage patterns the workshop explicitly excluded.
Decisions 10-11 (retain gaps, represent no-data honestly) extend the same
"no data" ≠ "error", never-fabricate-a-value discipline already governing
the rest of the EMS (`interaction-patterns.md`, ADR-011) into the export
surface, rather than inventing export-specific behavior. Decision 5's
refusal to invent a size threshold follows this documentation set's
evidence discipline — no technical threshold was given in this workshop,
so none is recorded as decided.

## Alternatives considered

Not established in available source material. What is established is the
decision itself (decision 1): MVP-6 Export is defined to contain the
aggregated analytical figures presented in EMS, not raw/underlying
time-series measurements. Q75's original archived wording ("relevant
energy/demand/PQ measurements") did not itself distinguish aggregated
figures from raw series, so decision 1 narrows that wording — but whether
a raw-series alternative was explicitly discussed and rejected during this
workshop, as opposed to simply not being the option chosen, is not
recorded, and this ADR does not claim otherwise. No other alternative is
established in available source material for the remaining decisions;
where the workshop specified a single behavior directly, no competing
option was recorded.

## Consequences

- `docs/02-requirements/functional-requirements.md` gains a new `##
  Export` section (`EMS-REQ-094`–`EMS-REQ-099`) recording decisions 1-12
  as testable requirements.
- `docs/02-requirements/requirements-traceability.md` §6 records Q75's
  classification change from its 2026-09-11 `C — NOT LANDED` (decision
  blocker) to decision-resolved-but-still-`C`-for-implementation, per this
  ADR.
- `docs/01-product/roadmap.md`'s MVP-6 entry is updated to reference this
  ADR.
- `docs/03-ux-and-design/information-architecture.md` gains a dedicated
  `## Export (MVP-6)` subsection, separated from `## Reports (MVP-6)` per
  Q76's own "Report = the story, Export = the data" distinction.
- `docs/03-ux-and-design/navigation.md`'s proposed nav tree gains an
  `Export` entry alongside `Reports`, subject to the same ADR-005
  placement caveat already governing that tree.
- **No code, API, or database change is made or implied by this ADR.**
  Implementation remains fully unscheduled; MVP-6's dependency on MVP-2/
  MVP-3 (both DONE) is unaffected.
- Q76 (Reporting) format/catalogue/storage-shape questions remain open —
  not addressed, not implied resolved, by this record.

**Consequences of the 2026-09-15 Amendment above:**
- `EMS-REQ-094` gains a dated clarification note (not a rewrite) in
  `functional-requirements.md`, distinguishing genuinely raw telemetry
  from the Energy chart's own already-displayed series.
- `requirements-traceability.md` gains a new §12 recording the amendment
  and the corrected implementation, without altering §6/§11's own
  historical snapshots.
- `information-architecture.md` and `docs/07-features/energy/README.md`
  gain corrections noting the summary-row interpretation is superseded
  for Energy's contextual export specifically.
- Still **no** code, API, or database change beyond the Energy contextual
  export's own CSV-building logic — the amendment authorizes no new
  endpoint, and Demand/PQ/dedicated-area/background-delivery remain
  exactly as unimplemented as before.

## Evidence / references

- Workshop baseline §107 (Q75) — [../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md)
- MVP-6 discovery report and Product Decision Workshop brief — produced
  2026-09-14 in-session (not a separately committed file; this ADR is the
  durable record of the decisions that discovery surfaced as open
  questions and this workshop resolved), per the same evidentiary pattern
  already used by [ADR-009](ADR-009-slice-c-historical-reference-methodology.md)
  and [ADR-010](ADR-010-mvp3-attention-materiality-policy.md) for
  decisions made in an uncommitted decision pack / session record.
- [01-product/roadmap.md](../../01-product/roadmap.md) MVP-6 entry.

## Implementation references

Energy contextual export only (`web/src/energy/energyExportCsv.ts`,
`web/src/export/downloadCsv.ts`, wired into
`web/src/routes/energy/EnergyOverview.tsx`). First implemented
2026-09-15 as a single period-summary row (superseded interpretation);
corrected 2026-09-15, per the Amendment above, to one row per
`current.series` chart point. Demand, Power Quality, the dedicated
Export area, and size-tiered delivery remain unimplemented. See
[requirements-traceability.md §11](../../02-requirements/requirements-traceability.md)
(original implementation) and
[§12](../../02-requirements/requirements-traceability.md) (chart-data
correction) for the full record.

Formula-injection protection (issue #124, 2026-10-10; implementation
hardening, not a scope change): every cell passes through
`web/src/export/spreadsheetSafety.ts` before CSV escaping, so a text value
such as `site_name` or `site_code` that starts with `=`, `+`, `-`, `@`, a tab
or a line break is prefixed with `'` (CWE-1236). Numeric cells, including the
`.toFixed(1)` strings such as `-3.5`, are never prefixed. The column set is
unchanged. The Analytics CSV (ADR-022, F7) uses the same helper.

Reports-tab site measurement export (Amendment 2): `postgres/migrations/309_report_export_jobs.sql`,
`app/src/report_export_service.py`, `app/src/report_export_worker.py`,
`app/src/routers/report_exports.py`, `web/src/routes/reportExports/ReportsPage.tsx`,
`web/src/reportExports/`.

## Validation references

Frontend test suite, `tsc --noEmit`, `eslint --max-warnings 0`, and
`vite build` all pass for the corrected implementation (see
requirements-traceability.md §12 for counts). Not deployed to staging or
production; no live end-to-end validation performed.


## Amendment 3 (2026-10-24) — asset selection and 14-day 1-minute exports

**Source.** Product request in the 2026-10-24 engineering session: the
Reports tab must download 1-minute data for up to 14 days; if that is too
much data, provide an asset selection like the Analytics tab's, limited to
10 assets.

**Analysis (staging, read-only, 2026-10-24).** Coimbatore has 32 assets
with ~49 columns each: a whole-site 14-day 1-minute export is ~32 M cells,
so selection is required. Independently of size, the 1-minute read path
was the bottleneck: the generic Analytics read probes
`telemetry.normalized_points` by `(logical_point_id, time)` and did not
finish 9 points x 1 day in 90 s; reading each device once on the existing
`(device_id, event_time)` index served all 58 points of a meter for 14
days in 2.9 s. Separately, 1-minute exports of metered assets failed on
register points (Apparent Energy) that have no 1-minute source.

**Decision.**

1. An export covers a selection of at most 10 assets of a site (the
   Analytics asset selector; a site with no more than 10 assets starts
   fully selected). A request without a selection covers the whole site
   and is held to the same maximum. A background job stores its selection.
2. An export serves 1 minute for up to 14 days (other resolutions keep the
   ADR-019 / Analytics windows).
3. At 1 minute, measurement columns come from a dedicated device-keyed,
   portal-scoped read (migration 312) with the Analytics 1m value rules;
   System Energy from the persisted Energy tier. Register points other than
   System Energy are not 1-minute columns.
4. The background size limit is raised to 20 M cells so that the largest
   allowed export is accepted; no new index.

**Consequences.** A 10-asset, 14-day 1-minute export is a background job of
roughly 12 M cells and tens of MB of ZIP. The Analytics page is unchanged
(still 3 days at 1 minute); whether it should use the device-keyed read is
a separate question.
