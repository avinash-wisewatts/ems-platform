# Reports export — production readiness (migrations 309 and 312)

Status: OPEN — not ready for production · Prepared: 2026-10-25 · Owner: Product + Engineering
Feature: [07-features/export](../07-features/export/README.md) · Decisions: [ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md) (Amendments 2 and 3)

The Reports tab (site measurement export, migration 309) and its asset
selection and 14-day 1-minute export (migration 312) are deployed and
accepted on **staging only**. Every item below must be closed, or explicitly
waived by the named owner, before either migration or the app/web image
that uses them is promoted to production. Nothing here has been run against
production.

## Checklist

| # | Item | Owner | State |
|---|---|---|---|
| 1 | **Per-cell data quality (ADR-014 decisions 3, 10, 11).** Decision 3 requires data-quality/freshness information wherever it matters for interpreting a figure; decisions 10 and 11 require gaps and no-data metrics to carry their data-quality state. The export carries none: a gap is an empty cell, and an asset with no data is a header-only CSV. Choose one: **(a)** accept empty cells and amend ADR-014 to say so; **(b)** add a quality column per value column (e.g. `GOOD` / `PARTIAL` / `GAP`), which doubles the columns and roughly doubles file size and cell count; or **(c)** add one row-level status column per CSV (any gap in the row). | Product Owner | **Decision required** |
| 2 | **Production performance of the 1-minute read.** Time the migration 312 query read-only against production data (procedure below). Pass criteria: every sampled asset under 30 s for 14 days; no backend restart; production `available` memory does not drop by more than 200 MB during the run. | Engineering, with explicit production read-only authorization | **Not run** — needs authorization |
| 3 | **Release sequencing.** Production's ledger head is behind staging (migrations 299 onwards are staging-only, per the production release plan). 309 and 312 need their own release batch, or an explicit place in the 299+ plan. The runner applies every unrecorded manifest migration in order, so promoting the 312 image also applies every staging-only migration before it. | Release owner | **Decision required** |
| 4 | **Production storage.** ZIPs live in `analytics.report_export_files` (`bytea`) until they expire (default 24 h). A 9-asset, 14-day 1-minute export was 18.3 MB on staging. With the default 3 active jobs per user, the worst case is roughly users x 3 x ~20 MB, held for 24 h. Confirm production disk headroom and whether `EMS_REPORT_EXPORT_RETENTION_HOURS` / `EMS_REPORT_EXPORT_MAX_ACTIVE_JOBS` should be lower there. | Engineering + Product | Check before release |
| 5 | **Production worker memory.** The worker builds one asset at a time: about 1 M cells per asset for a 14-day 1-minute export, a few hundred MB peak in the admin-portal process. Confirm the production host's free memory, or keep 14-day 1-minute behind a lower `EMS_REPORT_EXPORT_MAX_CELLS` until measured. | Engineering | Check before release |
| 6 | **10-asset export.** The largest verified UI export is **9 assets** (staging, 2 min 52 s, 18.3 MB). A 10-asset export has not been run; its time (about 3 min 10 s) and size (about 20 MB) are **estimates**. Accept the estimate, or run one 10-asset export as part of production acceptance. | Product Owner | Decision (accept the estimate or test) |
| 7 | **Second-user isolation in a live environment.** Staging has one active portal user, so owner-only jobs and other-organization isolation have been proven only by the real-database tests (CI). Optionally create a second staging portal user and confirm 404 on another user's job and file. | Product Owner / Engineering | Optional |
| 8 | **Production UI acceptance**, after release: immediate and background export, a 14-day 1-minute export, download, expiry, notification. | Product Owner | After release |

## Item 2 — read-only 1-minute timing on production

Migration 312 does not exist on production, so the timing runs the
**function's own SQL as a plain SELECT**, exactly as it was run on staging
before deployment (Chiller1, 38 points x 14 days, 10.2 s; after deployment
the function took 10.7 s). It reads; it creates and changes nothing.

Rules (from the staging crash lesson, 2026-10-09): one asset per statement;
`default_transaction_read_only`; `statement_timeout` 120 s; check memory
before; stop at the first timeout or dropped connection, then check
`pg_postmaster_start_time()`. Run off-peak. Choose 2–3 assets with the most
bound points (a meter and an AirSense-equipped AHU).

```sql
SET default_transaction_read_only = on;
SET statement_timeout = '120s';
SET lock_timeout = '2s';
SELECT pg_postmaster_start_time();   -- record before and after
\set aid '<asset uuid>'
\timing on
WITH points AS (
    SELECT row_number() OVER (ORDER BY lp)::int AS idx, lp AS point FROM (
      SELECT DISTINCT ap.logical_point_id AS lp
      FROM metadata.asset_points ap JOIN metadata.devices d ON d.id = ap.device_id
      WHERE ap.asset_id = :'aid'
        AND NOT EXISTS (SELECT 1 FROM config.energy_register_semantics ers
                        WHERE ers.profile_id = d.profile_id AND ers.logical_point_id = ap.logical_point_id
                          AND ers.is_active)) x
),
g AS (SELECT date_bin('1 minute', now() - interval '14 days', '2000-01-01'::timestamptz) AS gf,
             date_bin('1 minute', now(), '2000-01-01'::timestamptz) + interval '1 minute' AS gt),
windows AS MATERIALIZED (
    SELECT pt.idx, ap.device_id AS w_device, ap.logical_point_id AS w_point,
           GREATEST(ap.effective_from, g.gf) AS w_from,
           LEAST(COALESCE(ap.effective_to, 'infinity'::timestamptz), g.gt) AS w_to,
           sc.scale AS w_scale, sc.value_offset AS w_offset
    FROM points pt CROSS JOIN g
    JOIN metadata.asset_points ap ON ap.asset_id = :'aid' AND ap.logical_point_id = pt.point
    CROSS JOIN LATERAL analytics.analytics_point_source_scale(ap.device_id, ap.logical_point_id) sc
    WHERE ap.effective_from < g.gt AND (ap.effective_to IS NULL OR ap.effective_to > g.gf)
),
devices AS MATERIALIZED (
    SELECT w_device AS d_device, MIN(w_from) d_from, MAX(w_to) d_to, array_agg(DISTINCT w_point) d_points
    FROM windows GROUP BY w_device
),
samples AS (
    SELECT w.idx, date_bin('1 minute', x.t, '2000-01-01'::timestamptz) AS s_bucket,
           CASE WHEN x.good THEN x.v * w.w_scale + w.w_offset END AS s_value
    FROM devices d
    CROSS JOIN LATERAL (
        SELECT np.logical_point_id AS point, np.event_time AS t, np.numeric_value AS v,
               np.quality_code = 'GOOD' AS good
        FROM telemetry.normalized_points np
        WHERE np.device_id = d.d_device AND np.event_time >= d.d_from AND np.event_time < d.d_to
          AND np.logical_point_id = ANY (d.d_points) AND np.numeric_value IS NOT NULL
        OFFSET 0) x
    JOIN windows w ON w.w_device = d.d_device AND w.w_point = x.point
                  AND x.t >= w.w_from AND x.t < w.w_to
),
minute_values AS (
    SELECT s_bucket, idx, AVG(s_value)::double precision AS value
    FROM samples GROUP BY 1, 2 HAVING COUNT(s_value) > 0
),
out AS (
    SELECT s_bucket, array_agg(idx ORDER BY idx) i, array_agg(value ORDER BY idx) v
    FROM minute_values GROUP BY s_bucket
)
SELECT (SELECT count(*) FROM points) AS points, count(*) AS minute_rows,
       sum(cardinality(v)) AS "values", min(s_bucket), max(s_bucket)
FROM out;
```

`analytics.analytics_point_source_scale` (migration 292) and
`normalized_points` retention of 90 days or more must exist on production
first. Check with `to_regprocedure('analytics.analytics_point_source_scale(uuid, uuid)')`
and the retention job before running.

Record per asset: points, minute rows, values, duration, and free memory
before and after. Copy the results into this document and the feature doc.

## Decisions required before any production release

1. **Product Owner:** per-cell data quality (item 1: a, b or c).
2. **Product Owner:** accept the 10-asset estimate or require a 10-asset test (item 6).
3. **Release owner:** where 309 + 312 sit in the production migration sequence (item 3).
4. **User/operator:** authorize the read-only production timing (item 2), or run it themselves.
5. **Engineering + Product:** production retention and size limits (items 4 and 5).
