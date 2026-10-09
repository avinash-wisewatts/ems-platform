# ADR-022: Analytics v1 — scope, catalogue and series contract

Status: Decided (Product Owner, 2026-09-27; Amendments 1–6 to 2026-09-29); backend (migrations 275–285) deployed to staging; UI not implemented — see [Analytics feature](../../07-features/analytics/README.md#implementation-plan).
Date: 2026-09-27
Decision owners: Product Owner
Related requirements: EMS-REQ-037 (Trends, refined here), EMS-REQ-129 – EMS-REQ-139 (new, Analytics v1), EMS-REQ-901 / EMS-REQ-903 (unchanged exclusions).
Related features: [Analytics](../../07-features/analytics/README.md)
Related decisions: [ADR-007](ADR-007-analytics-api-boundary.md), [ADR-014](ADR-014-q75-export-scope-and-behavior.md), [ADR-018](ADR-018-asset-point-assignment-and-commissioning.md), [ADR-019](ADR-019-analytical-backbone-time-basis-and-tiers.md)

## Context

The EMS Web App shell has an "Analytics" navigation entry that routes to a
placeholder. The Product Owner supplied an Analytics requirements PDF with
mockups as a design reference. That PDF is a temporary, uncommitted artifact
and is not a repository document; its content is carried into committed
documentation only where the Product Owner has confirmed it (see the
Analytics feature document, which labels every requirement's origin).

A read-only reconciliation (2026-09-27) against `origin/staging` and the
staging database found:

- `metadata.asset_points` on staging holds 108 rows: `ENERGY_IMPORT_TOTAL` and
  `ENERGY_EXPORT_TOTAL` for each of the 54 assets that have a
  `PRIMARY_METER` relationship, on two sites. All were written in one
  statement at 2026-09-25 21:06:21 IST, 40 minutes before migration 263 was
  applied, with `effective_from = '-infinity'` and no `admin.onboarding_audit`
  entry. No committed migration, seed or application path writes them.
  Earlier statements that staging has 0 `asset_points` rows (ADR-018,
  change-history entry for migration 263) are stale.
- The Asset Data Point Assignment workflow (ADR-018 Amendments 5–8) is not
  deployed; no non-Energy point is assigned to any asset.
- ADR-019 D2 (block site timezone edits once a site has telemetry) is decided
  but not implemented: `admin.update_site_workspace` accepts any valid IANA
  zone at any time.
- The canonical Energy read's 1h tier (`analytics.v_energy_reporting_hourly`)
  buckets by site-local hour, while ADR-019 D3 puts 1h on the UTC grid.
- The `/api/v1` surface is GET-only by design
  (`app/src/auth/authorization.py`).

## Decision

1. **Reference material.** The Analytics PDF is not committed. Committed
   Analytics requirements live in the Analytics feature document and the
   requirements catalogue.
2. **Curated semantic explorer.** Analytics is a curated, semantic Trends
   explorer, not a raw-tag browser or free-form query builder (EMS-REQ-901/903
   unchanged). Users select Assets and semantic Data Points only from the
   confirmed `metadata.asset_points` catalogue (ADR-018 decision 1).
3. **Energy-only pilot.** An Energy-only pilot on the currently deployed
   Energy assignments is acceptable. Analytics implementation is not blocked
   on the full Asset Data Point Assignment workflow.
4. **Staging parity-bridge rows.** The 108 staging `asset_points` rows are
   staging-only parity-bridge assignments for development and testing. They
   are **not** completed commissioning. They must not be modified by
   Analytics work. Parity-bridge status is not customer-facing; an internal
   `attribution_basis` may exist in the read model only.
5. **Multi-type trends allowed.** Analytics Trends may combine assets of
   different asset types. The Post-MVP Comparisons fairness rule (EMS-REQ-038
   / EMS-REQ-064: comparisons only within one `asset_type_id`) governs the
   separate Comparisons capability and does not prohibit multi-type trend
   investigation.
6. **ACTIVE assets only.** The customer Analytics catalogue lists only assets
   with `lifecycle_status = 'ACTIVE'`. DRAFT and COMMISSIONING (and every
   other non-ACTIVE status) are excluded.
7. **Limits.** At most 5 distinct data points, 10 selected assets and 25
   rendered series per request.
8. **Energy directions.** Energy Import and Energy Export are separate
   selectable data points.
9. **1h basis.** Analytics 1h follows the UTC-grid contract (ADR-019 D3) for
   every data point, Energy included. Existing Energy screens (Main
   Dashboard, Asset View, Energy) are not changed by this work.
   **Superseded 2026-09-29 by [Amendment 4](#amendment-4-2026-09-29-data-quality-read-contract-migration-282):**
   Analytics 30m and 1h follow the site-local grid (Product Owner decision
   D24); the existing Energy screens are still unchanged.
10. **Asset-only v1.** Analytics v1 is Asset-only. Environmental / Space data
    (`metadata.space_points`) is out of scope for v1 and is not forced into
    the Asset contract.
11. **Per-series statistics.** Summary statistics are per
    asset × data point × phase series. No cross-asset aggregate totals in v1.
12. **Grouped Energy bars.** Energy is drawn as grouped bars, not stacked.
13. **1d required in v1.** 1-day resolution is required in Analytics v1, with
    proper site-local calendar-day semantics and DST handling. It is not
    deferred behind ADR-019 M3; the persisted generic 1d tier is part of the
    Analytics v1 plan.
14. **Explicit selections.** The series API takes an explicit list of
    (asset, data point) selections rather than independent asset and data
    point lists, so a request never produces an unintended cross-product.

## Rationale

Product Owner decisions, recorded 2026-09-27. Decisions 5, 9 and 11 resolve
conflicts the reconciliation surfaced between the PDF and committed IA / ADR
text. Decision 4 preserves ADR-018's distinction between confirmed
commissioning and an assignment made for another purpose.

## Alternatives considered

- Deriving the data-point list from device capability (the PDF's fallback):
  rejected by ADR-018 decision 1.
- Deferring 1d until ADR-019 M3: rejected by decision 13.
- Independent `asset_id[]` / `data_point[]` request arrays: rejected by
  decision 14.
- A POST request body for selections: not chosen at the implementation level,
  because `/api/v1` is a GET-only surface with no CSRF handling. Selections
  are carried as repeated query parameters instead.

## Consequences

- Production has no `asset_points` rows (decision 4 scopes the 108 rows to
  staging). Until the Asset Data Point Assignment workflow is deployed and
  real assets are commissioned there, the production Analytics catalogue is
  empty. See open question 6 in the feature document. *(Answered 2026-09-29 by
  [Amendment 5](#amendment-5-2026-09-29-analytics-ui-decisions-d3d84), D84: a
  production release is not blocked; an empty production catalogue is
  acceptable.)*
- Non-Energy data points, 3-phase selection and Power / Power Quality grouping
  remain blocked on the Asset Data Point Assignment workflow.
- ADR-019 D2 must be implemented before any persisted site-local-day tier
  (B0 in the feature plan).
- Analytics hourly Energy bars for half-hour-offset sites (all current sites
  are `Asia/Kolkata`) start on the half hour and differ from the site-local
  hourly bars on the existing Energy screens; daily totals are unaffected.
  **Superseded 2026-09-29 by [Amendment 4](#amendment-4-2026-09-29-data-quality-read-contract-migration-282)**
  (D24): Analytics 30m and 1h are on the site-local grid.

## Evidence / references

- Read-only staging verification, 2026-09-27 (image `5eb02ca`, ledger through
  migration 270): `metadata.asset_points` counts, provenance timestamps,
  `admin.schema_migrations`, `pg_get_viewdef('analytics.v_energy_reporting_hourly')`,
  `pg_get_functiondef('admin.update_site_workspace')`,
  `config.telemetry_capture_policies`, TimescaleDB chunk and policy metadata.
- `app/src/auth/authorization.py` (`/api/v1` GET-only surface).

## Implementation references

- B0: `postgres/migrations/275_site_timezone_immutable_with_telemetry.sql` (ADR-019 D2).
- B1: `postgres/migrations/276_analytics_api_catalog.sql`, `app/src/analytics_trends_service.py`, `GET /api/v1/sites/{site_id}/analytics/catalog`.
- B1b: `postgres/migrations/277_analytics_api_energy_availability.sql` (availability bounds per Energy data point, in the catalogue).
- B2: `postgres/migrations/278_analytics_api_energy_series.sql`, `GET /api/v1/sites/{site_id}/analytics/series` (explicit selections; Energy only; UTC-grid 1h; DST-correct site-local 1d).
- Amendment 1: `postgres/migrations/279_asset_energy_tier_read.sql` (deployed to staging, PR #85), `postgres/migrations/280_analytics_energy_persisted_tier_switch.sql` (deployed to staging 2026-09-27).
- Amendment 4: `postgres/migrations/282_analytics_energy_series_data_quality.sql`, `app/src/analytics_trends_service.py`, `app/src/routers/analytics_api.py` (deployed to staging 2026-09-29, PR #90).
- Amendments 2, 3, 5, 6: no code yet; the screen specification is the feature document's [User experience](../../07-features/analytics/README.md#user-experience) section.
- Remaining steps: [the Analytics feature document](../../07-features/analytics/README.md#implementation-plan).

## Validation references

Local only (2026-09-27): see the feature document's Validation section. Not deployed.

---

## Amendment 1 (2026-09-27): Option B — Analytics Energy from the persisted tiers

**Decision (Product Owner, 2026-09-27).** Customer Energy reads for Analytics
are keyed on the portal user and the asset's organization, never on
`metadata.grafana_organization_map`. Analytics Energy reads ADR-019's
persisted Energy tiers: `energy_consumption_15min` (15m; 30m derived from it),
`energy_consumption_hourly` (UTC hours), `energy_consumption_daily`
(site-local days) and raw 1-minute data only within raw retention.
**Superseded 2026-09-29 by [Amendment 4](#amendment-4-2026-09-29-data-quality-read-contract-migration-282)
for 1h:** Analytics 1h is on the site-local grid; the UTC-hour
`energy_consumption_hourly` rows serve it only where the site's local hours
are UTC hours, otherwise each local hour is summed from its 15-minute rows.

**Why.** A read-only investigation found that `analytics.get_canonical_energy_read`
— the source of the first B2 implementation — is keyed on the Grafana
organization mapping, which only Grafana provisioning writes (staging: 2
mappings for 3 organizations), and aggregates every tier at request time from
raw 1-minute/5-minute rows, so it cannot return anything older than raw
retention (180 days). Option A (an organization-keyed core inside the
canonical read) was rejected because it keeps both the retention limit and the
request-time aggregation cost.

**Delivery, parity-gated.**
1. Migration 279 — `analytics.get_portal_asset_energy_series`, additive.
   Deployed to staging 2026-09-27 (PR #85, `5ca62b0`). Read-only staging parity
   gate PT-1–PT-11 against the canonical read: zero mismatches at every
   resolution; the 108 parity-bridge rows unchanged.
2. Migration 280 — Analytics switches to 279 (the canonical-read-era Analytics
   series function from 278 is dropped); availability aligned with the same
   tiers; per-resolution retention floors make out-of-retention requests
   `RESOLUTION_UNAVAILABLE`. HTTP contract unchanged.

**Unchanged.** `analytics.get_canonical_energy_read`, every Grafana path and
the Asset View Energy tile; moving the Asset View off the Grafana-keyed read is
a separate, parity-gated decision.

---

## Amendment 2 (2026-09-27): Analytics UI Decision 1 — first load

**Context.** The committed decisions already fix the resolution default
(Auto, EMS-REQ-134 / ADR-019), reload on **Update** only and the date
picker's Apply / Cancel (EMS-REQ-133), explicit (asset, data point)
selections with no server-chosen series (decision 14), and site-local
presentation over a UTC API (ADR-019). ADR-019 defines per-resolution default
windows but not the Analytics page's initial range, and no committed rule
defined an initial series selection.

**Decision (Product Owner, 2026-09-27).** When a user arrives on the
Analytics page:

1. **Initial range** is the site's local **Today**: the current calendar day
   in the site's IANA timezone, DST-correct (ADR-019 time basis).
2. **Resolution** is **Auto**.
3. Auto resolves Today (a range under 5 days) to **15-minute** buckets.
4. **No series is selected.** No asset and no data point is pre-selected.
5. The page shows the Analytics empty state defined by
   [Amendment 3](#amendment-3-2026-09-27-analytics-ui-decision-2--empty-state).
6. A series is selected only by an explicit user action.
7. **The chart does not load on page arrival.** No series request is made
   until the user presses **Update**.
8. The date picker keeps **Apply / Cancel**.

No "main asset" or other default-asset rule is implied, and none is taken
from the Analytics reference PDF's mockups, which do not override the
committed IA and ADR decisions.

**Consequences.** The Today range depends on the site-local day
computation, so the frontend defect ADR-019 records in
`web/src/time/ranges.ts` (`resolveRange("TODAY")` uses UTC midnight) must be
fixed before or with the Analytics page (feature plan step F1). This
amendment makes no API, migration or backend change.

*Recorded first on PR #89 (not merged); carried here unchanged except for
the information-architecture reference in Amendment 3.*

---

## Amendment 3 (2026-09-27): Analytics UI Decision 2 — empty state

**Decision (Product Owner, 2026-09-27).** When the Analytics page has no
selected series (including on first load, Amendment 2):

1. Nothing is selected.
2. Nothing is suggested.
3. No chart data is loaded.
4. The page displays exactly:

   > **Select data to explore**
   >
   > Choose an asset and data point to get started.

The user explicitly selects an asset and a data point, then presses
**Update**. This replaces the "prompt with suggested series" empty state of
the superseded product IA (`docs/99-archive/superseded-product/`); the
canonical [information architecture](../../03-ux-and-design/information-architecture.md)
and the feature document record the new empty state.

**Consequences.** No suggestion logic or suggestion source is needed. This
amendment makes no API, migration or backend change.

---

## Amendment 4 (2026-09-29): Data Quality read contract (migration 282)

Numbering note: Amendments 2 and 3 (Analytics UI decisions 1 and 2, first
load and empty state) are recorded above.

**Decision.** The Analytics series read returns the evidence the Data Quality
section needs, computed server-side from existing data, with no storage or
pipeline change. Product Owner decisions it implements: site-local time axis
(D24), customer Energy labels (D73), and the Analytics Data Quality decisions
1–22 (2026-09-28/29).

**What changes (implemented in migration 282 and the Analytics service):**

1. **One `as_of` per request.** The API reads the database clock once and
   passes it to every read; bucket state, data state, data bounds and stale
   are evaluated at it. `analytics.get_portal_asset_energy_series` gains a
   seventh argument `p_as_of` (the 6-argument function is dropped).
2. **Site-local 30m and 1h grid (D24).** Buckets start on the site's local
   boundaries. **This supersedes decision 9 (UTC-grid 1h) and ADR-019 D3/D4
   for the Analytics series.** The persisted UTC hourly tier serves 1h only
   where local hours are UTC hours; otherwise each hour is the sum of its
   15-minute rows (every IANA offset is a multiple of 15 minutes). Energy
   values are unchanged: the same rows are summed.
3. **Per bucket and direction:** `bucket_state` (`COMPLETE` / `IN_PROGRESS` /
   `FUTURE`), `data_state` (`MEASURED` / `GAP` / `NOT_ASSIGNED` /
   `BEFORE_DATA` / `AFTER_LATEST_DATA` / `FUTURE`), `expected_intervals`,
   `assigned_expected_intervals`, `valid_intervals`, `invalid_intervals`,
   `reconstructed_intervals` and `evidence_flags` (every condition present).
   The device's first-ever reading (`INITIAL` by construction) is excluded
   from both the expected and the invalid count. `evidence_status` and
   `is_partial` remain for compatibility. **`coverage_ratio` is removed**
   (bucket and summary).
4. **Per series:** `status_reasons`, `resolution_available_from`,
   `first_data_at`, `last_data_at` and `stale`.
5. **Stale** is a data-latency condition, not device connectivity: true when
   `as_of − last_data_at` exceeds capture interval + late-arrival tolerance
   (the site policy in effect at `last_data_at`) + the live schedule interval
   of each forward stage on the site's Analytics path + that path's CAGG end
   offset, while `last_data_at` is inside the range and a binding extends
   beyond it. The threshold is never returned. For capture intervals other
   than ≤ 60 s and 300 s (900 s) the path is unverified and `stale` is null.
6. **Resolution floors and Auto.** Retention floors are site-aware (for 1h,
   the 15-minute floor where local hours are not UTC hours), returned as
   `resolutions[].available_from` in the catalogue. Auto is floor-aware: when its window-based choice starts before that resolution's retention floor, the next coarser resolution that can serve it is used (1d as the last resort); an explicit resolution is never changed.
7. **Labels (D73):** "Energy" (consumed/imported) and "Energy Export".
8. **Reconstruction stays OFF.** Nothing reconstructed exists; the counters
   are present and zero.

**Unchanged.** Energy values and attribution, the canonical Energy read,
every Grafana path, the Asset View, the persisted tiers, their jobs and
retention.

**Evidence.** `app/tests/test_analytics_energy_series_data_quality.py` and the
updated Analytics tests; full backend suite 1835 passed locally (2026-09-29).
Deployed to staging 2026-09-29 (PR #90, `ea6892f`); read-only validation and
the read-latency follow-ups (migrations 283–285) are in the feature document.

---

## Amendment 5 (2026-09-29): Analytics UI decisions D3–D84

**Decision (Product Owner, 2026-09-27 to 2026-09-29).** The Analytics page
behaves as specified in the feature document's
[User experience](../../07-features/analytics/README.md#user-experience) section, which records every decision
with its number. In summary:

- **Fresh state** (D3, D35, D56, D69): every visit and every site change
  starts at Today, Auto, System, no selections and no request — an explicit
  exception to Workshop Q89's resume rule.
- **Selectors** (D4, D5, D37–D44, D59, D65–D67, D70–D72, D75): assets grouped
  by Space (default) or Asset Type, with group checkboxes, Select All / Clear
  All and a 10-asset limit filled in visual order; data points from the full
  site catalogue in organizational groups without group checkboxes, at most 5;
  25 rendered series after phase expansion, enforced on Update.
- **Time** (D8, D10–D17, D24, D25, D60–D62, D76): calendar quick ranges
  shared application-wide (Today, 7 Days, 30 Days, 3 Months, 1 Year; month-end
  rule; Sunday week start), date-first selection with optional time-of-day,
  the exact site-local time axis.
- **Phase** (D53–D58, D63, D74, D83): System and 3 Phase; phase series P1–P3,
  E1–E3, Ex1–Ex3 etc.; System fallback without a label; qualifiers never
  shown.
- **Query behaviour** (D6, D7, D9, D45–D51, D68, D78, D80): explicit Update,
  "Changes not applied", one validation message, the previous chart kept while
  loading and on failure, a small notice when an unavailable resolution
  switches to Auto.
- **Page elements** (D18–D23, D26–D34, D36, D52, D64, D77, D81, D82):
  Statistics then Data quality below the chart, hidden until the first
  Update; no site header; visual-only zoom; toolbar Export CSV and Collapse
  only; wide CSV with local and UTC timestamps; filter panel order and
  narrow-screen drawer; the navigation entry opens Trends directly.
- **Terminology** (D73): "Energy" and "Energy Export" (implemented in
  Amendment 4).
- **Release** (D84): production release is not blocked by an empty
  production catalogue.

**Supersedes:** the feature document's "&lt;site name&gt; Analytics" header
(EMS-REQ-129), asset-type default grouping and data-point group checkboxes
(EMS-REQ-130/131), inline no-data series (EMS-REQ-138), the long-format CSV
(EMS-REQ-137), and the open presentation questions they answered.

**Recorded 2026-09-29:** the resolution auto-switch notice ("Resolution changed to Auto because the selected resolution is not available for this range."); the
chart keeps a two-handle range slider alongside drag-to-zoom, both visual-only
(EMS-REQ-135).

**Still open:** the limit-reached wording, CSV quality context and the
smaller items listed in the feature document's open questions.

---

## Amendment 6 (2026-09-29): Data quality presentation (DQ1–DQ23)

**Decision (Product Owner, 2026-09-28/29).**

1. **Semantics** (DQ1–DQ7): stale is data latency, not connectivity;
   Incomplete is any expected, elapsed interval without an accepted reading,
   with zero tolerance, excluding only the device's first-ever `INITIAL`
   reading; the value where readings resume after a gap gets a timing
   disclosure, not Incomplete. The read contract (DQ15–DQ22) is Amendment 4.
2. **Presentation** (DQ8, DQ9, DQ23): conditions are shown as independent
   groups in a fixed order — 1 Series not shown in chart · 2 Incomplete data ·
   3 Meter resets and rollovers · 4 No recent data · 5 Values after missing
   readings · 6 Reconstructed timing · 7 Shown as System values. "Series not
   shown" is always expanded; other groups are collapsed unless only one is
   present.
3. **"Series not shown in chart"** · {n} (approved 2026-09-29): always
   expanded; each affected series once, in selection order; one customer
   reason line per status/reason as tabulated in the feature document; no
   internal status or reason codes.
4. **General rule:** a conditional section or group is shown only when it has
   useful content. When no condition applies the Data quality section is
   absent — this supersedes DQ8's single healthy statement.
5. **Wording** (DQ10–DQ14, DQ23, D79, D80): as tabulated in the feature
   document. Meter resets and rollovers share one group (DQ23). Reconstructed
   timing uses D79's text and stays inactive while reconstruction is OFF. This
   settles ADR-020's open "customer wording for reconstructed timing" for
   Analytics only.

**Backend mapping (read-only check, 2026-09-29):** group 2 from the bucket
counts (`assigned_expected_intervals`, `valid_intervals`, `invalid_intervals`,
`reconstructed_intervals`); group 3 from the `RESET_DETECTED` /
`ROLLOVER_DETECTED` evidence flags (no API-level test covers these two yet);
group 4 from series `stale` and `last_data_at`; group 5 from `GAPS_DETECTED`;
group 6 from `RECONSTRUCTED_TIMING`; group 7 from `phase = three_phase` with a
`TOTAL` qualifier; group 1 from series `status` / `status_reasons`.

---

## Amendment 7 (2026-10-09): Statistics semantics and F6 presentation decisions

**Decision (Product Owner, 2026-10-09, on the review of PR #112).**

1. **In-progress periods.** They stay visible in the chart (D17). Average,
   Minimum and Maximum use completed periods only, so a period still filling
   up is never reported as the minimum and never lowers the average. Total
   is the Energy recorded so far in the applied range, the in-progress period
   included. Statistics are never calculated in the browser: the API's series
   `summary` implements this (feature document, API contract). Supersedes the
   earlier contract (average / min / max over every bucket with a value).
2. **Catch-up periods.** Where the API identifies a value as including Energy
   from readings that resumed after a gap (`GAPS_DETECTED` on that period),
   Statistics shows a concise disclosure on that Minimum or Maximum. Catch-up
   is never inferred from a value's magnitude.
3. **Unavailable selections.** In "Series not shown in chart", selections
   with the same reason are grouped under that reason with a count and can be
   expanded to list the selections in selection order.
4. **Data quality.** Amendment 6 and the documented API counting rules apply.
   Durations are not shown when the interval length is unknown. Several
   reasons for one selection are each shown with their approved line. A
   period range that spans unaffected periods must not read as continuous.
5. **Formatting.** Two decimal places for this release. At daily resolution,
   period times are shown as dates without a time of day.
6. **Production readiness.** Scenarios that cannot be validated with current
   staging data (meter reset / rollover, reconstructed timing, and others
   recorded in the feature document) are recorded as unverified, not passed.

## Amendment 8 (2026-10-09): B3 — measurements and per-phase Energy

**Decision (Product Owner, 2026-10-09).** After every enabled data point was
assigned on staging (55 asset–device pairs, 3,021 assignments, effective
2026-10-09 12:56:55 IST), the registry grows beyond the Energy-only pilot
(decision 3) to: Energy, Energy Export, Power (active), Reactive Power,
Current, Voltage (line-to-neutral), Line to Line Voltage, Power Factor and
Frequency. 3 Phase is served wherever the source data and the assignments
support it, including per-phase Energy. Apparent power and energy, the
reactive energy registers, Current THD, phase angle, neutral current and
environmental points stay out of the registry.

**Implementation (B3, migration 292; not deployed).**

1. Measurements are read from `telemetry.normalized_points` (1m) and
   `analytics.point_telemetry_15m` composed into the site-local
   15m/30m/1h/1d grid (business rule 10's exact mean, with min / max).
   `analytics.point_telemetry_1h` is not read: it is on the UTC hour grid.
   1d is limited to the 120-day 15-minute tier until B4.
2. Values are converted from the stored source unit to the logical point's
   unit exactly as live telemetry converts them (field-mapping scale and
   offset, migration 025), as migration 289 required of this layer.
3. Per-phase Energy is read from `analytics.energy_register_delta_15min`
   (migration 290) at 15m and coarser, in kWh, with the register evidence;
   at 1m 3 Phase shows System Energy (no 1-minute per-phase source). System
   Energy is unchanged (migrations 279–286). Phase series are never presented
   as summing to the System series.
4. Attribution: a persisted 15-minute row counts only when it lies entirely
   inside an assignment; a partial first / last 15 minutes is read from raw
   samples by their own time. New assignments are never backfilled.
5. Measurement Data quality uses the existing lattice (`GOOD` / `PARTIAL` /
   `GAP`) with interval counts at the site capture interval; `stale` is null
   for measurements and per-phase Energy; `summary.total` is null for
   measurements.
6. Customer names (PO naming convention, 2026-10-09): chart legend and
   tooltip `<Asset name>-<code>` (System P, Q, V, I, PF, F; phases P1–P3,
   Q1–Q3, V1–V3, I1–I3, PF1–PF3, E1–E3, Ex1–Ex3, line-to-line V12/V23/V31;
   Energy, Energy Export and Line to Line Voltage System keep their name);
   Statistics and Data quality use the measurement name, the phase code and
   the asset name (`Power-Chiller 1`, `Reactive Power-Q1-AHU 2`), so
   different assets never share a label. Power is in Frequently Used.

**Line-to-line evidence (2026-10-09):** the mapping Eniscope `U1`/`U2`/`U3`
→ L12/L23/L31 (shown V12/V23/V31) is recorded as a confirmed vendor mapping
in `postgres/ddl/110_enhance_eniscope_energy_profile.sql`, and staging
telemetry agrees (U/V = √3; `U` = mean of `U1`–`U3`; each field closest to
its mapped pair). Line to Line Voltage System keeps its readable label (no
authoritative code). **Open (Product Owner):** confirm the pair order from
Eniscope documentation (not held in the repository).

