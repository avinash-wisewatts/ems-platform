# Aggregation Architecture

Status: CURRENT · Last reviewed: 2026-09-24
Verification basis: Repository + Staging (live row counts, timestamps, capture-policy resolution; retention/refresh jobs re-read from `timescaledb_information.jobs` on 2026-09-23)

Target architecture for all resolutions (UTC time basis, tiers, retention,
windows): [ADR-019](../../00-governance/decisions/ADR-019-analytical-backbone-time-basis-and-tiers.md).

## Two parallel aggregation systems — do not confuse them

1. **`telemetry.ca_energy_*`** — TimescaleDB continuous aggregates (auto-
   refreshing materialized views over `telemetry.energy_measurements`).
   Simple statistical rollups (avg/min/max per bucket). Not tenant-semantic;
   no quality classification.
2. **`analytics.energy_consumption_*`** — separately-persisted, explicitly-
   refreshed tables containing *validated, quality-classified* consumption
   deltas (import/export kWh with GOOD/GAP/reset/rollover classification).
   These, not `ca_energy_*`, are the authoritative semantic layer Grafana
   and the Analytics API consume.

## The five resolutions, verified

| Resolution | Table | Source | Applies to |
|---|---|---|---|
| 1 minute | `analytics.energy_consumption_1min` | `telemetry.ca_energy_1min` | All sites (native for 60s capture policies) |
| 5 minute | `analytics.energy_consumption_5min` | `telemetry.ca_energy_5min` | **Only sites whose effective capture interval is exactly 300 seconds** |
| 15 minute | `analytics.energy_consumption_15min` | `analytics.v_energy_semantic_rollup_15min` (aggregates whichever native resolution applies per site) | All sites |
| Hourly | `analytics.energy_consumption_hourly` | `analytics.energy_consumption_15min` — explicitly, never raw registers | All sites |
| Daily | `analytics.energy_consumption_daily` | `analytics.energy_consumption_15min`, resolved using `metadata.sites.timezone` for local-midnight boundaries | All sites |

**Architectural principle**: once a value is classified once (GOOD/GAP/
reset/rollover, at the native resolution), every coarser resolution
aggregates the already-classified consumption — it never re-derives from
raw cumulative registers a second time.

## The fact that looks like a bug but isn't: `energy_consumption_5min` can legitimately be empty

`postgres/ddl/143_persisted_validated_energy_consumption_5min.sql`'s own
header: "60-second sites are intentionally excluded because their
authoritative semantic history is `analytics.energy_consumption_1min`."
Verified for Meenaxy Pharma's site `UNIT_2` (`capture_interval_seconds=60`):
`_5min` correctly has 0 rows while `_1min` has 946, `_15min` has 66, and
`_hourly` has 22, all current. **This will be misdiagnosed as a bug again
if this isn't known** — check the site's capture-interval policy first;
see [../../10-operations/troubleshooting.md](../../10-operations/troubleshooting.md).

## Retention and compression currently in force (staging, verified 2026-09-23)

**Correction:** this section used to say "No retention policy currently
implemented", quoting `postgres/ddl/143_*.sql`'s header. That header is out
of date. Staging's `timescaledb_information.jobs` shows these policies:

| Object | Retention | Compression after |
|---|---|---|
| `analytics.energy_consumption_1min` | 180 days | 7 days |
| `analytics.energy_consumption_5min` | 2 years | 14 days |
| `analytics.energy_consumption_15min` | 2 years | 7 days |
| `analytics.energy_consumption_hourly` | 5 years | 30 days |
| `analytics.energy_consumption_daily` | none | 90 days |
| `telemetry.normalized_points` | 90 days | 1 day |
| `analytics.generic_telemetry_15m` / `_1h` (migration 185) | none | none |

ADR-019 sets different targets (Energy 1m 90d, 15m 120d uncompressed, 1h 1y,
1d 8y). Those Energy retention changes are **not applied**; they are an
irreversible deployment gate (ADR-019 D6).

## Generic point-telemetry tier: `analytics.point_telemetry_15m` (migration 264)

Status: **deployed to staging and backfilled** (ADR-019 M1, PR #75,
2026-09-24; not in production). Backfilled 2026-08-20 to 2026-09-22 12:00
IST and validated exactly against raw `normalized_points`.

- Continuous aggregate over `telemetry.normalized_points`, UTC 15-minute
  grid, grouped by organization/site/device/logical point. It stores
  `sum_value`, `sample_count`, `min_value`, `max_value` over
  `quality_code = 'GOOD'` numeric samples. Average = `sum_value /
  sample_count` at read time. Keyed by device/point, not asset:
  attribution resolves through `metadata.asset_points` when read.
- Two disjoint, bounded refresh policies: `[now-2d, now-1m)` every 5 minutes,
  and `[now-35d, now-2d)` daily at 21:30 UTC, which catches late or
  recovered telemetry. Its first run on staging is 2026-09-25 21:30 UTC, one
  day later than migration 264's comments state; the backfill already covers
  that window.
- 120-day retention; no compression; `materialized_only`.
- SELECT for `ems_app` and `ems_readonly` only (not `grafana_reader`: it is
  not tenant-scoped).
- Intended upstream of the future generic 30m (derived when read), 1h and 1d
  tiers. The legacy Explorer aggregates `generic_telemetry_15m`/`_1h` remain
  in service, unchanged, until the Explorer is repointed.

**Never refresh with NULL bounds.** Refreshing a continuous aggregate over
a window whose raw data has been dropped deletes the aggregate rows.
`normalized_points` is kept 90 days and this tier 120, so
`refresh_continuous_aggregate('analytics.point_telemetry_15m', NULL, NULL)`
would destroy the 90–120-day history. For manual or initial backfill, use
`CALL analytics.backfill_point_telemetry_15m(p_from, p_to[, p_slice])`
(top-level CALL, `ems_admin`). It requires 15-minute-aligned, non-future
bounds, commits per slice, and refuses to start before the oldest retained
`normalized_points` chunk. The migration 185 and 046 headers suggest an
unbounded refresh for their own aggregates; do not copy that pattern.

**Initial backfill after deployment (operator step):** the two policies
fill the last 35 days by themselves. The late-data policy's first run
materializes about 33 days in committed batches, so run the backfill
procedure first to spread that load. Older retained history (35 to about 90
days) is filled once with the backfill procedure from the oldest
`normalized_points` chunk start up to `now() - 35 days`, 15-minute aligned.

**Always bound 15m reads on `bucket_start`.** An unbounded whole-table
GROUP BY on this aggregate ran for over 25 minutes on staging, doing
IO-bound device-ordered scans.

## Generic point-telemetry tier: `analytics.point_telemetry_1h` (migration 265)

Status: **deployed to staging and fully backfilled** (ADR-019 M2, PR #76,
2026-09-24). Backfilled [2026-08-24 15:00, 2026-09-24 11:00) UTC and
validated exactly against 15m. The four jobs are activated by migration 266
(forward on the :07/:22/:37/:52 UTC grid, reconcile at 22:30 UTC); until 266
is deployed they are paused.

- Job-built hypertable (7-day chunks) on the UTC hour grid, derived only
  from `point_telemetry_15m`: sum of sums, sum of counts, min of mins, max of
  maxes, and `source_bucket_count` (1–4). Identity is NOT NULL with a plain
  unique index. There is no asset or timezone column: for IST sites, hour
  buckets are HH:30 local.
- Written only by `analytics.refresh_point_telemetry_1h` (bounded,
  hour-aligned, value-aware upsert, never removes rows). It is called by:
  - the forward job `run_point_telemetry_1h_job` (every 15 minutes, 2-hour
    overlap; the only `pipeline_state('point_telemetry_1h')` writer);
  - the 35-day reconcile `reconcile_point_telemetry_1h` (daily at 22:30 UTC,
    1-day coarse buckets, `n_max` 7, logged to `pipeline_reconciliation_log`);
  - `backfill_point_telemetry_1h`.
- An hour is built only when the 15m materialization watermark has passed
  its end. That watermark is the end of the newest materialized 15m bucket
  that holds data, so the tier stops advancing when telemetry stops,
  reporting `NO_SOURCE_DATA`.
- 1-year retention; compression after 30 days (grouped by device and
  logical point). Both policies are activated by migration 266.
- The legacy Explorer aggregate `generic_telemetry_1h` stays in service,
  unchanged, until the Explorer is repointed.
- **Not yet in `analytics.v_pipeline_health`.** Adding it means replacing an
  existing view, so it is left for a later step. Until then, monitor it with
  `telemetry.pipeline_state` and `analytics.pipeline_reconciliation_log`.
- **Forward-job failures.** A run that fails, including partway through
  the refresh, rolls back completely. No partial 1h rows are kept, and
  `pipeline_state` keeps its previous checkpoint and status, because the
  handler's `FAILED` write rolls back with the run. So `pipeline_state`
  never shows a failure. The failure is recorded in
  `timescaledb_information.job_stats` (`last_run_status = 'Failed'`) and
  `job_errors`, and the next successful run retries the same window from the
  unchanged checkpoint. A test in `app/tests/test_point_telemetry_1h.py`
  proves this for both a direct call and a run by the scheduler.

## Repository/live gap: canonical `ddl/` coverage

`postgres/ddl/` contains persisted-aggregation files only for **1min and
5min**. The 15min/hourly/daily persisted tables exist **only** as numbered
upgrade migrations (179–183), with no corresponding file in `postgres/ddl/`.
**Status: unresolved drift**, not investigated further — could mean a
from-scratch `ddl/`-only deployment would be missing these three tables, or
they were simply never backported despite being live and correct via the
migration path.

## Why Grafana should never scan raw telemetry

`telemetry.energy_measurements` and `telemetry.normalized_points` are
per-message-resolution tables — 44 raw rows and 2,250 normalized rows per
device in under an hour, for a single 60-second-capture device. A dashboard
querying any meaningful time range directly against these tables would scan
orders of magnitude more rows than necessary. See
[analytics-layer.md](analytics-layer.md) and
[../../10-operations/monitoring.md](../../10-operations/monitoring.md).
