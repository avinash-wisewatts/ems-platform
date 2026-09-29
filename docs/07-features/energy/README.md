# Feature: Energy

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering
MVP stage: MVP-2 · Related requirements: [EMS-REQ-020, 021, 027, 031, 040](../../02-requirements/functional-requirements.md)

## Purpose

Answer "how much energy are we using, and is it normal?" — the first of
MVP's four core analytical questions (Workshop Q50).

## Requirements

[EMS-REQ-021](../../02-requirements/functional-requirements.md) (energy vs.
expected/baseline), [EMS-REQ-027](../../02-requirements/functional-requirements.md)
(period comparison), [EMS-REQ-031](../../02-requirements/functional-requirements.md)
(trend + spike inspection), [EMS-REQ-040](../../02-requirements/functional-requirements.md)
(Grafana numerical parity).

## User experience

[../../03-ux-and-design/information-architecture.md](../../03-ux-and-design/information-architecture.md)
§"Energy — Consumption": consumption total + comparison, trend at
appropriate resolution, top meter-role/system contribution. Graceful
degradation when a resolution tier isn't commissioned for a site (e.g.
`energy_consumption_5min` on a 60-second-capture site) — never an error.

## Business rules

Comparison basis (Workshop Q54/Q56): previous period, same period
previously, or a rolling historical average by default; configured
expectation where the customer has supplied one. **Expected performance is
a comparison concept, not a prediction concept** (Q55) — no adaptive/
predictive baselines in MVP. Any energy number shown must eventually carry
a Grafana parity commitment before Grafana's equivalent workflow retires
(see [ADR-008](../../00-governance/decisions/ADR-008-grafana-ops-role.md)).

**Time ranges** (2026-09-29, ADR-022 Amendment 5, D61/D62): the presets
Today, 7 Days, 30 Days, 3 Months and 1 Year are calendar ranges in the site's
timezone, from local midnight of the first day to the exclusive next local
midnight (7 / 30 Days = today plus the preceding 6 / 29 days; 3 Months / 1 Year
= the same day-of-month back, or that month's last valid day). The same
presets apply on Site Overview, Demand, Power Quality and the Main Dashboard.

**Typical historical consumption** ([ADR-009 Amendment 1](../../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md#amendment-1-2026-09-29-typical-reference-with-calendar-ranges)):
the selected calendar range stays authoritative for actual consumption; the
reference uses the nearest supported fixed window (1/7/30/90/365 days) ending
at the range's end; when the two durations differ, average consumption per
calendar day is compared instead of raw totals; Typical is never shown as
unavailable merely because the durations differ.

**Comparisons use only the elapsed portion** (2026-09-29): the displayed range
is unchanged, but unelapsed time is excluded from the previous-period,
same-period-last-year and Typical comparisons and from Energy Attention.
Previous-period and same-period-last-year compare the same elapsed duration on
both sides; Typical compares complete elapsed local days only, so Today has no
Typical comparison until the day is complete. "This period" still shows the
total recorded so far. Wherever a comparison covers only the matched elapsed
portion, it carries the site-local qualifier "Compared through {date/time}"
(e.g. "Compared through 00:00, 15 Jun") -- on the Energy comparison, the Site
Overview "vs. typical" figure and the Energy Attention trigger.

## Data / API dependencies

- `GET /api/v1/sites/{site_id}/energy/consumption` (`1h`/`1d`) — **LIVE**.
- `GET /api/v1/sites/{site_id}/energy/consumption/evidence` — **LIVE** (Slice C, PR #49).
- `GET /api/v1/sites/{site_id}/energy/consumption/typical-reference` —
  **LIVE** — the historical comparison surface (median of up to 8
  comparable windows, ≥70% coverage each). See
  [ADR-009](../../00-governance/decisions/ADR-009-slice-c-historical-reference-methodology.md).
- 5-minute/15-minute resolution tiers not yet exposed via the API, though
  the underlying aggregation exists (Workshop Q82).

## Architecture

[../../04-architecture/data-architecture.md](../../04-architecture/data-architecture.md);
[../../06-platform/telemetry/aggregation.md](../../06-platform/telemetry/aggregation.md)
(the 5-tier resolution ladder and why `_5min` can be legitimately empty);
[../../06-platform/telemetry/pipeline.md](../../06-platform/telemetry/pipeline.md)
(watermark/bounded-catchup mechanics).

## Validation

Underlying consumption data verified end-to-end on staging (raw ingestion
through 1-minute/15-minute/hourly aggregation to Grafana-facing views) for
a real 22-device fleet. Slice C (comparison) landed with 1,277 backend +
112 frontend tests passing. See
[../../08-verification/staging-validation.md](../../08-verification/staging-validation.md).

## Release status

**DONE** (2026-09-13). Consumption (PR #46), comparison/evidence (PR #49,
Slice C) all live on `origin/staging`.

**Export CSV (2026-09-15, Q75, MVP-6):** an "Export CSV" action was
added to this screen, client-side only (no new endpoint). It was first
implemented serializing a single period-summary row (total, comparison,
evidence, freshness) — **that interpretation is superseded.** Corrected
the same day, per an explicit Product Owner decision, to export one CSV
row per Energy Trend chart point (`current.series` —
`bucket_start`/`import_kwh`, at the chart's resolution), with the same
context (site/hierarchy, metric, unit, period, comparison, evidence,
freshness) repeated on every row. A null chart point is retained as its
own row with a blank value; a whole-period no-data range produces the
header plus one explicit no-data row. Implemented, tested, not yet
deployed to `origin/staging`. See
[functional-requirements.md §Export](../../02-requirements/functional-requirements.md#export),
[ADR-014's amendment](../../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md#amendment-2026-09-15--decision-1-narrowed-energy-chart-series-now-in-scope),
and
[requirements-traceability.md §12](../../02-requirements/requirements-traceability.md#12-status-update-2026-09-15--q75-energy-chart-data-export-decided-correcting-increment-1)
(§11 records the original, now-superseded, summary-row implementation).

## Known limitations

No tariff/cost schema exists anywhere — financial views on energy (cost-
to-date, EMS-REQ-025) are blocked on a genuine data dependency, not a
scope question (Workshop Q73/Q74).

**1 Year across 29 February — backend follow-up.** The 1 Year preset is
the same date one year back through today (D61/D62), so it spans 366
calendar days, or **367** when the interval contains 29 February. The API's
1-day serving limit is 366 days (`ENERGY_RESOLUTION_MAX_WINDOW["1d"]` and
`POWER_QUALITY_RESOLUTION_MAX_WINDOW["1d"]` in `app/src/analytics_api_service.py`,
mirrored in `web/src/time/ranges.ts`). Product Owner decision (2026-09-29):
keep the calendar semantics — no shortened range and no special 365/366-day
rule — and **extend the backend/API limit to the maximum calendar span the 1
Year preset produces (367 days)**. That backend change is a follow-up,
required before 29 February 2028. Until then, for every "today" from
29 Feb 2028 to 28 Feb 2029 the 1 Year preset reports the range as not
served, rather than being shortened.

**Energy CSV and the elapsed-portion comparison -- follow-up.** Since
2026-09-29 the Energy comparison value, difference and percentage cover only
the matched elapsed portion, qualified in the UI as "Compared through
{date/time}". The CSV export's `comparison_value_kwh`, `delta_kwh` and
`delta_percent` carry the same matched values, but the CSV schema is
unchanged and has no column stating the cut-off. Whether the export should
carry that context (an ADR-014 export-format change) is a separate follow-up.

## Future scope

Cost overlay, functional-category breakdown (blocked on PA-2), baseline/
expected-performance bands (Post-MVP, DDS Phase 13), multi-utility
monitoring (water/gas/thermal — schema exists, no loader).
