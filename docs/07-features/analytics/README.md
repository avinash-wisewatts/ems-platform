# Feature: Analytics (v1)

Status: DECIDED, implementation in progress (2026-09-27) · Owner: Product ·
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
| EMS-REQ-129 | Site-scoped Analytics page titled "&lt;site name&gt; Analytics"; a curated semantic Trends explorer. | [REF] title · [PO] curated explorer · [C] EMS-REQ-037, Q62 site context |
| EMS-REQ-130 | Asset selection: only ACTIVE assets that have at least one catalogue data point; search by name; Select all / Clear all; group by asset type (default) or area; a group checkbox selects the group; groups collapsed by default; "N of M" count; at most 10 selected. | [REF] controls · [PO] ACTIVE only, 10 assets |
| EMS-REQ-131 | Data point selection: semantic data points from the confirmed `asset_points` catalogue only, grouped by category; search; Select all / Clear all; count; at most 5 distinct data points. Energy Import and Energy Export are separate data points. | [REF] controls · [PO] 5 points, Energy directions · [C] ADR-018 decision 1 |
| EMS-REQ-132 | Phase selection: System or 3 phase, applied where the data point has per-phase values. | [REF] |
| EMS-REQ-133 | Shared date/time range: two-month calendar, quick-range buttons, optional time-of-day selector (00:00 bounds when off), Apply / Cancel / click-outside to close; the chart reloads only on **Update**; selectable dates bounded by data availability. All ranges are site-local (site IANA timezone, DST-correct). | [REF] controls · [C] ADR-019 time basis |
| EMS-REQ-134 | Resolution: exactly one of Auto (default), 1 minute, 15 minutes, 30 minutes, 1 hour, 1 day. Auto and the per-resolution maximum windows follow ADR-019; options whose maximum window the range exceeds are unavailable. 30 minutes and 1 hour are on the site-local grid (superseding "1 hour is on the UTC grid"); 1 day is the site-local calendar day. Auto never selects a resolution whose retention floor is after the range start. | [REF] options, Auto default · [C] ADR-019 · [PO] site-local 30m/1h (D24, supersedes 1h UTC grid), 1d required in v1 |
| EMS-REQ-135 | Chart: Energy as grouped bars, every other data point as a line; one Y axis per unit, auto-scaled; drag-to-zoom, "show all" reset and a two-handle range slider; a legend entry per asset – data point (– phase); at most 25 rendered series. | [REF] chart behaviour · [PO] grouped bars, 25 series |
| EMS-REQ-136 | Statistics table: one row per asset × data point × phase series with Total (Energy only), Average, Minimum and Maximum. No cross-asset aggregate totals. | [PO] |
| EMS-REQ-137 | CSV download of the data the chart displays: one row per series per bucket, with site, time range, resolution, data point, unit, phase and quality context. Generated client-side. | [REF] download · [C] ADR-014 export pattern |
| EMS-REQ-138 | Data quality and coverage: every bucket carries its interval counts, bucket and data state and evidence flags (business rule 11; the per-bucket coverage ratio was removed); a selection with no data, or no longer available, is shown as such inline with its reason and never dropped silently; the chart still renders the other series. | [C] IA "Analytics — Trends" no-data rule, terminology quality vocabulary, ADR-011 |
| EMS-REQ-139 | Chart options: CSV download and collapse-to-header only. No Administration App functionality on this page. | [REF] · [C] ADR-006 |

**Out of scope for v1** [PO]: Environmental / Space data
(`metadata.space_points`); cross-asset aggregate statistics; stacked Energy
bars; Comparison (shown as a disabled placeholder [REF]); cost. The PDF's
"Misc/Other" data-point section is a placeholder only [REF].

## User experience

- Header: "&lt;site name&gt; Analytics".
- Right-hand filter panel, top to bottom: Update, Assets, Data points,
  Resolution, Phase type, Comparison (disabled placeholder).
- Main area: chart card (title "&lt;N assets | asset name&gt;, &lt;range&gt; – &lt;resolution&gt;,
  &lt;phase&gt;", options: download CSV, collapse), then the statistics table.
- Changing a filter never reloads by itself; **Update** does.

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
   under 3 phase]. Energy is System-only in v1.
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
| B0 | ADR-019 D2: block site timezone changes once a site has telemetry | Implemented (migration 275), not deployed |
| B1 | Catalogue read function + `GET …/analytics/catalog` | Implemented (migration 276, `app/src/analytics_trends_service.py`), not deployed |
| B1b | Data availability bounds per catalogue data point | Implemented for Energy (migration 277), not deployed; non-Energy bounds come with B3 |
| B2 | Energy series + `GET …/analytics/series` | Implemented (migration 278), not deployed; its Energy source replaced by Option B (below) |
| Option B | Persisted-tier Energy read, portal/organization scoped, not Grafana-keyed | Migration 279 **deployed to staging** 2026-09-27 (PR #85); staging parity gate PT-1–PT-11 passed with zero mismatches |
| 280 | Switch Analytics Energy to 279; drop 278's function; availability aligned; resolution retention floors | Implemented, not deployed |
| 282 | Data Quality read contract ([ADR-022 Amendment 4](../../00-governance/decisions/ADR-022-analytics-v1-scope-and-contract.md#amendment-4-2026-09-29-data-quality-read-contract-migration-282)): `as_of`, site-local 30m/1h, interval counts, bucket/data state, evidence flags, status reasons, data bounds, stale, site-aware floors, floor-aware Auto, D73 labels, `coverage_ratio` removed | Implemented, not deployed; staging parity and latency gate pending |
| 283 | Read latency, Option 1: the fresh 15-minute tail is read through `analytics.energy_semantic_rollup_15min_range` (the rollup view bounded to a whole-bucket UTC range before grouping, so chunk exclusion applies); results unchanged | Deployed to staging 2026-09-29 (`e6754de`, PR #91). Read-only validation: helper↔view parity on live data 0 differing rows; value and Data Quality snapshot 282→283 identical (140,132 rows, 36 columns); tail read pruned to the current chunk |
| 284 | Read latency, Option 2: the per-bucket Data Quality subqueries of 282 (NOT_ASSIGNED, the device-first INITIAL count, assigned expected intervals) are replaced by set-based, request-level computation (computed once per request and joined to the bucket grid); 7-argument API, Energy values, Data Quality semantics, 283's tail pruning, views, tiers, jobs and storage unchanged | Implemented, not deployed. Local validation: 283→284 parity 0 differences across the randomised scenario matrix; full backend suite 1843 passed. Staging validation pending |
| B3 | Generic series path (1m / 15m / 30m / 1h) | Planned — returns `NOT_AVAILABLE` until non-Energy assignments exist |
| B4 | `analytics.point_telemetry_1d` persisted tier (job-built from 15m, upsert-only, 35-day reconcile, backfill, 8-year retention, compression after 90 days; ADR-019 D1/D5) and the 1d read path | Planned — must be live before the first `point_telemetry_15m` chunks age out of 120-day retention |
| F1–F8 | Frontend: time-range defect fixes (ADR-019), route, API layer, date/time picker, filter panel, ChartFrame extension, table/CSV/states, verification against staging through the tunnel | Planned |

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

1. **Summary vs Individual tabs.** With no cross-asset aggregates in v1, does
   the page show one per-series statistics table, or keep a "Summary" tab with
   different content?
2. **Curated non-Energy registry.** Which parameters join the registry once
   assignments exist (the reference lists Current, Power, Power Factor,
   Voltage, and a Power list)? Cumulative registers other than Active Energy
   Import/Export (apparent and reactive energy) cannot be shown as averages;
   they need a delta calculation first.
3. **"System" phase for non-Energy points.** Which qualifier is "System" for
   Current and Voltage (`TOTAL`, `AVG`, line-to-line)?
4. **Data point labels.** Parameter names ("Active Energy Import") or shorter
   customer wording ("Energy Import")? *Resolved for Energy (D73, implemented
   with migration 282): "Energy" and "Energy Export". Labels for future
   non-Energy points remain open.*
5. **Presentation details.** Coverage/quality rendering on the chart; week
   start day for This / Last Week; whether "Last 24 Hours" is a quick range;
   minute granularity of the time selector; the reference mockups' stepping
   arrows, "Hide Filters", print, share and expand controls; which location
   level "group by area" uses (space, floor or building — the catalogue
   returns all three and the location path).
6. **Production release gate.** Is a production release of Analytics held
   until real assets are commissioned there, given the catalogue would
   otherwise be empty?

## Validation

- B0: `app/tests/test_site_timezone_immutable_with_telemetry.py`, `app/tests/test_database_error_messages.py`.
- B1: `app/tests/test_analytics_catalog_read.py` (database read: lifecycle, effective-dating, parity-bridge classification, semantic-only, tenant isolation) and `app/tests/test_analytics_api_v1_analytics_catalog_routes.py` (route contract, registry filtering, no `attribution_basis` exposure).
- Energy read (migration 279): `app/tests/test_asset_energy_tier_read.py` (30) — tiers, checkpoint composition, DST, source boundaries, reconstruction, retention, unmapped organization, tenant isolation, exact parity with the canonical read. Staging parity gate PT-1–PT-11 (2026-09-27, read-only): zero mismatches over 112,806 15-minute buckets, 56,510 30-minute buckets, 28,387 hours, 1,448 days, 211,817 minutes and 318 fingerprints (details in the platform-manual change history).
- B1b/280: `app/tests/test_analytics_energy_availability_read.py` (278's function dropped; availability and floors contracts; floors equal the live retention policies; availability from the daily start to the raw tail, beyond raw retention, binding start, parity-bridge rows unchanged).
- B2/280: `app/tests/test_analytics_api_v1_analytics_series_routes.py` (validation, limits, statuses, Energy mapping, summary, retention floors) and `app/tests/test_analytics_api_v1_analytics_e2e.py` (HTTP to database with no data-layer mocking and **no Grafana mapping**: catalogue, every resolution agreeing on totals, UTC hour grid, IST days, 1m beyond raw retention `RESOLUTION_UNAVAILABLE`, tenant isolation).
- Full backend suite passed locally (1798 tests, 2026-09-27). Migration 280 not deployed.
- 282: `app/tests/test_analytics_energy_series_data_quality.py` (18: IST local 1h equals its 15m rows with the UTC hourly tier unused, Kathmandu +05:45 30m/1h, DST days of 23/25 local hours, in-progress/future buckets, assignment boundaries, device-first vs later `INITIAL`, missing/rejected/gap and all-rejected buckets, stale at 7 and 21 minutes, policy at `last_data_at`, unscheduled stage, 900 s capture → null, site-aware floors, reconstruction off, tenancy, function security); `test_asset_energy_tier_read.py` values unchanged (tenant default UTC for hourly-tier composition; reasons now named); series route tests (reasons, NO_DATA reasons, one `as_of`, floor-aware Auto, evidence flags, bucket state, no `coverage_ratio`, 3-phase fallback); e2e (IST local hours, 1d, floors). Full backend suite 1835 passed locally (2026-09-29). Not deployed.

- 283: `app/tests/test_energy_rollup_range.py` (5: helper security and inlinability, helper = view definition plus the bounded `WHERE`, series function = 282 with only the tail line changed, `bucket_start` pruning in the plan, helper rows equal the view's rows on all 43 columns for on-grid, off-grid, empty, infinite and no-data ranges, 1-minute and 5-minute native rows, and another organization's device). Existing Analytics suites pass unchanged in values. Full backend suite 1840 passed locally (2026-09-29). Staging (2026-09-29, after deployment of `e6754de`, read-only): helper↔view parity on live data for every bound device in both organizations — last 6 hours including the fresh tail, last 3 days, an off-grid range and an empty range — 0 differing rows in either direction; 282→283 snapshot (5 resolutions, 53 assets, fixed `as_of`) identical on all 140,132 rows and 36 columns; the tail read scans only the current `energy_consumption_1min` chunk via `(device_id, bucket_start)` (0.24 ms, against up to 1,565 ms per asset before).

- 284: new `app/tests/test_energy_series_set_based_quality.py` (3: set-based structure and unchanged security; property test installing migration 283's exact function as a session-temporary reference and comparing it with 284 on every row and column — 12 seeded scenarios × 5 resolutions × 3 `as_of` values, across UTC / IST / Kathmandu / London sites, 60 / 300 / 900 s capture, tier checkpoints, binding windows starting and ending mid-bucket, device replacement with the new device's first reading inside the range, separate import/export windows, a sub-bucket window, a never-reporting device, missing / gap / rejected minutes and a later INITIAL — 0 differences, every data state exercised; a check that the device-first reading is still subtracted once per containing binding window). A mutation check confirmed the property test detects deliberate changes to the assigned-interval, INITIAL and NOT_ASSIGNED logic. `test_energy_rollup_range.py`: its byte-for-byte pin of the series function to 282 plus one line is retired (superseded by the 283→284 parity test); it still checks the tail is read through the 283 helper. Full backend suite 1843 passed locally (2026-09-29). Not deployed; staging validation pending.

## Release status

Not released. Nothing deployed.

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
- Staging measurements after migration 282 (2026-09-29, same method):
  15m / 30 days 1.55–2.39 s; 30m / 60 days 1.66–2.20 s; 1h / 180 days (IST,
  local hours) 1.68–2.93 s; 1d / 3 years 1.05–1.20 s. A read-only
  investigation attributed about 0.3–0.55 s per request to 282's per-bucket
  and per-series Data Quality work, and the largest, most variable cost to the
  unchanged fresh-tail read of `v_energy_semantic_rollup_15min`, whose filter
  on the grouped `bucket_start` scanned every chunk of a device's native rows
  (up to about 1.6 s per asset on a cold cache). Migration 283 (deployed to
  staging 2026-09-29) bounds that tail read. Staging benchmark (10 IST assets,
  maximum windows, 5 runs; first run cold, median of the rest warm), 282 → 283:
  15m / 30 days first 6.99 → 1.98 s, warm 1.78 → 1.73 s; 30m / 60 days warm
  1.94 → 1.74 s; 1h / 180 days warm 1.70 → 1.78–1.82 s (repeat runs); 1d /
  3 years warm 1.02 → 1.07 s. The cold-cache spike is removed; warm latency is
  essentially unchanged and **remains above the 500 ms target**, being mostly
  282's per-bucket and per-series Data Quality work. Option 2 — replacing
  282's per-bucket subqueries with set-based, request-level computation — is
  migration 284 (implemented 2026-09-29, **not deployed**; staging validation
  pending). A local benchmark (disposable test database, 10 IST assets, 30 days
  of 1-minute data, warm median of 5 runs), 283 → 284: 15m 5.36 → 0.77 s;
  30m 1.77 → 0.64 s; 1h 0.86 → 0.58 s; 1d 0.25 → 0.26 s. These figures are
  **directional and local only**: the test database is not tuned like staging
  (283's 15m read took 1.73 s on staging against 5.36 s locally), so they are
  not a staging or production result and do not establish that the 500 ms
  target is met. No production-readiness claim is made.
- The Asset View Energy tile still reads the canonical, Grafana-keyed Energy
  read; moving it is a separate, parity-gated change.

## Future scope

Spaces / Environmental analytics; Comparisons (EMS-REQ-038 / EMS-REQ-064);
cross-asset aggregate statistics; saved views.
