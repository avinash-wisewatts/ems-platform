-- ============================================================================
-- Migration 214
-- Phase 2 Foundation, Phase 1 companion: operator pipeline-health surface.
--
--   analytics.v_pipeline_health
--
-- A READ-ONLY, SYSTEM/OPERATOR-SCOPED view. One row per reconciliation domain
-- (the seven 213 tiers). It EXPOSES the failure modes that motivated migrations
-- 209-213; it does NOT repair anything.
--
-- HARD CONSTRAINTS (enforced by this file + the 214 contract test):
--   - No INSERT / UPDATE / DELETE. It is a plain view.
--   - No CALL of any refresh_* / reconcile_* procedure.
--   - No public.refresh_continuous_aggregate().
--   - No write to telemetry.pipeline_state or analytics.pipeline_reconciliation_log.
--   - No advisory / blocking locks. No reconciliation detector is run.
--   - No new index, no new table, no new job, no config-table dependency.
--
-- EVIDENCE SOURCES (all already persisted; all cheap):
--   - telemetry.pipeline_state                         (209/210/211 forward checkpoint)
--   - analytics.pipeline_reconciliation_log            (213; latest run per tier + a
--                                                       bounded last-10-rows window)
--   - timescaledb_information.jobs / .job_stats        (schedule / runtime / status)
--   - analytics.cagg_available_through(regclass)       (209; CAGG materialisation
--                                                       watermark, NULL if never
--                                                       materialised)
--   - scalar MAX(time_column) on ca_energy_1min / ca_energy_5min /
--     energy_measurements / environment_measurements / energy_consumption_1min /
--     _5min / _15min  -> newest-chunk access only
--   - config.telemetry_capture_policies                (overshoot safety margin)
--
-- HEALTH MODEL - four EXPLICIT dimensions, never collapsed to one opaque field:
--   forward_state    : the forward pipeline right now (pipeline_state + job meta)
--   reconcile_state  : the 213 trailing re-drive for this tier (reconciliation log)
--   integrity_risk   : data-integrity risk not visible in the other two
--   health           : overall roll-up (ERROR > WARNING > UNKNOWN > OK)
--
-- THRESHOLDS are derived from each job's own schedule_interval / max_runtime /
-- max_catchup_window (NOT a new config table). The only constants are documented
-- "missed-cadence" multipliers:
--   k_fwd = 4   : forward STALE  = checkpoint age > 4 x forward schedule_interval
--                                                    + forward max_catchup_window
--   k_run = 2   : forward RUNNING_STALE = RUNNING for > 2 x forward max_runtime
--   k_rec = 3   : reconcile STALE = last run age > 3 x reconcile schedule_interval
--   BACKLOGGED / CONTENDED / PERSISTENT_DEFICIT are pure evidence (2 or 3
--   consecutive log rows), no age threshold.
--
-- CAGG OVERSHOOT (energy_consumption_1min / _5min only). ca_energy_1min and
-- ca_energy_5min are materialized_only with a 1-minute end_offset, so
-- cagg_available_through(ca) legitimately trails "now" and legitimately runs
-- AHEAD of the newest STABLE source bucket by up to one correction window
-- (capture_interval + late_arrival_tolerance) plus the end_offset plus routing
-- latency. The naive  watermark - max(source) > 0  test would fire constantly.
-- The margin used here:
--   overshoot_margin = MAX(capture_interval_seconds + late_arrival_tolerance_seconds)
--                          over enabled config.telemetry_capture_policies
--                    + CAGG end_offset            (from the refresh-policy config)
--                    + 2 x run_energy_routing_job schedule_interval
--                    + 120 s safety pad
-- With current data that is ~21 minutes. CAGG_OVERSHOOT is a WARNING: the 213
-- reconcile self-heals it within one reconcile cycle once source lands.
--
-- OLDER-BACKFILL LIMITATION (energy_consumption_1min / _5min). Source corrected
-- OLDER than the CAGG start_offset (2d / 7d) is re-materialised by neither the
-- automatic CAGG policy nor the 213 reconcile (whose window is also the
-- start_offset). A local probe of
-- _timescaledb_catalog.continuous_aggs_materialization_invalidation_log (C2)
-- found it is NOT a trustworthy persisted signal on TimescaleDB 2.29.2 (bootstrap
-- sentinel rows for every CAGG even on an empty database; internal-integer time;
-- entries merged/consumed on refresh; no compatibility guarantee). Therefore
-- 214 does NOT claim to detect it: integrity_risk = 'OLDER_BACKFILL_UNKNOWN' for
-- the two native tiers whenever no higher-precedence risk applies, and
-- older_backfill_horizon exposes the latest reconcile window_start (the point
-- below which automated repair provably cannot see). The operator diagnostic is
-- in docs/platform-manual/19-operations-and-diagnostics.md.
--
-- NOT TOUCHED by this migration: migrations 209-213; any refresh_* body; any
-- run_*_job wrapper; any reconcile_* procedure; the reconcile jobs; the forward
-- jobs; telemetry.pipeline_state; analytics.pipeline_reconciliation_log; any CAGG
-- or CAGG policy; retention / compression; routing; normalization; Grafana;
-- application / API code; tenant-isolation mechanisms. No tenant columns are
-- added (this view describes platform-global machinery; a stalled job affects
-- every tenant identically). SELECT is granted to grafana_reader ONLY - the sole
-- role with USAGE on schema analytics and the reader of every existing
-- analytics.v_* view (ems_readonly has no analytics-schema USAGE, so the 214
-- audit's "ems_readonly + grafana_reader" plan is corrected to grafana_reader
-- only). This is NOT a v_grafana_* tenant view and carries no grafana_org_id;
-- it is an operator/admin surface and must not be wired into tenant dashboards.
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW analytics.v_pipeline_health AS
WITH tiers (pipeline, domain, forward_job, reconcile_job, cagg_name) AS (
    VALUES
      ('energy_consumption_1min',  'energy',      'analytics.run_energy_consumption_1min_job',   'analytics.reconcile_energy_consumption_1min',   'telemetry.ca_energy_1min'),
      ('energy_consumption_5min',  'energy',      'analytics.run_energy_consumption_5min_job',   'analytics.reconcile_energy_consumption_5min',   'telemetry.ca_energy_5min'),
      ('energy_consumption_15min', 'energy',      'analytics.run_energy_consumption_15min_job',  'analytics.reconcile_energy_consumption_15min',  NULL),
      ('energy_consumption_hourly','energy',      'analytics.run_energy_consumption_hourly_job', 'analytics.reconcile_energy_consumption_hourly', NULL),
      ('energy_consumption_daily', 'energy',      'analytics.run_energy_consumption_daily_job',  'analytics.reconcile_energy_consumption_daily',  NULL),
      ('demand_intervals',         'demand',      'analytics.run_demand_calculation_job',        'analytics.reconcile_demand_intervals',          NULL),
      ('environment_daily',        'environment', 'telemetry.run_environment_daily_job',         'telemetry.reconcile_environment_daily',         NULL)
),
fwd AS (
    SELECT pipeline_name, last_received_at, last_status, last_started_at, updated_at
    FROM telemetry.pipeline_state
),
jobmeta AS (
    SELECT proc_schema || '.' || proc_name AS job_name,
           schedule_interval,
           max_runtime,
           NULLIF(config ->> 'max_catchup_window', '')::interval AS max_catchup_window
    FROM timescaledb_information.jobs
    WHERE proc_name ~ '^(run_energy_consumption_|run_demand_calculation_job|run_environment_daily_job|reconcile_)'
),
jobstats AS (
    SELECT j.proc_schema || '.' || j.proc_name AS job_name,
           js.job_status, js.last_run_status, js.last_successful_finish, js.next_start
    FROM timescaledb_information.jobs j
    JOIN timescaledb_information.job_stats js USING (job_id)
    WHERE j.proc_name ~ '^reconcile_'
),
rec_latest AS (
    SELECT DISTINCT ON (tier)
           tier, ran_at, window_start, window_end, outcome,
           rows_repaired, error_count, first_error_sqlstate
    FROM analytics.pipeline_reconciliation_log
    ORDER BY tier, ran_at DESC
),
rec_recent AS (
    SELECT tier,
           count(*)                                                            AS recent_run_count,
           count(*) FILTER (WHERE rn <= 3 AND rows_repaired > 0)              AS recent_repaired_runs,
           count(*) FILTER (WHERE rn <= 3 AND outcome = 'PARTIAL')           AS recent_partial_runs,
           count(*) FILTER (WHERE rn <= 3 AND outcome = 'SKIPPED_LOCKED')    AS recent_skipped_runs,
           max(outcome) FILTER (WHERE rn = 2)                                 AS prev_outcome
    FROM (
        SELECT tier, outcome, rows_repaired,
               row_number() OVER (PARTITION BY tier ORDER BY ran_at DESC) AS rn
        FROM analytics.pipeline_reconciliation_log
    ) s
    WHERE rn <= 10
    GROUP BY tier
),
cagg AS (
    -- CAGG materialisation watermark read INLINE from the TSDB catalog by
    -- schema/name (NOT via analytics.cagg_available_through, and NOT via a
    -- text::regclass cast): cagg_available_through is SECURITY INVOKER and its
    -- internal format(...)::regclass needs USAGE ON SCHEMA telemetry, which
    -- grafana_reader (the intended reader of this view) does not have. The
    -- logic is otherwise identical: convert the internal integer watermark and
    -- NULLIF the "never materialised" -infinity sentinel. This inline read is
    -- evaluated with the view owner's privileges.
    SELECT v.cagg_name,
           NULLIF(_timescaledb_functions.to_timestamp(w.watermark),
                  '4714-11-24 00:00:00+00 BC'::timestamptz) AS watermark,
           p.start_offset,
           p.end_offset
    FROM (VALUES
            ('telemetry.ca_energy_1min', 'ca_energy_1min'),
            ('telemetry.ca_energy_5min', 'ca_energy_5min')
         ) v(cagg_name, hypertable_name)
    LEFT JOIN _timescaledb_catalog.continuous_agg ca
           ON ca.user_view_schema = 'telemetry'
          AND ca.user_view_name = v.hypertable_name
    LEFT JOIN _timescaledb_catalog.continuous_aggs_watermark w
           ON w.mat_hypertable_id = ca.mat_hypertable_id
    LEFT JOIN (
        SELECT hypertable_name,
               (config ->> 'start_offset')::interval AS start_offset,
               (config ->> 'end_offset')::interval   AS end_offset
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_refresh_continuous_aggregate'
          AND hypertable_name IN ('ca_energy_1min', 'ca_energy_5min')
    ) p ON p.hypertable_name = v.hypertable_name
),
routing AS (
    SELECT min(schedule_interval) AS routing_sched
    FROM timescaledb_information.jobs
    WHERE proc_name = 'run_energy_routing_job'
),
capture AS (
    SELECT make_interval(secs => COALESCE(
               max(capture_interval_seconds + late_arrival_tolerance_seconds)
                   FILTER (WHERE is_enabled),
               960)) AS correction_window
    FROM config.telemetry_capture_policies
),
src AS (
    SELECT
        (SELECT max(bucket_start) FROM telemetry.energy_measurements)      AS em_max,
        (SELECT max(bucket_start) FROM telemetry.environment_measurements) AS env_max,
        (SELECT max(bucket_start) FROM analytics.energy_consumption_1min)  AS ec1_max,
        (SELECT max(bucket_start) FROM analytics.energy_consumption_5min)  AS ec5_max,
        (SELECT max(bucket_start) FROM analytics.energy_consumption_15min) AS ec15_max
),
assessed AS MATERIALIZED (
    -- MATERIALIZED: force the three axis CASE expressions (and the STABLE
    -- analytics.cagg_available_through calls) to be evaluated exactly once for
    -- the seven rows, so the outer health / health_rank / health_reason
    -- expressions read a compact 7-row result instead of re-inlining every axis.
    SELECT
        t.pipeline,
        t.domain,
        t.forward_job,
        t.reconcile_job,

        -- forward pipeline signals
        f.last_status                                              AS forward_last_status,
        f.last_received_at                                         AS forward_checkpoint,
        (now() - f.last_received_at)                               AS forward_checkpoint_age,
        f.updated_at                                               AS forward_last_run_at,

        -- reconciliation signals (latest run for the tier)
        rl.outcome                                                 AS reconcile_last_outcome,
        rl.ran_at                                                  AS reconcile_last_ran_at,
        (now() - rl.ran_at)                                        AS reconcile_last_age,
        rl.window_start                                            AS reconcile_window_start,
        rl.window_end                                              AS reconcile_window_end,
        rl.rows_repaired                                           AS reconcile_last_rows_repaired,
        rl.first_error_sqlstate                                    AS reconcile_last_error_sqlstate,
        (COALESCE(rl.error_count, 0) > 0)                          AS reconcile_has_error,
        COALESCE(rr.recent_run_count, 0)::smallint                 AS reconcile_recent_run_count,
        COALESCE(rr.recent_repaired_runs, 0)::smallint             AS reconcile_recent_repaired_runs,
        COALESCE(rr.recent_partial_runs, 0)::smallint              AS reconcile_recent_partial_runs,
        COALESCE(rr.recent_skipped_runs, 0)::smallint              AS reconcile_recent_skipped_runs,
        jsr.job_status                                             AS reconcile_job_status,
        jsr.last_run_status                                        AS reconcile_job_last_run_status,
        jsr.next_start                                             AS reconcile_job_next_start,

        -- CAGG / source frontier (native tiers only)
        t.cagg_name,
        cg.start_offset                                            AS cagg_start_offset,
        cg.watermark                                               AS cagg_watermark,
        CASE t.pipeline
            WHEN 'energy_consumption_1min'   THEN s.em_max
            WHEN 'energy_consumption_5min'   THEN s.em_max
            WHEN 'energy_consumption_15min'  THEN GREATEST(s.ec1_max, s.ec5_max)
            WHEN 'energy_consumption_hourly' THEN s.ec15_max
            WHEN 'energy_consumption_daily'  THEN s.ec15_max
            WHEN 'demand_intervals'          THEN s.em_max
            WHEN 'environment_daily'         THEN s.env_max
        END                                                       AS source_max_bucket,
        CASE WHEN t.cagg_name IS NOT NULL THEN cg.watermark - s.em_max END
                                                                  AS cagg_overshoot,
        CASE WHEN t.cagg_name IS NOT NULL
             THEN cap.correction_window + COALESCE(cg.end_offset, interval '1 minute')
                  + (COALESCE(rt.routing_sched, interval '1 minute') * 2)
                  + interval '120 seconds'
        END                                                       AS cagg_overshoot_margin,
        CASE WHEN t.cagg_name IS NOT NULL THEN rl.window_start END AS older_backfill_horizon,

        -- ---- dimension A: forward_state ----
        CASE
            WHEN f.last_received_at IS NULL THEN 'NOT_INITIALIZED'
            WHEN f.last_status = 'FAILED' THEN 'FAILED'
            WHEN f.last_status = 'RUNNING'
                 AND f.last_started_at IS NOT NULL
                 AND now() - f.last_started_at > jm_f.max_runtime * 2 THEN 'RUNNING_STALE'
            WHEN now() - f.last_received_at
                 > jm_f.schedule_interval * 4 + COALESCE(jm_f.max_catchup_window, interval '0') THEN 'STALE'
            WHEN f.last_status = 'NO_SOURCE_DATA' THEN 'NO_SOURCE_DATA'
            WHEN f.last_status = 'RUNNING' THEN 'RUNNING'
            ELSE 'OK'
        END                                                       AS forward_state,

        -- ---- dimension B: reconcile_state ----
        CASE
            WHEN rl.outcome IS NULL THEN 'NOT_INITIALIZED'
            WHEN rl.outcome = 'NO_CHECKPOINT' THEN 'NOT_INITIALIZED'
            WHEN rl.outcome = 'FAILED' THEN 'FAILED'
            WHEN jsr.job_status = 'Paused' THEN 'STALE'
            WHEN now() - rl.ran_at > jm_r.schedule_interval * 3 THEN 'STALE'
            WHEN rl.outcome = 'PARTIAL' AND rr.prev_outcome = 'PARTIAL' THEN 'BACKLOGGED'
            WHEN COALESCE(rr.recent_skipped_runs, 0) >= 3 THEN 'CONTENDED'
            WHEN rl.outcome = 'PARTIAL' THEN 'PARTIAL'
            WHEN rl.outcome = 'SKIPPED_LOCKED' THEN 'SKIPPED_LOCKED'
            ELSE 'OK'
        END                                                       AS reconcile_state,

        -- ---- dimension C: integrity_risk ----
        CASE
            WHEN t.domain <> 'energy' THEN 'N/A'
            WHEN COALESCE(rr.recent_repaired_runs, 0) >= 3 THEN 'PERSISTENT_DEFICIT'
            WHEN t.cagg_name IS NOT NULL
                 AND cg.watermark IS NOT NULL
                 AND s.em_max IS NOT NULL
                 AND (cg.watermark - s.em_max)
                     > cap.correction_window + COALESCE(cg.end_offset, interval '1 minute')
                       + (COALESCE(rt.routing_sched, interval '1 minute') * 2)
                       + interval '120 seconds'
                 THEN 'CAGG_OVERSHOOT'
            WHEN t.cagg_name IS NOT NULL THEN 'OLDER_BACKFILL_UNKNOWN'
            ELSE 'OK'
        END                                                       AS integrity_risk,

        now()                                                     AS evaluated_at

    FROM tiers t
    LEFT JOIN fwd f        ON f.pipeline_name = t.pipeline
    LEFT JOIN rec_latest rl ON rl.tier        = t.pipeline
    LEFT JOIN rec_recent rr ON rr.tier        = t.pipeline
    LEFT JOIN jobmeta jm_f  ON jm_f.job_name  = t.forward_job
    LEFT JOIN jobmeta jm_r  ON jm_r.job_name  = t.reconcile_job
    LEFT JOIN jobstats jsr  ON jsr.job_name   = t.reconcile_job
    LEFT JOIN cagg cg       ON cg.cagg_name   = t.cagg_name
    CROSS JOIN routing rt
    CROSS JOIN capture cap
    CROSS JOIN src s
)
SELECT
    a.*,
    CASE
        WHEN a.forward_state IN ('FAILED', 'RUNNING_STALE')
          OR a.reconcile_state IN ('FAILED', 'STALE')
          OR a.integrity_risk = 'PERSISTENT_DEFICIT'
            THEN 'ERROR'
        WHEN a.forward_state = 'STALE'
          OR a.reconcile_state IN ('BACKLOGGED', 'CONTENDED')
          OR a.integrity_risk = 'CAGG_OVERSHOOT'
            THEN 'WARNING'
        WHEN a.forward_state = 'NOT_INITIALIZED'
          OR a.reconcile_state = 'NOT_INITIALIZED'
          OR a.integrity_risk = 'OLDER_BACKFILL_UNKNOWN'
            THEN 'UNKNOWN'
        ELSE 'OK'
    END                                                           AS health,
    CASE
        WHEN a.forward_state IN ('FAILED', 'RUNNING_STALE')
          OR a.reconcile_state IN ('FAILED', 'STALE')
          OR a.integrity_risk = 'PERSISTENT_DEFICIT'
            THEN 3
        WHEN a.forward_state = 'STALE'
          OR a.reconcile_state IN ('BACKLOGGED', 'CONTENDED')
          OR a.integrity_risk = 'CAGG_OVERSHOOT'
            THEN 2
        WHEN a.forward_state = 'NOT_INITIALIZED'
          OR a.reconcile_state = 'NOT_INITIALIZED'
          OR a.integrity_risk = 'OLDER_BACKFILL_UNKNOWN'
            THEN 1
        ELSE 0
    END::smallint                                                 AS health_rank,
    COALESCE(NULLIF(concat_ws('; ',
        CASE WHEN a.forward_state <> 'OK'
             THEN 'forward=' || a.forward_state END,
        CASE WHEN a.reconcile_state <> 'OK'
             THEN 'reconcile=' || a.reconcile_state
                  || COALESCE(' (sqlstate ' || a.reconcile_last_error_sqlstate || ')', '') END,
        CASE WHEN a.integrity_risk NOT IN ('OK', 'N/A')
             THEN 'integrity=' || a.integrity_risk
                  || CASE WHEN a.integrity_risk = 'CAGG_OVERSHOOT'
                          THEN ' (watermark ahead of source by ' || a.cagg_overshoot::text || ')'
                          WHEN a.integrity_risk = 'OLDER_BACKFILL_UNKNOWN'
                          THEN ' (not detectable in-view; run the source-vs-child diagnostic, see 19-operations-and-diagnostics.md)'
                          ELSE '' END END
    ), ''), 'all clear')                                          AS health_reason
FROM assessed a
ORDER BY health_rank DESC, a.domain, a.pipeline;

ALTER VIEW analytics.v_pipeline_health OWNER TO ems_admin;
REVOKE ALL ON analytics.v_pipeline_health FROM PUBLIC;
-- grafana_reader ONLY: it is the sole role with USAGE ON SCHEMA analytics and is
-- the reader of every existing analytics.v_* view. ems_readonly has no USAGE on
-- schema analytics and cannot query any analytics view, so a grant to it would
-- be inert (the 213 ems_readonly grant on pipeline_reconciliation_log is
-- likewise inert; not corrected here). This view is an operator/admin surface;
-- it must NOT be added to any tenant-facing Grafana dashboard.
GRANT SELECT ON analytics.v_pipeline_health TO grafana_reader;

COMMENT ON VIEW analytics.v_pipeline_health IS
'Migration 214: read-only, SYSTEM/OPERATOR-scoped health surface for the seven analytical reconciliation domains (209-213). One row per pipeline. Four explicit dimensions: forward_state (telemetry.pipeline_state + job meta), reconcile_state (analytics.pipeline_reconciliation_log latest run + last-10 window), integrity_risk (CAGG overshoot / persistent deficit / older-backfill-unknown), health (ERROR>WARNING>UNKNOWN>OK). Thresholds derived from each job schedule_interval / max_runtime / max_catchup_window with documented missed-cadence multipliers k_fwd=4, k_run=2, k_rec=3; BACKLOGGED/CONTENDED/PERSISTENT_DEFICIT are consecutive-log-row evidence. CAGG overshoot logic applies to energy_consumption_1min/_5min only, with a safety margin = enabled-capture-policy correction window + CAGG end_offset + 2x routing schedule + 120s. Source backfilled older than the CAGG start_offset is NOT detectable here (integrity_risk=OLDER_BACKFILL_UNKNOWN + older_backfill_horizon + operator diagnostic in 19-operations-and-diagnostics.md). The CAGG watermark is read inline from _timescaledb_catalog by name (not via analytics.cagg_available_through, which is SECURITY INVOKER and needs telemetry-schema USAGE). Never writes any table, never CALLs a repair proc, never refresh_continuous_aggregate, never advances a checkpoint, never locks. No tenant columns: pipeline machinery is platform-global. Not a v_grafana_* view; SELECT granted to grafana_reader only (operator/admin dashboard) - do NOT wire into tenant dashboards.';

COMMIT;
