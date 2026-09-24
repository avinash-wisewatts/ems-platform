# ADR-019: Analytical Backbone — UTC Time Basis, Resolution Tiers, Retention

Status: Decided (architecture). **M1 implemented, not deployed** (migration
264, branch `feature/analytics-backbone-m1-point-telemetry-15m`). M2 onwards
not implemented.
Date: 2026-09-24
Decision owners: Product + Architecture
Related: [ADR-007](ADR-007-analytics-api-boundary.md) (Analytics API is the
customer read boundary), [ADR-018](ADR-018-asset-point-assignment-and-commissioning.md)
(`metadata.asset_points` is the authoritative Asset attribution layer).

## Context

The Analytics page and the future `/analytics/series` API need a generic,
multi-resolution storage backbone for every point type, not only Energy.
Before this decision, generic history existed only as the Explorer-specific
continuous aggregates `analytics.generic_telemetry_15m` / `_1h` (migration
185). They store avg/min/max only, which cannot be combined exactly into
coarser tiers, and have no retention. Energy had its own persisted tiers,
whose hourly tier is on the UTC grid (migration 217) and whose daily tier
uses site-local days (migration 183).

Findings established during the investigation (read-only, staging, TimescaleDB 2.29.2):

- Refreshing a continuous aggregate over a window whose source data has
  been dropped **deletes** the aggregate rows (documented TimescaleDB
  behaviour). An unbounded `refresh_continuous_aggregate(..., NULL, NULL)`
  therefore destroys any aggregate history older than the source's retention.
- A continuous aggregate can bucket in only one fixed timezone, so per-site
  local buckets cannot be a continuous aggregate.
- Every IANA timezone offset is a multiple of 15 minutes (0 exceptions in the
  PostgreSQL timezone database), so UTC 15-minute buckets nest exactly inside
  any site-local hour or day. UTC hours do **not** nest inside local days for
  half-hour-offset zones (every current site is `Asia/Kolkata`, +05:30).
- TimescaleDB 2.29.2 supports several refresh policies on one continuous
  aggregate provided their windows do not overlap (overlaps are rejected).

## Decision

### Time basis
UTC is the canonical time basis for storage, aggregation, retention,
compression, watermarks and pipeline processing. `normalized_points`, all
persisted aggregate timestamps, `asset_points` effective ranges and API
transport timestamps are UTC. The site timezone is a presentation/semantic
concern: date pickers, "Today"/"Yesterday"/weeks, and chart/table labels use
the site's IANA timezone, DST-correct, never a fixed offset.

### Tiers

| Tier | Generic | Energy | Retention | Compression |
|---|---|---|---|---|
| 1m | live from `telemetry.normalized_points` (no persisted generic 1m tier) | persisted `energy_consumption_1min` | 90d | — |
| 15m | persisted, UTC grid (common upstream tier) | persisted `energy_consumption_15min`, UTC | 120d | none |
| 30m | derived at read time from 15m | derived from Energy 15m | — | — |
| 1h | job-built persisted table, UTC buckets | existing `energy_consumption_hourly`, UTC | 1y | after 30d |
| 1d | job-built persisted table, one row per **site-local calendar day** stored as UTC `bucket_start`/`bucket_end`, plus a `local_date` label | existing `energy_consumption_daily` | 8y | after 90d |

- Default resolution: range < 5d → 15m; < 30d → 1h; ≥ 30d → 1d.
- Maximum windows (max / default-display): 1m 3d/36h; 15m 30d/15d; 30m 60d/30d; 1h 180d/90d; 1d 3y/1.5y.
- Energy and non-Energy follow the same customer-facing storage, retention,
  resolution and window policy; Energy keeps its register-delta calculation.
- `normalized_points` stays device/logical-point identified — no `asset_id`.
  Asset attribution resolves at read time through `metadata.asset_points`.
- 15m stores `sum_value`, `sample_count`, `min_value`, `max_value`; the
  average is computed at read time.
- 1h and 1d are **not** continuous aggregates: they are durable job-built
  tables with bounded, non-destructive (upsert-only, never delete)
  reconciliation, so they can be altered later without losing history.
- No refresh or reconcile may be unbounded; every window stays inside the
  90-day raw retention.

### Locked decisions (2026-09-24)

- **D1** — `point_telemetry_1d` stores `local_date DATE` as a semantic label
  alongside UTC `bucket_start`/`bucket_end`. It is not a timezone or a
  storage key.
- **D2** — Block site timezone edits once a site has telemetry. Effective-
  dated timezone history is a separate, future product/data-model decision.
- **D3** — 1h stays on the UTC grid. For half-hour-offset sites (IST) the
  customer sees e.g. 05:30–06:30 local; 1h is never re-bucketed to local hours.
- **D4** — 1h range edges include overlapping UTC hours as-is; the requested
  range is not silently rounded; actual UTC bucket boundaries are displayed
  converted to site-local time.
- **D5** — Late-data reconciliation is bounded to 35 days (failed-message
  recovery can re-normalize rows up to the 30-day `raw_message_failures`
  retention). Writes into compressed chunks are acceptable; the window is
  not expanded.
- **D6** — The Energy retention cuts (M9 in the plan) are an irreversible
  deployment gate: full staging validation, inspection of the oldest
  production rows in every affected Energy tier, before/after
  reconciliation, verification that no required consumer depends on data
  beyond the new retention, and explicit approval before applying.

### Scope separation
`/analytics/series` and the move of the Grafana Explorer to `asset_points`
attribution are separate workstreams, not part of the backbone migrations.

## M1 implementation (migration 264)

`analytics.point_telemetry_15m`: continuous aggregate over
`telemetry.normalized_points`, UTC `time_bucket('15 minutes', …)`, grouped by
organization/site/device/logical point, over `numeric_value IS NOT NULL AND
quality_code = 'GOOD'` samples.

- Refresh: two disjoint, bounded policies: `[now-2d, now-1m)` every 5
  minutes, and `[now-35d, now-2d)` daily (first run at 21:30 UTC) for
  late/recovered data. Refresh is invalidation-driven and batched (10
  buckets per committed batch by default).
- Retention: 120 days. No compression. `materialized_only = true`.
- `analytics.backfill_point_telemetry_15m(p_from, p_to, p_slice)`: the only
  sanctioned manual refresh. It requires explicit, 15-minute-aligned,
  non-future bounds, refreshes in committed slices, and refuses any slice
  that starts before the oldest retained `normalized_points` chunk. Top-level
  `CALL` only; EXECUTE is granted to `ems_admin` only.
- Grants: SELECT to `ems_app` and `ems_readonly`; **not** `grafana_reader`,
  because the aggregate is not tenant-scoped.
- Additive only: the legacy `generic_telemetry_*` aggregates, the Explorer,
  Energy tiers and `normalized_points` retention are unchanged.

**Analytical aggregate contract (approved 2026-09-24):** the aggregate
includes only samples with `quality_code = 'GOOD'` and a non-null
`numeric_value`. `sample_count` is the number of usable contributing
measurements, not received messages. Evidence (read-only, staging): both
`normalized_points` writers derive `quality_code` as `MISSING` (value
absent), `INVALID_NUMERIC` (unparseable numeric value) or `GOOD`, and
`numeric_value` is non-null only when the value parses. So every non-GOOD row
has a NULL value. No existing path aggregates non-GOOD samples, and the
Energy routing layer requires `GOOD` on all 59 value fields. Partial
coverage, gaps and data availability are handled by the downstream analytical
read layer, not by this tier. The filter cannot change later without a
rebuild, and a rebuild recovers only 90 days of raw telemetry.

## Consequences

- Old site-local hourly behaviour in `analytics.v_energy_reporting_hourly`
  (canonical Energy read, Grafana asset-overview) becomes UTC hours when
  that read is repointed. This is a visible change, planned for a later step.
- `telemetry.ca_energy_daily` / `ca_energy_phase_power_daily` bucket in a
  hard-coded `Asia/Kolkata` and must be addressed before a non-IST site is
  onboarded. This is outside the backbone migrations.
- Frontend defects to fix under this model (separate web change):
  `web/src/time/ranges.ts` `resolveRange("TODAY")` uses UTC midnight; the
  offset-at-noon logic in `startOfDayInTimeZone` / `siteLocalDateToUtcInstant`
  is off by an hour for midnight on DST-transition days.
