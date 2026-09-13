# Aggregation Architecture

Status: CURRENT · Last reviewed: 2026-08-24
Verification basis: Repository + Staging (live row counts, timestamps, capture-policy resolution)

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

## No retention policy currently implemented

Explicitly stated in `postgres/ddl/143_*.sql`: "No retention policy yet.
The semantic history remains authoritative until validated higher-
resolution semantic rollups and their retention contracts have been
implemented." Treat retention as **unknown/not implemented** for all five
resolutions unless independently re-checked.

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
