# Feature: Analytics (v1)

Status: DECIDED (UI decisions recorded 2026-09-29), implementation in progress · Owner: Product ·
Decision record: [ADR-022](../../00-governance/decisions/ADR-022-analytics-v1-scope-and-contract.md)

## Purpose

Analytics is the INVESTIGATE stage ("Why is this happening?") of the EMS Web
App: a **curated, semantic Trends explorer** over a single site. The customer
selects Assets and semantic Data Points from the site's confirmed
asset-point catalogue, a shared date/time range and a resolution, and reads
them on one chart with a per-series statistics table and a CSV download.

It is not a raw-tag browser or a free-form query builder (EMS-REQ-901 and
EMS-REQ-903 remain NOT-IN-SCOPE), and it does not administer anything: no
"+ Add Meter" or other Administration App function appears on this page
(ADR-006).

## Source basis

Every requirement below is labelled by origin:

- **[C]** an existing committed decision (ADR, requirement or IA document);
- **[PO]** a Product Owner decision recorded in ADR-022;
- **[REF]** taken from the Product Owner's Analytics requirements PDF and
  confirmed by ADR-022 or not contradicted by any committed decision. The
  PDF is a temporary design reference: it is **not** committed to the
  repository and is not linked from here;
- **[IMPL]** an implementation rule chosen to satisfy the above. It can
  change without a product decision provided the requirement it serves is
  still met.

Items the Product Owner has not yet decided are listed under
[Open Product Owner questions](#open-product-owner-questions) and are not
stated as requirements anywhere in this document.

## Requirements

Catalogued in [functional-requirements.md](../../02-requirements/functional-requirements.md#analytics-v1-adr-022).
EMS-REQ-129 – EMS-REQ-139 refine EMS-REQ-037 (Trends, MUST).

| ID | Requirement | Origin |
|---|---|---|
| EMS-REQ-129 | Site-scoped Analytics page: a curated semantic Trends explorer. No site-name page header; the navigation entry opens Trends directly. | [PO] curated explorer, D32, D81 · [C] EMS-REQ-037, Q62 site context |
| EMS-REQ-130 | Asset selection: only ACTIVE assets that have at least one catalogue data point; search by name; Select All / Clear All; group by Space (default; "Unassigned" at the bottom) or Asset Type ("Other"); group checkboxes; groups collapsed by default; selected count; at most 10, filled in the current visual order. | [REF] controls · [PO] ACTIVE only, 10 assets, D37, D38, D44, D65, D71, D72 |
| EMS-REQ-131 | Data point selection: semantic data points from the confirmed `asset_points` catalogue only, independent of the assets; organizational groups without group checkboxes, collapsed by default; search; Select All / Clear All; count; at most 5 distinct data points. "Energy" and "Energy Export" are separate data points. | [REF] controls · [PO] 5 points, Energy directions, D39, D42, D59, D66, D67, D73, D75 · [C] ADR-018 decision 1 |
| EMS-REQ-132 | Phase selection: System (default) or 3 Phase. 3 Phase expands a data point into phase series (P1–P3, E1–E3, Ex1–Ex3 …); without per-phase values the System value is shown under the normal name; qualifiers are never shown. | [REF] · [PO] D53–D58, D63, D74, D83 |
| EMS-REQ-133 | Shared date/time range: two-month calendar; quick ranges Today, 7 Days, 30 Days, 3 Months, 1 Year (calendar-based, application-wide, Sunday week start); date-first with an optional time-of-day refinement that a quick range resets; Apply / Cancel / click-outside to close; the chart reloads only on **Update**; selectable dates bounded by data availability. All ranges are site-local (site IANA timezone, DST-correct). | [REF] controls · [C] ADR-019 time basis · [PO] D8, D10–D15, D60–D62, D76 |
| EMS-REQ-134 | Resolution: exactly one of Auto (default), 1 minute, 15 minutes, 30 minutes, 1 hour, 1 day. Auto and the per-resolution maximum windows follow ADR-019; options whose maximum window the range exceeds are unavailable. 30 minutes and 1 hour are on the site-local grid (superseding "1 hour is on the UTC grid"); 1 day is the site-local calendar day. Auto never selects a resolution whose retention floor is after the range start. | [REF] options, Auto default · [C] ADR-019 · [PO] site-local 30m/1h (D24, supersedes 1h UTC grid), 1d required in v1 |
| EMS-REQ-135 | Chart: Energy as grouped bars, every other data point as a line; one Y axis per unit, auto-scaled; visual-only drag-to-zoom, "show all" reset and a two-handle range slider; a legend entry per rendered series; a selected series with no data is omitted; at most 25 rendered series. | [REF] chart behaviour · [PO] grouped bars, 25 series, D6, D26 |
| EMS-REQ-136 | Statistics table: one compact table, one row per rendered series, with Total (Energy only), Average, Minimum and Maximum (Min/Max with site-local times); full applied range. No cross-asset aggregate totals. | [PO] D19–D21, D26 |
| EMS-REQ-137 | CSV download: full applied range; wide format, one row per timestamp with site-local and UTC timestamps and one column per rendered series; missing values and no-data series blank; filename with the site name. Generated client-side. | [REF] download · [C] ADR-014 export pattern · [PO] D28–D31, D77 |
| EMS-REQ-138 | Data quality and coverage: every bucket carries its interval counts, bucket and data state and evidence flags (business rule 11; the per-bucket coverage ratio was removed); a Data quality section lists conditions in seven fixed groups; a selection with no data, or no longer available, is omitted from the chart and listed under "Series not shown" with its reason, never dropped; the section is absent when nothing applies. | [C] ADR-011 · [PO] D6, DQ1–DQ23 |
| EMS-REQ-139 | Chart options: CSV download and collapse-to-header only. No Administration App functionality on this page. | [REF] · [C] ADR-006 |

**Out of scope for v1** [PO]: Environmental / Space data
(`metadata.space_points`); cross-asset aggregate statistics; stacked Energy
bars; Comparison (shown as a disabled placeholder [REF]); cost. The PDF's
"Misc/Other" data-point section is a placeholder only [REF].

## User experience

The screen specification. Every rule below is a Product Owner decision
recorded in [ADR-022](../../00-governance/decisions/ADR-022-analytics-v1-scope-and-contract.md) Amendments 2, 3, 5 and 6; the numbers in brackets
(D1–D84, DQ1–DQ23) are the Product Owner's decision numbers.

**General rule** (2026-09-29): a conditional section, group, indicator or
message is shown only when it has useful content; otherwise it is absent.

### Page, navigation and filter panel

- The Analytics navigation entry opens Trends directly; there is no Trends
  sub-item (D81).
- No site-name page header; the site comes from the global site selector
  (D32).
- Main area, top to bottom: chart card, **Statistics**, **Data quality**
  (D19). Chart card title "&lt;N assets | asset name&gt;, &lt;range&gt; –
  &lt;resolution&gt;, &lt;phase&gt;" [REF].
- Right-hand filter panel, visible by default, collapsible with **Hide
  Filters** / **Show Filters**, independent of the chart's collapse. Its
  collapsed state is not persisted: it is visible on every visit (D33, D34).
  On narrow screens it is a drawer/overlay opened with **Show Filters** (D82).
- Filter order: 1 Update · 2 Assets · 3 Data points · 4 Resolution · 5 Phase
  type · 6 Comparison (D36). Comparison is visible, disabled and marked as
  unavailable in v1 with the text "Coming soon" (D52; wording approved
  2026-09-30).

### First load, return visits and site change

- **Every visit starts fresh** (D1, D3): range Today, resolution Auto, phase
  System, no assets, no data points, no chart request. Nothing from a previous
  visit is restored — an Analytics-specific exception to Workshop Q89.
- **Empty state** (D2): nothing is selected or suggested and no chart data
  loads. The page shows exactly:

  > **Select data to explore**
  >
  > Choose an asset and data point to get started.

- Statistics and Data quality are hidden until the first successful Update
  (D64).
- **Site change** (D35, D69): switch immediately and reset completely, as on
  a fresh visit, with the filters visible and Statistics and Data quality
  hidden. No Analytics state is carried across sites.

### Assets

- ACTIVE assets with at least one catalogue data point, listed directly in
  the panel: search, individual checkboxes, selected count (D37).
- Two views: **Group by Space** (default) and **Group by Asset Type**.
  Switching views never changes the selection. Assets without a Space are in
  an **Unassigned** group at the bottom; assets without an Asset Type are in
  an **Other** group, also at the bottom (position approved 2026-09-30).
  Groups are collapsed by default (D38, D65, D71, D72).
- Group-level checkboxes and **Select All / Clear All**. At most **10**
  assets, enforced while selecting. When a group selection or Select All
  would exceed 10, assets are selected top to bottom in the current visual
  order up to the limit, the rest stay unselected, the group checkbox shows a
  partial state and the UI indicates that the limit was reached (D5, D44,
  D65): "You can select up to 10 assets." (approved 2026-09-30).

### Data points

- The full site catalogue, independent of the selected assets; assets and
  data points can be selected in either order, and any combination may be
  chosen (combinations without data are handled after Update) (D4, D42, D43).
- At most **5** semantic data points, enforced while selecting; phase
  expansion does not count (D5, D66, D70). At the limit the UI shows "You can
  select up to 5 data points." (approved 2026-09-30).
- Groups are organizational only: collapsed by default, **no** group-level
  checkbox; **Select All / Clear All** and search (D39, D59, D66).
- Groups and members (D67, as revised by D75). A group appears only where
  the catalogue has points for it; theoretical, device-profile, Grafana,
  Eniscope-only or unavailable points are never shown (D40, D66).
  - **Frequently Used** (fixed, not personalised; selecting an item selects
    the same underlying point): Current; Energy; Power; Power Factor; Voltage.
  - **Power:** 1/2 Phase Angle; 1/3 Phase Angle; Amp Hour; Apparent Energy;
    Apparent Power; Apparent Power Peak; Current Peak; Export Energy;
    Frequency; Line to Line Voltage; Line to Line Voltage Peak; Maximum System
    Current Total Harmonic Distortion; Neutral Current; Reactive Energy;
    Reactive Export Energy; Reactive Power; Reactive Power Peak; Total
    Harmonic Distortion. Energy and Energy Export belong here, not in a
    separate Energy group.
  - **Input/Output:** Analog Input; Digital Input Counter; PIR; Pulse; Time
    Since Last Count Event; Time Since Last Pulse Event.
  - **Environmental:** Light Level; Relative Humidity; Temperature
    (Temperature is not in Frequently Used).
  - **Conversion:** BTU; Carbon.
  - **Misc/Other:** Battery Voltage; Flow Temperature; Signal Strength;
    Volume; Volume Flow.
- Customer labels: **Energy** (consumed/imported) and **Energy Export**
  (D73). The v1 registry serves only these two (business rule 2).

### Resolution and phase type

- Options per EMS-REQ-134 (Auto default). When the range changes and a
  manually chosen resolution becomes unavailable, it switches to Auto with a
  small, non-blocking notice (D9, D68): "Resolution changed to Auto because the selected resolution is not available for this range."
- Phase type: **System** (default) and **3 Phase**, functional in v1 (D53,
  D54). "System" is the canonical system-level measurement; qualifiers such as
  TOTAL or AVG are never shown (D83). It resets to System on every visit and
  site change (D56).
- 3 Phase expands each selected semantic point (still one catalogue item)
  into phase series labelled P1–P3 (Active Power), I1–I3 (Current), V1–V3
  (Voltage), PF1–PF3 (Power Factor), E1–E3 (Energy) and Ex1–Ex3 (Energy
  Export), named e.g. `Main Incomer - P1` (D55, D63, D74). Each phase series
  counts toward the 25-series limit (D70).
- Without per-phase values the System value is shown under the normal
  series name with no visible label; it is disclosed in Data quality
  ("Shown as System values") (D57, D58, D63).

### Date and time range

- Quick ranges, shared application-wide: **Today, 7 Days, 30 Days, 3 Months,
  1 Year**; no "Last 24 Hours" (D10, D61).
- Calendar semantics in the site's IANA timezone (D8, D11, D12, D61, D62):
  - Today = the whole current local day, local midnight to next local
    midnight (not shortened to "now").
  - 7 Days / 30 Days = today plus the preceding 6 / 29 local days.
  - 3 Months / 1 Year = the same day-of-month 3 months / 1 year back; when
    that month has no such day, its last valid day (31 May → 28 Feb; 29 Feb
    2028 → 28 Feb 2027).
  - The end is the exclusive next local midnight. The week starts on Sunday
    (D13).
- Date-first selection with an optional time-of-day refinement; by default
  local day start to next local day start. The refinement can be set to any
  minute (HH:MM; approved 2026-09-30). Choosing a quick range resets any
  time-of-day refinement (D60, revising D14). Two-month calendar with Apply /
  Cancel (D1, EMS-REQ-133).
- Display: inclusive dates, e.g. `01 Sep 2026 – 30 Sep 2026`; with a
  time-of-day refinement the time is shown under the date selector (D15,
  D76).
- The chart shows exactly the requested site-local range: never the UTC
  bucket grid or UTC-derived `:30` labels (D24, implemented by migration
  282); label density adapts to the range (D25). Future periods are shown
  empty (D16); the current in-progress period is shown (D17).

### Update, validation, loading and errors

- Changing a filter never reloads by itself; **Update** does. Update is
  enabled whenever there are unapplied changes, and a small **"Changes not
  applied"** indicator is shown until they are applied (D46, D47).
- Validation happens before any request, as one message beside/above Update
  (D48): "Select at least one asset and one data point to update the chart."
  / "Select at least one data point to update the chart." / "Select at least
  one asset to update the chart." More than 25 series after phase expansion:
  "You can display up to 25 series at a time. Reduce your selections and try
  again." (D45, D78). A failed validation keeps the selections as they are
  (D49).
- While loading, the current chart stays visible with a loading indication
  and is replaced only when the result is ready (D7).
- Request failure: the previous chart and the selections are kept, with
  "Unable to load selected data. Please try again." near Update; no technical
  details (D50, D80).
- Partial failure: whatever loaded is kept and the rest is reported in Data
  quality with "Some data could not be loaded for the selected range." (D51,
  D80). The series endpoint is currently all-or-nothing, so this cannot occur
  yet.

### Chart

- Energy as grouped bars, other data points as lines, one Y axis per unit
  (EMS-REQ-135). A legend entry per rendered series.
- A selected series with no data is omitted from the chart and the legend
  and reported in Data quality (D6).
- Two visual-only ways to explore: **drag-to-zoom** on the chart and a
  **two-handle range slider** (useful for long ranges such as 3 Months or 1
  Year). Both change only the visible window, never the applied range,
  Statistics or CSV; **Show all / Reset** restores the full applied range
  (D26; range slider decided 2026-09-29, EMS-REQ-135). Toolbar: **Export CSV** and **Collapse /
  Expand** only — no print, share or previous/next (D27).
- Tooltip: series name, value and unit, site-local date/time, and that
  period's Data quality lines in group order; no technical details (D22,
  DQ9). No quality marks on the chart; edge periods get no special treatment
  (D23).

### Statistics

- One compact table, one row per rendered series: **Series · Total (Energy
  only) · Average · Minimum · Maximum**, with Minimum and Maximum showing
  their site-local time beneath the value (e.g. `892.4 kW` / `14:15 · 10 Sep
  2026`). No cross-asset totals. Always the full applied range, never the
  zoomed window (D19, D20, D21, D26).

### Data quality

- Hidden until the first successful Update (D64). It describes the applied
  query: rebuilt on each successful Update (expansion reset), unchanged on a
  failed Update or while changes are not applied, fully reset on site change
  or a new visit (DQ9).
- **Absent when no condition applies** — no healthy statement (general
  rule, superseding DQ8's healthy statement). Each group appears only when
  its condition is present.
- **Fixed group order** (DQ9, DQ23): 1 Series not shown in chart · 2
  Incomplete data · 3 Meter resets and rollovers · 4 No recent data · 5
  Values after missing readings · 6 Reconstructed timing · 7 Shown as System
  values.
- **Expansion:** "Series not shown" is always expanded; the other groups are
  collapsed with heading and series count visible; a group that is the only
  one present is expanded. No truncation (at most 25 series). Within a group
  series follow the Statistics order ("Series not shown": selection order).
  A series not shown appears only in that group; a charted series can appear
  in any of groups 2–7 (DQ9).
- **Semantics** (DQ1–DQ7): Incomplete = at least one expected, elapsed
  interval with no accepted reading (missing or rejected), zero tolerance;
  reconstructed intervals count as accounted for; the device's first-ever
  `INITIAL` reading, unassigned periods, periods before the first or after the
  latest data, future periods and the stale tail are not expected. "No recent
  data" is data latency (business rule 12), not device connectivity. The
  value where readings resume after a gap carries a timing disclosure, not
  Incomplete.
- **Wording.** Vocabulary is "readings" and "periods", never internal terms.
  Durations = intervals × the site's capture interval, two largest units
  ("2 h 15 min"). Times are site-local, `h:mm · DD Mon YYYY`. A period range
  reads "{time} – {time} · {k} periods" (single: "{time} · 1 period").

| # | Group heading | Explanation | Per series | Tooltip |
|---|---|---|---|---|
| 1 | **Series not shown in chart** · {n} | — | Series name and one reason line (table below) | — |
| 2 | **Incomplete data** · {n} series | "Data is incomplete for the selected range. Some expected meter readings were not received or could not be used." Energy series only, also: "Energy used while readings were missing can appear in the next value after readings resume. Energy from readings that could not be used is not included." | "Not received: {duration}" · "Could not be used: {duration}" (each only when above zero); period range | "Incomplete: some readings not received" / "…could not be used" / "…not received or could not be used" / "Incomplete: no readings received" / "Incomplete: readings could not be used" |
| 3 | **Meter resets and rollovers** · {n} series | "The meter's cumulative Energy register changed unexpectedly or rolled over during the selected range. Energy values around these events may be affected." | "Meter reset · {date/time}" · "Meter rollover · {date/time}" | "Meter reset" · "Meter rollover" |
| 4 | **No recent data** · {n} series | "The latest available data for these series is older than expected. The chart has no values after the time shown." | "Latest data: {h:mm · DD Mon YYYY}" · "{duration} before the chart was updated" | Elapsed periods after the latest data: "No data available after {h:mm · DD Mon YYYY}" |
| 5 | **Values after missing readings** · {n} series | "After missing readings, the next value includes Energy used while readings were missing. It is shown in the period when readings resumed, because when that Energy was used is not known." | Period range (no duration or kWh) | "Includes Energy used while readings were missing" |
| 6 | **Reconstructed timing** · {n} series | "Some Energy values are reconstructed when valid meter data arrives late or after a data gap. Totals come from the meter; only the timing is reconstructed." (D79) | "Timing reconstructed: {duration}"; period range; no kWh | "Timing reconstructed" |
| 7 | **Shown as System values** · {n} series | "3 Phase is selected, but per-phase values are not available for these series. Their System values are shown." | Series name only | — |

- **"Series not shown in chart" reasons** (approved 2026-09-29). Always
  expanded; each affected series appears once, in selection order; internal
  status and reason codes are never shown.

  | API status / reason | Reason line |
  |---|---|
  | `NO_DATA` / `NOT_ASSIGNED_IN_RANGE` | "This data point was not assigned to the asset during the selected range." |
  | `NO_DATA` / `RANGE_IN_FUTURE` | "The selected range is in the future." |
  | `NO_DATA` / any other reason (`NO_DATA_EVER`, `RANGE_BEFORE_DATA`, `RANGE_AFTER_LATEST_DATA`, `NO_DATA_IN_RANGE`) | "No data available for the selected range." |
  | `NOT_AVAILABLE` | "This selection is not available." |
  | `RESOLUTION_UNAVAILABLE` / `BEFORE_RETENTION_FLOOR` | "Data is not available at this resolution for the full selected range. Data is available from {date}." ({date} = `resolution_available_from`, site-local) |
  | `RESOLUTION_UNAVAILABLE` / `CAPTURE_INTERVAL_TOO_COARSE` | "Data is not available at the selected resolution for this site." |
  | `DATA_UNAVAILABLE` / `CAPTURE_POLICY_GAP` | "Data is unavailable for part of the selected range." |
  | `DATA_UNAVAILABLE` / `CAPTURE_POLICY_CHANGE` | "Data availability changed during the selected range." |
  | `DATA_UNAVAILABLE` / `TIMEZONE_MISMATCH` | "Daily data is not available consistently for the selected range." |

- Reset and rollover events share group 3 and never show reason codes or
  register values (DQ23). Reconstructed timing stays inactive while
  reconstruction is OFF (ADR-020 PR3); values after missing readings are
  active today. Stale and Incomplete never count the same period.

### CSV

- Always the full applied range, independent of zoom (D28).
- Wide format: one row per timestamp; columns `Timestamp local`, `Timestamp
  UTC`, then one column per rendered series, e.g. `Chiller 1 · Active Power
  (kW)`. Missing observations are blank, not zero; a selected series with no
  data stays as a blank column (D29, D30, D77).
- Filename with the normalized site name, e.g.
  `Radisson_Blu_analytics_27-Sep-2026_to_30-Sep-2026.csv` (D31).

## Business rules

1. **Catalogue source.** A data point is available for an asset only when a
   currently effective `metadata.asset_points` row binds it (ADR-018
   decisions 1, 2, 11). Device capability, device profile, `PRIMARY_METER`
   and the Grafana selector view are never used.
2. **Curation.** Only logical points mapped to a semantic parameter
   (`metadata.logical_points.parameter_id`) and listed in the Analytics
   data-point registry appear. v1 registry: `ENERGY_IMPORT`, `ENERGY_EXPORT`
   [IMPL]. Further entries require an open question to be resolved (see
   question 2).
3. **Lifecycle.** Only `ACTIVE` assets appear [PO].
4. **Parity-bridge rows.** The staging-only parity-bridge assignments
   (`effective_from = '-infinity'`) are catalogue-eligible for development
   and testing but are not commissioning. The read model classifies each
   assignment internally as `CONFIRMED` or `PARITY_BRIDGE`; the customer
   API never exposes that classification [PO]. Analytics never modifies
   `asset_points`.
5. **Explicit selections.** A request names each (asset, data point) pair;
   the server never forms a cross-product [PO]. Phase expands each pair into
   one series (System: `TOTAL`) or three (3 phase: `L1`, `L2`, `L3`). Under 3
   phase, a data point without per-phase values returns its System series
   [REF: the reference mockup shows single-phase assets as System series
   under 3 phase]. Energy is System-only in v1. The customer never sees
   qualifiers: System is shown as the normal series name and phases as P1–P3,
   E1–E3, Ex1–Ex3 etc. (D63, D74, D83; see User experience).
6. **Limits.** ≤ 5 distinct data points, ≤ 10 distinct assets, ≤ 25 series
   after phase expansion, enforced by the server [PO].
7. **Time basis.** Transport is UTC; presentation is site-local
   (ADR-019). A bucket that overlaps the requested range is returned whole,
   never clipped or re-bucketed (ADR-019 D4, applied to every resolution
   [IMPL]; since migration 282 the buckets are site-local, see rule 8).
   Every read in a request is evaluated at one `as_of` (the database clock,
   read once) [IMPL, migration 282].
8. **Resolution.** Auto: range < 5 days → 15m; < 30 days → 1h; otherwise 1d.
   Maximum windows: 1m 3 days; 15m 30 days; 30m 60 days; 1h 180 days; 1d 3
   years (ADR-019) [C]. 30m and 1h buckets are on the **site-local grid**
   (D24) [PO, migration 282]: they start on the site's local 30-minute/hour
   boundaries (identical to the UTC grid when the site's offset is a multiple
   of the width). The persisted UTC hourly tier serves 1h only where local
   hours are UTC hours; otherwise each hour is summed from its 15-minute rows.
   *(Superseded: "30m buckets are on the UTC grid" and "1h on the UTC grid",
   migration 280 / ADR-022 decision 9.)* A request that starts before the
   resolution's retention floor -- the earliest instant its Energy tier still
   holds, from the live retention policies (1m raw 1-minute, 15m/30m persisted
   15-minute, 1h persisted hourly, or the 15-minute floor where local hours are
   not UTC hours; the daily tier has none) -- is `RESOLUTION_UNAVAILABLE` with
   reason `BEFORE_RETENTION_FLOOR` and `resolution_available_from` rather than
   silently empty [IMPL, migrations 280/282]. **Auto is floor-aware**: when its
   window-based choice starts before that resolution's floor, the next coarser
   resolution that can serve it is used (1d as the last resort); an explicit
   resolution is never changed [IMPL, migration 282].
9. **1 day.** One bucket per site-local calendar day,
   `[local midnight, next local midnight)`, so a bucket is 23, 24 or 25
   hours on DST transition days. Derived from the 15-minute tier, which nests
   exactly in every IANA local day (ADR-019). Requires the site timezone to be
   immutable once telemetry exists (ADR-019 D2). For Energy, a day comes from
   the persisted daily tier once the daily pipeline has processed it (day end
   <= its `pipeline_state` checkpoint) and exactly one binding window covers
   it; otherwise -- including today, whose persisted daily row can be partial
   -- it is the day's attributed 15-minute rows summed [IMPL, migration 279].
10. **Aggregation.** Energy: kWh consumed per bucket (register delta from the
    persisted Energy tiers, ADR-020 semantics preserved); series Total is the
    sum of buckets. Other data points: bucket value is the exact mean
    (Σ sum ÷ Σ sample count over `GOOD` samples), with the bucket's minimum and
    maximum sample.
11. **Data quality evidence** [IMPL, migration 282; [ADR-022 Amendment 4](../../00-governance/decisions/ADR-022-analytics-v1-scope-and-contract.md#amendment-4-2026-09-29-data-quality-read-contract-migration-282)].
    *(Superseded: the per-bucket and summary `coverage_ratio` of migrations
    278/280 is removed.)* Per bucket and direction:
    - `bucket_state`: `COMPLETE` (ended at `as_of`), `IN_PROGRESS`, `FUTURE`;
      `is_partial` (= not `COMPLETE`) is kept for compatibility.
    - `data_state`, first match: `FUTURE`; `NOT_ASSIGNED` (no binding window
      overlaps the bucket); `BEFORE_DATA` (ends at or before `first_data_at`);
      `AFTER_LATEST_DATA` (starts at or after `last_data_at`); `MEASURED`
      (has a value); otherwise `GAP`.
    - Interval counts at the site's capture interval: `expected_intervals`
      (the bucket width), `assigned_expected_intervals` (only the part that is
      assigned, elapsed and between `first_data_at` and `last_data_at`),
      `valid_intervals`, `invalid_intervals` (rejected measured readings) and
      `reconstructed_intervals`. The device's first-ever reading, `INITIAL` by
      construction, is excluded from both the expected and the invalid count.
    - `evidence_flags`: every condition present (`INVALID_INTERVALS` only when
      `invalid_intervals > 0`, `RESET_DETECTED`, `GAPS_DETECTED`,
      `RECONSTRUCTED_TIMING`, `ROLLOVER_DETECTED`). `evidence_status` (the most
      severe, in the Energy tiers' precedence) is kept for compatibility.

    Energy evidence is **not** mapped onto the five-value lattice: the MVP-4
    decision pack keeps Energy evidence separate from it [C]. Non-Energy
    buckets will use the existing lattice `GOOD / GAP / ESTIMATED / INVALID /
    PARTIAL` ([terminology](../../01-product/terminology.md)).
12. **Data bounds and stale** [IMPL, migration 282]. Per series:
    `first_data_at` / `last_data_at` are the first measured interval start and
    the last measured interval end of the bound source(s) inside their binding
    windows (device-level bounds, exact while reconstruction is off).
    `stale` is a data-latency condition, not device connectivity: true when
    `as_of − last_data_at` exceeds capture interval + late-arrival tolerance
    (the site's capture policy in effect at `last_data_at`) + the live
    schedule interval of each forward stage on the site's Analytics path
    (normalization, energy routing, the `ca_energy_1min` / `ca_energy_5min`
    refresh and the 1- / 5-minute Energy job; an unscheduled stage still
    counts) + that path's CAGG end offset, while `last_data_at` is inside the
    requested range and a binding extends beyond `last_data_at` + threshold.
    With staging's current configuration this is 7 minutes (60 s capture,
    60 s tolerance) or 21 minutes (60 s, 900 s). The threshold is never
    returned. Only the ≤ 60 s and 300 s capture paths are verified; for any
    other capture interval (900 s) `stale` is null.
13. **Labels** [PO, D73]. Energy Import is labelled "Energy" (consumed /
    imported energy) and Energy Export "Energy Export", in the catalogue and
    the series.
14. **Reconstruction** stays OFF (ADR-020): `reconstructed_intervals` is zero
    and `RECONSTRUCTED_TIMING` never appears.

## API contract

Both endpoints are GET, portal-session authenticated, portal-user scoped
server-side, and return 404 for an inaccessible or unknown site
(ADR-007, `app/src/auth/authorization.py`: `/api/v1` is a GET-only surface).
422 uses the standard `{error, detail}` envelope.

### `GET /api/v1/sites/{site_id}/analytics/catalog`

```json
{
  "site_id": "uuid", "site_name": "Coimbatore", "site_timezone": "Asia/Kolkata",
  "limits": {"max_data_points": 5, "max_assets": 10, "max_series": 25},
  "resolutions": [
    {"resolution": "1m",  "max_window_seconds": 259200,   "default_window_seconds": 129600,   "available_from": "…Z|null"},
    {"resolution": "15m", "max_window_seconds": 2592000,  "default_window_seconds": 1296000,  "available_from": "…Z|null"},
    {"resolution": "30m", "max_window_seconds": 5184000,  "default_window_seconds": 2592000,  "available_from": "…Z|null"},
    {"resolution": "1h",  "max_window_seconds": 15552000, "default_window_seconds": 7776000,  "available_from": "…Z|null"},
    {"resolution": "1d",  "max_window_seconds": 94608000, "default_window_seconds": 47304000, "available_from": "…Z|null"}
  ],
  "assets": [{
    "asset_id": "uuid", "asset_name": "Chiller 1",
    "asset_type_id": "uuid|null", "asset_type_name": "Chillers (Central/Industrial)|null",
    "space_id": "uuid|null", "space_name": "string|null", "location_path": "string|null",
    "data_points": [{
      "data_point": "ENERGY_IMPORT", "label": "Energy",
      "category": "Energy", "unit": "kWh",
      "chart_kind": "bar", "aggregation": "sum",
      "phases": {"system": true, "three_phase": false},
      "available_from": "…Z|null", "available_to": "…Z|null"
    }]
  }]
}
```

Only ACTIVE assets with at least one registry data point are listed.
`available_from` / `available_to` bound the data the asset has for that data
point across all of its bindings (null = no data yet); the date picker uses
them (EMS-REQ-133). `resolutions[].available_from` is each resolution's
retention floor for this site (null = none); for 1h at a site whose local
hours are not UTC hours it is the 15-minute floor [migration 282].

### `GET /api/v1/sites/{site_id}/analytics/series`

Query: `from`, `to` (ISO-8601 UTC, half-open), `resolution`
(`auto|1m|15m|30m|1h|1d`), `phase` (`system|three_phase`), and one
`selection=<asset_id>:<DATA_POINT>` per selected pair (repeated).

```json
{
  "site_id": "uuid", "site_timezone": "Asia/Kolkata", "as_of": "…Z",
  "from": "…Z", "to": "…Z", "requested_resolution": "auto", "resolution": "1h", "phase": "system",
  "series": [{
    "asset_id": "uuid", "asset_name": "Chiller 1",
    "data_point": "ENERGY_IMPORT", "label": "Energy", "qualifier": "TOTAL",
    "unit": "kWh", "chart_kind": "bar", "aggregation": "sum",
    "status": "OK", "status_reasons": [], "resolution_available_from": null,
    "first_data_at": "…Z", "last_data_at": "…Z", "stale": false,
    "points": [{"bucket_start": "…Z", "bucket_end": "…Z", "value": 12.4,
                "min": null, "max": null,
                "bucket_state": "COMPLETE", "data_state": "MEASURED",
                "expected_intervals": 60, "assigned_expected_intervals": 60,
                "valid_intervals": 59, "invalid_intervals": 1, "reconstructed_intervals": 0,
                "evidence_flags": ["INVALID_INTERVALS"], "evidence_status": "INVALID_INTERVALS",
                "quality": null, "is_partial": false}],
    "summary": {"total": 298.1, "average": 12.4, "min": 3.2, "min_at": "…Z",
                "max": 20.9, "max_at": "…Z"}
  }]
}
```

- One series per selection, in request order; every bucket of the grid is
  returned (empty buckets have `value: null`). Bucket and series fields are
  defined in business rules 11 and 12.
- `status` and `status_reasons` [migration 282]:
  - `OK`.
  - `NO_DATA` (selection valid, no value in range), with one reason, first
    match: `NOT_ASSIGNED_IN_RANGE`, `NO_DATA_EVER`, `RANGE_IN_FUTURE`,
    `RANGE_BEFORE_DATA`, `RANGE_AFTER_LATEST_DATA`, `NO_DATA_IN_RANGE`.
  - `NOT_AVAILABLE` (asset not an ACTIVE asset of this site, or data point not
    in that asset's catalogue — indistinguishable by design, so nothing leaks
    across tenants); no reasons.
  - `RESOLUTION_UNAVAILABLE`: reason `BEFORE_RETENTION_FLOOR` (with
    `resolution_available_from`) or `CAPTURE_INTERVAL_TOO_COARSE`.
  - `DATA_UNAVAILABLE`: reasons `CAPTURE_POLICY_CHANGE`,
    `CAPTURE_POLICY_GAP`, `TIMEZONE_MISMATCH` (all that apply; any of them
    makes the series `DATA_UNAVAILABLE`).

  Unavailable series have no points.
- 3-phase fallback is `phase = three_phase` with a `TOTAL` qualifier (no
  separate field); Energy is System-only in v1.
- 422 codes (existing `/api/v1` codes reused where they exist):
  `invalid_selection`, `duplicate_selection`, `unknown_data_point` (not in
  the registry), `too_many_data_points`, `too_many_assets`,
  `too_many_series`, `invalid_resolution`, `invalid_phase`,
  `invalid_time_range`, `time_range_too_large`. The whole request is
  validated before any access check or read.
- Energy `min`/`max` per bucket are `null` (a bucket is a sum); series
  `summary.min`/`max` are the smallest and largest bucket values;
  `summary.average` is the mean of buckets with a value.
- All timestamps are UTC (ADR-019), independent of the database session
  timezone.

## Data / API dependencies

| Resolution | Energy (Import / Export) | Other data points |
|---|---|---|
| 1m | raw `v_energy_consumption_native` (60 s capture on every current site), only within raw retention | `telemetry.normalized_points` (`GOOD`), 90-day retention |
| 15m | persisted `analytics.energy_consumption_15min`; newer than its checkpoint, `v_energy_semantic_rollup_15min` (read through the bounded helper `analytics.energy_semantic_rollup_15min_range` since migration 283) | `analytics.point_telemetry_15m` |
| 30m | the 15-minute rows, summed per site-local 30-minute bucket | derived from `point_telemetry_15m` |
| 1h | site-local hours (migration 282): persisted `analytics.energy_consumption_hourly` (UTC hours) only where local hours are UTC hours; otherwise, and for newer hours and hours a binding changes inside, summed from 15m. Never the site-local `v_energy_reporting_hourly` | `analytics.point_telemetry_1h` |
| 1d | persisted `analytics.energy_consumption_daily` (site-local days, DST-exact); unprocessed days and days a binding changes inside are summed from 15m | new `analytics.point_telemetry_1d` (site-local days, from 15m), plus the open day from 15m |

Asset attribution for every row resolves through effective-dated
`metadata.asset_points` windows (ADR-018 Amendment 7).

Database reads: `analytics.get_portal_analytics_catalog` (migration 276),
`analytics.get_portal_analytics_energy_availability` (277, aligned with the
persisted tiers by 280: start from the daily tier, end at the latest persisted
15-minute or raw 1-minute bucket), the site-aware
`analytics.get_analytics_energy_resolution_floors(site, as_of)` (282; the
0-argument version from 280 remains) and
`analytics.get_portal_asset_energy_series(…, p_as_of)` (282, values as
279/281 — portal/organization scoped, **never keyed on the Grafana
organization mapping**). The
canonical-read-era `analytics.get_portal_analytics_energy_series` (278) is
dropped by 280; `analytics.get_canonical_energy_read` stays for Grafana and
the Asset View only ([ADR-022 amendment](../../00-governance/decisions/ADR-022-analytics-v1-scope-and-contract.md#amendment-1-2026-09-27-option-b--analytics-energy-from-the-persisted-tiers)).

## Implementation plan

| Step | Scope | Status |
|---|---|---|
| B0 | ADR-019 D2: block site timezone changes once a site has telemetry | Implemented (migration 275); deployed to staging 2026-09-27 |
| B1 | Catalogue read function + `GET …/analytics/catalog` | Implemented (migration 276, `app/src/analytics_trends_service.py`); deployed to staging 2026-09-27 |
| B1b | Data availability bounds per catalogue data point | Implemented for Energy (migration 277); deployed to staging 2026-09-27; non-Energy bounds come with B3 |
| B2 | Energy series + `GET …/analytics/series` | Implemented (migration 278); deployed to staging 2026-09-27; its Energy source replaced by Option B (below) |
| Option B | Persisted-tier Energy read, portal/organization scoped, not Grafana-keyed | Migration 279 **deployed to staging** 2026-09-27 (PR #85); staging parity gate PT-1–PT-11 passed with zero mismatches |
| 280 | Switch Analytics Energy to 279; drop 278's function; availability aligned; resolution retention floors | Deployed to staging 2026-09-27 (with 281: the 15-minute checkpoint is floored to the 15-minute grid) |
| 282 | Data Quality read contract ([ADR-022 Amendment 4](../../00-governance/decisions/ADR-022-analytics-v1-scope-and-contract.md#amendment-4-2026-09-29-data-quality-read-contract-migration-282)): `as_of`, site-local 30m/1h, interval counts, bucket/data state, evidence flags, status reasons, data bounds, stale, site-aware floors, floor-aware Auto, D73 labels, `coverage_ratio` removed | Deployed to staging 2026-09-29 (PR #90, `ea6892f`); latency addressed by 283–285 |
| 283 | Read latency, Option 1: the fresh 15-minute tail is read through `analytics.energy_semantic_rollup_15min_range` (the rollup view bounded to a whole-bucket UTC range before grouping, so chunk exclusion applies); results unchanged | Deployed to staging 2026-09-29 (`e6754de`, PR #91). Read-only validation: helper↔view parity on live data 0 differing rows; value and Data Quality snapshot 282→283 identical (140,132 rows, 36 columns); tail read pruned to the current chunk |
| 284 | Read latency, Option 2: the per-bucket Data Quality subqueries of 282 (NOT_ASSIGNED, the device-first INITIAL count, assigned expected intervals) are replaced by set-based, request-level computation (computed once per request and joined to the bucket grid); 7-argument API, Energy values, Data Quality semantics, 283's tail pruning, views, tiers, jobs and storage unchanged | Deployed to staging 2026-09-29 (`17b1843`, PR #92, deploy run 36541126955). Read-only validation: value and Data Quality snapshot 283→284 identical (140,132 rows, 36 columns); helper↔view parity still 0 differing rows; latency improved only about 10–25%, all resolutions remain above the 500 ms target |
| 285 | Read latency: `analytics.energy_direction_status` `RESET search_path`, so its IMMUTABLE `CASE` is inlined into the series read (was one function call per 15-minute row per direction); body, grants and the series function unchanged | Deployed to staging 2026-09-29 (`6b09475`, PR #93, deploy run 36551005201; checksum `926d7ae4…`). Read-only validation: 284→285 snapshot identical (140,132 rows, 36 columns); helper inlined (0 helper executions per 15m request, against 42,958); latency improved only about 0–10% (median) |
| B3 | Generic series path (1m / 15m / 30m / 1h) | Planned — returns `NOT_AVAILABLE` until non-Energy assignments exist |
| B4 | `analytics.point_telemetry_1d` persisted tier (job-built from 15m, upsert-only, 35-day reconcile, backfill, 8-year retention, compression after 90 days; ADR-019 D1/D5) and the 1d read path | Planned — must be live before the first `point_telemetry_15m` chunks age out of 120-day retention |
| F1 | Calendar quick ranges in the site timezone, application-wide (ADR-022 Amendment 5, D61/D62) | Merged to staging (PR #96, `a420a88`) |
| F2 | Analytics v1 API client (`getAnalyticsCatalog`, `getAnalyticsSeries`) | Merged to staging (PR #97, `11e8123`) |
| F3 | Page at `/features/analytics`, draft/applied state, Update, validation, loading and error behaviour | Merged to staging (PR #98, `feb7aec`) |
| F4 | Filter panel (Assets, Data points, Resolution, Phase type, Comparison placeholder) and the date/time range | Merged to staging (PR #100, `ffe3dcc`); assignment periods in the selector added by PR #105 (migration 288) |
| F5 | Chart card: multi-series chart, drag-to-zoom, range slider, Collapse / Expand | Merged to staging (PR #101, `6b9a805`) |
| F6 | Statistics table, Data quality section (seven groups), per-period Data quality lines in the chart tooltip | Implemented (branch `feat/analytics-f6-statistics-quality`); see "Frontend implementation notes (F6)" |
| F7 | CSV export (wide format, local + UTC timestamps, full applied range) and the toolbar's **Export CSV** | Planned |
| F8 | Verification of the finished page against staging data through the SSH tunnel | Planned |

### Frontend implementation notes (F6)

`web/src/routes/analytics/`: `analyticsStatisticsModel.ts` / `AnalyticsStatistics.tsx`,
`analyticsDataQualityModel.ts` / `AnalyticsDataQuality.tsx`,
`analyticsSeriesName.ts` (one customer-facing name for a series everywhere),
and per-bucket tooltip lines through `analyticsChartModel.ts` and
`ChartFrame`'s optional `notes`.

- **Statistics** shows the API's series `summary` as returned (Total for Energy
  only, Average, Minimum, Maximum with `min_at` / `max_at` in site-local time);
  nothing is computed in the browser. A value the API does not return is shown
  as "—". The Total column is shown only when an Energy series is charted
  (general rule). Values use the charts' existing two-decimal formatting; the
  value precision per data point is still undecided.
- **Data quality** follows the backend mapping of ADR-022 Amendment 6. Choices
  the specification leaves open, made here and open to Product Owner review:
  - Incomplete: a period's missing intervals are `assigned_expected_intervals`
    − (`valid_intervals` + `reconstructed_intervals`) − `invalid_intervals`;
    "could not be used" is `invalid_intervals`. Durations multiply the
    intervals by the capture interval, read per period as the period width ÷
    `expected_intervals` (the API does not return the capture interval).
  - Tooltip wording: no accepted reading and nothing rejected → "Incomplete: no
    readings received"; no accepted reading and nothing missing → "Incomplete:
    readings could not be used"; otherwise "Incomplete: some readings not
    received" / "…could not be used" / "…not received or could not be used".
  - A period range runs from the first to the last affected period's start
    time ("{time} – {time} · {k} periods"); the periods need not be contiguous.
  - No recent data and its tooltip appear only when `stale` is `true`
    (`null`, an unverified capture path, claims nothing).
  - A `DATA_UNAVAILABLE` series with several reasons shows one line, the first
    of: policy gap, policy change, timezone mismatch.
  - A selection the catalogue cannot serve (D4, never requested) is listed
    under "Series not shown in chart" with "This selection is not available."
  - Names fall back to the catalogue when the API returns no asset name or
    label, then to "Asset" / "Data point"; registry codes are never shown.
- **Tooltip**: each series' lines for the hovered period, in group order; a
  series with lines but no value (e.g. a period without readings) is listed
  without a value.
- Statistics and Data quality describe the applied query only: hidden until the
  first successful Update, kept while loading and after a failed Update, and
  rebuilt (expansion reset) on each successful Update.
- Not exercised against real data yet: meter resets / rollovers have no
  API-level test (Amendment 6), and reconstructed timing stays inactive while
  reconstruction is OFF. Partial failure ("Some data could not be loaded…",
  D51) cannot occur while the series endpoint is all-or-nothing.

## Pilot status

The pilot is Energy-only. On staging the catalogue is backed by the
staging-only parity-bridge assignments (54 assets on two sites — 53 ACTIVE,
1 DRAFT — Energy Import/Export only); the DRAFT asset is excluded by rule 3.
Production has no `asset_points` rows, so its catalogue is empty until the
Asset Data Point Assignment workflow is deployed and assets are commissioned
there.

**Blocked on the Asset Data Point Assignment workflow (ADR-018 Amendments
5–8):** every non-Energy data point, 3 phase selection, Power / Power Quality
grouping, and customer-meaningful data point names.

## Open Product Owner questions

Answered and removed (2026-09-29): Summary vs Individual tabs (one
per-series table, D21); the "System" qualifier (D83); Energy labels (D73);
presentation details — quick ranges and week start (D10, D13, D61), time
refinement (D60), controls (D27, D33), the "group by area" level (Space,
D65), quality on the chart (D23 and Data quality); production release gate
(not blocked; an empty production catalogue is acceptable, D84); the
"Series not shown" wording and the resolution auto-switch notice (approved
2026-09-29); the range slider (kept, visual-only, 2026-09-29).
Answered and removed (2026-09-30): the limit-reached wording ("You can select
up to 10 assets." / "You can select up to 5 data points."); the Comparison
placeholder text ("Coming soon"); the "Other" asset group's position (at the
bottom, D72); the time-of-day refinement's granularity (any minute, D60).

1. **Curated non-Energy registry.** Which parameters join the registry once
   assignments exist? Cumulative registers other than Active Energy
   Import/Export (apparent and reactive energy) cannot be shown as averages;
   they need a delta calculation first. Labels for non-Energy points are part
   of this question.
2. **CSV quality context.** Whether the wide CSV carries any coverage or
   quality information (EMS-REQ-137, ADR-014).
3. **Smaller open items:** "Export Energy" in the Power list (D67) versus
   "Energy Export" (D73); whether D73's platform-wide "Energy" replaces the
   customer term "Consumption" outside Analytics; phase labels for other
   quantities (D63); a hint near Phase type before Update when per-phase
   values are unavailable (DQ14).

## Validation

- B0: `app/tests/test_site_timezone_immutable_with_telemetry.py`, `app/tests/test_database_error_messages.py`.
- B1: `app/tests/test_analytics_catalog_read.py` (database read: lifecycle, effective-dating, parity-bridge classification, semantic-only, tenant isolation) and `app/tests/test_analytics_api_v1_analytics_catalog_routes.py` (route contract, registry filtering, no `attribution_basis` exposure).
- Energy read (migration 279): `app/tests/test_asset_energy_tier_read.py` (30) — tiers, checkpoint composition, DST, source boundaries, reconstruction, retention, unmapped organization, tenant isolation, exact parity with the canonical read. Staging parity gate PT-1–PT-11 (2026-09-27, read-only): zero mismatches over 112,806 15-minute buckets, 56,510 30-minute buckets, 28,387 hours, 1,448 days, 211,817 minutes and 318 fingerprints (details in the platform-manual change history).
- B1b/280: `app/tests/test_analytics_energy_availability_read.py` (278's function dropped; availability and floors contracts; floors equal the live retention policies; availability from the daily start to the raw tail, beyond raw retention, binding start, parity-bridge rows unchanged).
- B2/280: `app/tests/test_analytics_api_v1_analytics_series_routes.py` (validation, limits, statuses, Energy mapping, summary, retention floors) and `app/tests/test_analytics_api_v1_analytics_e2e.py` (HTTP to database with no data-layer mocking and **no Grafana mapping**: catalogue, every resolution agreeing on totals, UTC hour grid, IST days, 1m beyond raw retention `RESOLUTION_UNAVAILABLE`, tenant isolation).
- Full backend suite passed locally (1798 tests, 2026-09-27). Migration 280 deployed to staging 2026-09-27.
- 282: `app/tests/test_analytics_energy_series_data_quality.py` (18: IST local 1h equals its 15m rows with the UTC hourly tier unused, Kathmandu +05:45 30m/1h, DST days of 23/25 local hours, in-progress/future buckets, assignment boundaries, device-first vs later `INITIAL`, missing/rejected/gap and all-rejected buckets, stale at 7 and 21 minutes, policy at `last_data_at`, unscheduled stage, 900 s capture → null, site-aware floors, reconstruction off, tenancy, function security); `test_asset_energy_tier_read.py` values unchanged (tenant default UTC for hourly-tier composition; reasons now named); series route tests (reasons, NO_DATA reasons, one `as_of`, floor-aware Auto, evidence flags, bucket state, no `coverage_ratio`, 3-phase fallback); e2e (IST local hours, 1d, floors). Full backend suite 1835 passed locally (2026-09-29). Deployed to staging 2026-09-29.

- 283: `app/tests/test_energy_rollup_range.py` (5: helper security and inlinability, helper = view definition plus the bounded `WHERE`, series function = 282 with only the tail line changed, `bucket_start` pruning in the plan, helper rows equal the view's rows on all 43 columns for on-grid, off-grid, empty, infinite and no-data ranges, 1-minute and 5-minute native rows, and another organization's device). Existing Analytics suites pass unchanged in values. Full backend suite 1840 passed locally (2026-09-29). Staging (2026-09-29, after deployment of `e6754de`, read-only): helper↔view parity on live data for every bound device in both organizations — last 6 hours including the fresh tail, last 3 days, an off-grid range and an empty range — 0 differing rows in either direction; 282→283 snapshot (5 resolutions, 53 assets, fixed `as_of`) identical on all 140,132 rows and 36 columns; the tail read scans only the current `energy_consumption_1min` chunk via `(device_id, bucket_start)` (0.24 ms, against up to 1,565 ms per asset before).

- 284: new `app/tests/test_energy_series_set_based_quality.py` (3: set-based structure and unchanged security; property test installing migration 283's exact function as a session-temporary reference and comparing it with 284 on every row and column — 12 seeded scenarios × 5 resolutions × 3 `as_of` values, across UTC / IST / Kathmandu / London sites, 60 / 300 / 900 s capture, tier checkpoints, binding windows starting and ending mid-bucket, device replacement with the new device's first reading inside the range, separate import/export windows, a sub-bucket window, a never-reporting device, missing / gap / rejected minutes and a later INITIAL — 0 differences, every data state exercised; a check that the device-first reading is still subtracted once per containing binding window). A mutation check confirmed the property test detects deliberate changes to the assigned-interval, INITIAL and NOT_ASSIGNED logic. `test_energy_rollup_range.py`: its byte-for-byte pin of the series function to 282 plus one line is retired (superseded by the 283→284 parity test); it still checks the tail is read through the 283 helper. Full backend suite 1843 passed locally (2026-09-29). Staging (2026-09-29, after deployment of `17b1843`, read-only): function md5 `3f43cdae…`, security unchanged (SECURITY DEFINER, STABLE, owner `ems_admin`, pinned `search_path`, `ems_app`-only EXECUTE); 283 helper, view and `get_canonical_energy_read` fingerprints unchanged; reconstruction OFF; 283→284 snapshot (5 resolutions, 53 assets, fixed `as_of`) identical on all 140,132 rows and 36 columns; helper↔view parity on live data 0 differing rows in either direction.

- 285: new `app/tests/test_energy_direction_status_inlining.py` (5: helper attributes and grants, body byte-identical to 279; inlining shown by `EXPLAIN`; all 4,096 counter combinations including NULL; series parity against a non-inlinable reference over the 284 randomised scenarios and a GOOD / INVALID / RESET / GAPS / ROLLOVER scenario, mutation-checked). Full backend suite 1848 passed locally (2026-09-29).

- F6 (frontend): `analyticsDataQualityModel.test.ts` (durations, period
  ranges, every "Series not shown" reason, all seven groups in order with no
  internal codes in customer text, selection order including unserved
  selections, catalogue name fallback, incomplete counts and durations,
  Energy-only wording, resets/rollovers, stale only when `true`, System values
  only under 3 Phase, tooltip lines for every condition in group order);
  `analyticsStatisticsModel.test.ts` (rows in chart order, Energy-only Total,
  values never computed); `AnalyticsResultSections.test.tsx` (Statistics with
  site-local Min/Max times, Data quality expansion rules, a no-data series
  explained while left out of the chart, tooltip lines, and the page flow:
  hidden before Update, unchanged by draft edits, kept while loading and after
  a failure, replaced on the next Update, absent after a failed first Update).

## Release status

Not released to production. The backend (migrations 275–288) is deployed to
staging. The Analytics page is on staging through F5 (filters, date range,
chart); F6 (Statistics, Data quality, tooltip quality lines) is implemented
and awaiting review. Still open on the frontend: F7 (CSV export) and F8
(verification against staging data through the tunnel). Backend dependencies
still open: B3 (non-Energy series; until then the catalogue is Energy-only and
3 Phase has no per-phase data) and B4 (the daily persisted tier, required
before the first `point_telemetry_15m` chunks age out of retention).

## Known limitations

- ~~Hourly Energy in Analytics (UTC grid) differs from hourly Energy on the
  existing Energy screens (site-local hours) for half-hour-offset sites.~~
  Resolved by migration 282: Analytics 1h is site-local.
- Local 1h at a site whose local hours are not UTC hours is built from
  15-minute rows, so its retention floor is the 15-minute tier's; earlier
  ranges are `RESOLUTION_UNAVAILABLE` (Auto moves to 1d). Its latency over a
  180-day window has not been measured on staging.
- `stale` is null for capture intervals other than ≤ 60 s and 300 s (900 s
  path unverified).
- The device's first-ever `INITIAL` reading is identified as the device's
  earliest measured interval in the tiers; if that is not the true first
  reading, one genuine rejection in that bucket would be hidden.
- `first_data_at` / `last_data_at` are device-level; per-direction bounds are
  an ADR-020 prerequisite before reconstruction is enabled, as is telling a
  reconstructed gap end from an unreconstructed post-gap value.
- Zones with a 30-minute DST shift (Australia/Lord_Howe) are not exact for
  local 1h at the shift; no such site exists.
- Latency baseline of the Energy read on staging (one 10-asset request at
  each resolution's maximum window): 1m / 3 days 2.66 s; 15m / 30 days
  0.88 s; 30m / 60 days 0.67 s; 1h / 180 days 0.48 s; 1d / 3 years 0.36 s.
  1m, 15m and 30m exceed a 500 ms per-request target; not yet optimized.
- Staging after migration 282 (2026-09-29, same method): 15m / 30 days
  1.55–2.39 s; 30m / 60 days 1.66–2.20 s; 1h / 180 days (IST, local hours)
  1.68–2.93 s; 1d / 3 years 1.05–1.20 s.
- Read-latency work 283–285 (all deployed to staging 2026-09-29; values
  unchanged at each step). Benchmarks: Coimbatore IST, 10 assets, maximum
  windows, warm medians, each baseline taken just before its merge.
  - **283** (bounded fresh-tail read): the cold-cache spike is removed (15m
    first run 6.99 → 1.98 s); warm latency essentially unchanged (15m 1.78 →
    1.73 s; 1d 1.02 → 1.07 s).
  - **284** (set-based Data Quality work): about 10–25% (15m 1.56 →
    1.34–1.36 s; 30m 1.85 → 1.30–1.50 s; 1h 1.78 → 1.47–1.74 s; 1d 0.91 →
    0.73–0.76 s). A local benchmark had overstated the gain (15m 5.36 →
    0.77 s on an untuned test database).
  - **285** (status helper inlined): pooled medians 284 → 285 over 8–13 and
    22–27 runs: 15m 1.38 → 1.27 s (−8%); 30m 1.43 → 1.42 s; 1h 1.41 →
    1.27 s (−10%); 1d 0.75 → 0.85 s (noise). Fastest runs: 15m 1.30 → 1.12 s;
    30m 1.31 → 1.04 s; 1h 1.35 → 1.10 s; 1d 0.71 → 0.67 s.
- **Measured state after 285:** 15m, 30m and 1h about 1.1–1.4 s; 1d about
  0.7–0.85 s. **The 500 ms target is not met.** Staging is a 2-vCPU host
  shared with the application and live-telemetry containers; single runs
  vary by ±0.3–0.5 s, so medians of fewer than about 10 runs are unreliable.
- **Remaining cost (measured, read-only decomposition on 284):** structural.
  The read runs once per asset: a main query (planned per asset, about
  11–24 ms of planning each) plus about 10 small per-asset statements
  (binding windows, data bounds, stale). Inside the main query, bucket joins,
  sorts and the 34-column result scale with the window, not the data.
  Persisted tier and rollup reads are only about 2–4% of the time.
- **Decision (Product Owner, 2026-09-29): the 500 ms target is accepted as
  non-blocking.** The current implementation (283–285) is kept; the
  all-assets, set-based rewrite of the roughly 900-line series function (one
  query for every asset instead of the per-asset loop) and any further
  performance optimization are not pursued. That rewrite was only a proposal:
  never started, unmeasured, and never claimed to reach 500 ms. Performance
  work closes here; no production-readiness claim is made.
- The Asset View Energy tile still reads the canonical, Grafana-keyed Energy
  read; moving it is a separate, parity-gated change.

## Future scope

Spaces / Environmental analytics; Comparisons (EMS-REQ-038 / EMS-REQ-064);
cross-asset aggregate statistics; saved views.
