# Aggregation Architecture

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository (postgres/ddl/140,143; postgres/migrations/179-183) + Staging (live row counts, timestamps, and capture-policy resolution)
```

## Two parallel aggregation systems — do not confuse them

The platform has **two distinct layers** that both produce 1min/5min/15min/hourly/daily buckets, with confusingly similar names:

1. **`telemetry.ca_energy_*`** — TimescaleDB continuous aggregates (auto-refreshing materialized views over `telemetry.energy_measurements`). Simple statistical rollups (avg/min/max per bucket). Not tenant-semantic; no quality classification.
2. **`analytics.energy_consumption_*`** — separately-persisted, explicitly-refreshed tables containing *validated, quality-classified* consumption deltas (import/export kWh with GOOD/GAP/reset/rollover classification). These, not the `ca_energy_*` views, are the authoritative semantic layer Grafana and the application should consume.

## The five resolutions, verified

| Resolution | Table | Source | Refresh mechanism | Applies to |
|---|---|---|---|---|
| 1 minute | `analytics.energy_consumption_1min` | `telemetry.ca_energy_1min` | `analytics.refresh_energy_consumption_1min()` via TimescaleDB job (`postgres/ddl/140_persisted_validated_energy_consumption_1min.sql`) | All sites (native resolution for 60-second capture policies) |
| 5 minute | `analytics.energy_consumption_5min` | `telemetry.ca_energy_5min` | `analytics.refresh_energy_consumption_5min()` / `analytics.run_energy_consumption_5min_job` (job scheduled every 1 minute, 30-minute lookback; `postgres/ddl/143_persisted_validated_energy_consumption_5min.sql`) | **Only sites whose effective capture interval is exactly 300 seconds** (see below) |
| 15 minute | `analytics.energy_consumption_15min` | `analytics.v_energy_semantic_rollup_15min` (which itself aggregates whichever native resolution — 1min or 5min — applies per site) | `postgres/migrations/179_persisted_energy_consumption_15min.sql` (+ fix in `180`) | All sites |
| Hourly | `analytics.energy_consumption_hourly` | `analytics.energy_consumption_15min` — explicitly, never raw registers | `postgres/migrations/181_persisted_energy_consumption_hourly.sql` (+ fix in `182`) | All sites |
| Daily | `analytics.energy_consumption_daily` | `analytics.energy_consumption_15min` — explicitly **not** hourly, and resolved using `metadata.sites.timezone` for local-midnight boundaries, not UTC | `postgres/migrations/183_persisted_energy_consumption_daily.sql` | All sites |

**Architectural principle, stated explicitly in the migration comments and confirmed by the rollup chain above:** once a value has been classified once (GOOD/GAP/reset/rollover, at the native resolution), every coarser resolution aggregates the *already-classified* consumption — it never re-derives from raw cumulative registers a second time. Hourly and daily are explicit about this ("must never recalculate energy from coarse cumulative register MIN/MAX values").

## The fact that looks like a bug but isn't: `energy_consumption_5min` can legitimately be empty

`postgres/ddl/143_persisted_validated_energy_consumption_5min.sql`'s own header states: *"Native-resolution semantic layer for sites whose effective telemetry capture interval is exactly 300 seconds... 60-second sites are intentionally excluded because their authoritative semantic history is `analytics.energy_consumption_1min`."* The refresh function filters on `capture_policy.capture_interval_seconds = 300`.

**Verified live this session**: Meenaxy Pharma's site `UNIT_2` has `capture_interval_seconds=60` (confirmed via `telemetry.resolve_site_capture_bucket()`), and `analytics.energy_consumption_5min` correctly has **0 rows, 0 devices** for it — while `analytics.energy_consumption_1min` has 946 rows, `_15min` has 66 rows, and `_hourly` has 22 rows, all current. This was initially flagged as a suspicious anomaly during pipeline verification (15-minute data existing while 5-minute data didn't looks backwards for a naive rollup chain) and was root-caused to this design decision, not a defect. **Document this prominently — it will be misdiagnosed as a bug again if this isn't known.**

## No retention policy currently implemented

`postgres/ddl/143_persisted_validated_energy_consumption_5min.sql` states explicitly: *"No retention policy yet. The semantic history remains authoritative until validated higher-resolution semantic rollups and their retention contracts have been implemented."* Not verified whether this has since changed for the other resolutions — treat retention as **unknown/not implemented** for all five resolutions unless independently re-checked.

## Repository/live gap: canonical `ddl/` coverage

`postgres/ddl/` (the canonical fresh-deployment schema set) contains persisted-aggregation files only for **1min and 5min** (`140_*`, `143_*`). The 15min/hourly/daily persisted tables exist **only** as numbered upgrade migrations (`179`–`183`), with no corresponding file found in `postgres/ddl/`.

**STATUS: Drift (unresolved, not investigated further this pass).** This could mean a genuinely fresh deployment (running only `postgres/ddl/*`) would be missing these three tables entirely, or it could mean they were simply never backported into the canonical set despite being live and correct via the migration path. Not established which. Worth resolving before treating `ddl/` as sufficient for a from-scratch environment build.

## Why Grafana should never scan raw telemetry

`telemetry.energy_measurements` and `telemetry.normalized_points` are per-message-resolution tables (44 raw rows and 2250 normalized rows per device in under an hour, for a single 60-second-capture device, in this session's verification). A dashboard querying any meaningful time range directly against these tables would scan orders of magnitude more rows than necessary. The `analytics.energy_consumption_*` tables and their `v_grafana_*`/`v_energy_*` view layer exist specifically so Grafana queries the resolution matched to the requested time range (see `12-grafana.md` and `22-performance.md`) instead of aggregating raw data on every dashboard load.
