-- ============================================================================
-- Migration 213
-- Phase 2 Foundation, Phase 1 (4/4): analytical reconciliation layer.
--
-- The forward pipeline (209 energy cascade, 210 demand, 211 environment_daily)
-- advances telemetry.pipeline_state.last_received_at only over a contiguous
-- bounded slice and rolls the whole run back atomically on failure. Three
-- classes of sub-checkpoint hole are still unhandled:
--   G1  late source corrected/backfilled BELOW the checkpoint after the
--       forward run passed that bucket;
--   G2  ca_energy_1min / ca_energy_5min materialisation-watermark OVERSHOOT
--       (the CAGG refresh policy advances the scalar watermark across empty
--       source periods; the forward child then advances its checkpoint over a
--       range that has no CAGG rows, and never re-reads it once source arrives);
--   G3  a retroactive effective-dated config change, or a bad manual write,
--       that changes the correct value of already-finalised rows.
-- A high-water mark cannot see any of these.
--
-- Migration 213 adds a bounded, observable, idempotent TRAILING RE-DRIVE that
-- repairs G1-G3 WITHOUT advancing any forward checkpoint. It is a corrective
-- safety net, NOT a second forward pipeline.
--
-- ARCHITECTURE (Option C, per the "N1 + Reconciliation Architecture Redesign
-- Audit v2" and the "Migration 213 Pre-Implementation Reconciliation Audit"):
--
--   1. analytics.pipeline_reconciliation_log      -- hypertable, 180d retention,
--                                                    ONE row per reconcile run.
--   2. config.assert_reconciliation_job_config    -- check_config validator for
--                                                    {reconcile_window, coarse,
--                                                     n_max, lookback}.
--   3. analytics.reconcile_energy_deficits(...)   -- READ-ONLY per-tier deficit
--                                                    detector for the 4
--                                                    helper-driven energy tiers
--                                                    (1min/5min/15min/hourly).
--   4. analytics.record_reconciliation_run(...)   -- shared log-writer (infra).
--   5. SEVEN tier-specific reconcile procedures:
--        analytics.reconcile_energy_consumption_1min / _5min / _15min / _hourly
--                                                    (helper detector + n_max
--                                                     coarse-bucket re-drive of
--                                                     the EXISTING refresh fn),
--        analytics.reconcile_energy_consumption_daily (INLINE site-local-day
--                                                     detector),
--        analytics.reconcile_demand_intervals        (CALL the EXISTING 4-arg
--                                                     refresh_demand_analytics
--                                                     with p_finalize_from/to),
--        telemetry.reconcile_environment_daily       (INLINE site-local-day
--                                                     detector + the EXISTING
--                                                     refresh_environment_daily).
--   6. SEVEN reconcile jobs, offset cadences (1min/5min/demand 1h; 15min 6h;
--      hourly 12h; daily/env 24h), each taking the SAME transaction-scoped
--      advisory key as its FORWARD job -> a reconcile and its forward job (and
--      two reconcile runs of the same tier) can never run concurrently; the
--      loser records SKIPPED_LOCKED. Finite max_runtime / max_retries=3 /
--      retry_period. n_max ships CONSERVATIVE (energy 6, environment_daily 8);
--      raise via alter_job after observing the log.
--   7. N2: analytics.run_energy_consumption_15min_job config.reconcile_window
--      3 days -> 8 days (15min consumes energy_consumption_1min UNION ALL
--      energy_consumption_5min; a ca_energy_5min-fed 5min repair can be up to
--      ca_energy_5min's 7-day start_offset old).
--
-- HARD INVARIANTS enforced here and by the 213 contract test:
--   - NO reconcile object contains an assignment to
--     telemetry.pipeline_state.last_received_at (direct OR indirect: none of
--     the seven calculation functions writes pipeline_state -- only the seven
--     forward wrappers + five telemetry loaders do; the reconcile procs call
--     the calculation functions, never the run_*_job wrappers).
--   - NO reconcile object calls public.refresh_continuous_aggregate (the v2
--     probe proved it is rejected inside any transaction / subtransaction on
--     TimescaleDB 2.29.2). reconcile_window(1min)=2d and (5min)=7d = the
--     respective CAGG automatic-refresh start_offsets, so the automatic policy
--     keeps the CAGG truthful WITHIN the window. Backfill OLDER than the
--     start_offset is NOT auto-repaired and NOT reported HEALTHY -- it is a
--     documented operator-remediation condition
--     (CALL public.refresh_continuous_aggregate(...) at the top level, then the
--     next reconcile pass repairs the children). Migration 214 (NOT part of
--     this migration) will expose that condition.
--   - Completeness is judged from PERSISTED FINGERPRINTS
--     (energy_consumption_1min/5min.source_sample_count vs ca_energy_*.sample_count;
--      energy_consumption_15min/hourly/daily.source_interval_count and
--      calculated_at recency vs the parent rollup), NEVER from a pipeline_state
--      watermark position.
--   - Each individual refresh_* call is wrapped in a per-coarse-bucket /
--     per-scope BEGIN..EXCEPTION subtransaction: one bucket's failure stops the
--     loop and is logged, but does not roll back the earlier successful
--     re-drives in the same run. The whole reconcile procedure is otherwise a
--     SINGLE transaction with no COMMIT/ROLLBACK -- so on max_runtime
--     cancellation nothing is repaired and nothing advanced.
--
-- NOT touched by this migration: any refresh_* calculation body; any run_*_job
-- forward wrapper; telemetry.pipeline_state schema or rows; any CAGG or CAGG
-- policy; any retention/compression policy on any EXISTING table; the schedule
-- / max_runtime / max_retries / retry_period of any FORWARD job; migration 212;
-- postgres/jobs/*.sql; Grafana; application code; normalization; routing;
-- demand max_catchup_window (stays 6h). Migration 214 (v_pipeline_health) is
-- NOT implemented here. The demand reconcile_window is 6 hours -- the audit's
-- 12h recommendation is CONDITIONAL on a staging cost read (O-D) that has NOT
-- been performed, so the safe approved value (retain 6h) is used and raising it
-- later is an alter_job, not a migration.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. analytics.pipeline_reconciliation_log  -- one row per reconcile run.
-- ----------------------------------------------------------------------------
CREATE TABLE analytics.pipeline_reconciliation_log (
    ran_at                timestamptz  NOT NULL DEFAULT clock_timestamp(),
    run_id                uuid         NOT NULL DEFAULT gen_random_uuid(),
    tier                  text         NOT NULL,
    trigger_reason        text         NOT NULL DEFAULT 'SCHEDULED',
    window_start          timestamptz,
    window_end            timestamptz,
    coarse_examined       integer,
    coarse_mismatch       integer,
    rows_examined         bigint,
    rows_repaired         bigint       NOT NULL DEFAULT 0,
    error_count           integer      NOT NULL DEFAULT 0,
    outcome               text         NOT NULL,
    first_error_sqlstate  text,
    first_error_message   text,
    duration_ms           integer,
    created_at            timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pipeline_reconciliation_log_pkey PRIMARY KEY (run_id, ran_at),
    CONSTRAINT pipeline_reconciliation_log_tier_chk CHECK (tier IN (
        'energy_consumption_1min','energy_consumption_5min','energy_consumption_15min',
        'energy_consumption_hourly','energy_consumption_daily','demand_intervals',
        'environment_daily')),
    CONSTRAINT pipeline_reconciliation_log_trigger_chk CHECK (trigger_reason IN ('SCHEDULED','MANUAL')),
    CONSTRAINT pipeline_reconciliation_log_outcome_chk CHECK (outcome IN (
        'HEALTHY','REPAIRED','PARTIAL','FAILED','SKIPPED_LOCKED','NO_CHECKPOINT'))
);

SELECT create_hypertable('analytics.pipeline_reconciliation_log', 'ran_at',
    chunk_time_interval => INTERVAL '30 days', if_not_exists => TRUE);

CREATE INDEX ix_pipeline_reconciliation_log_tier_time
    ON analytics.pipeline_reconciliation_log (tier, ran_at DESC);

CREATE INDEX ix_pipeline_reconciliation_log_attention
    ON analytics.pipeline_reconciliation_log (tier, ran_at DESC)
    WHERE outcome IN ('FAILED','PARTIAL') OR error_count > 0;

SELECT add_retention_policy('analytics.pipeline_reconciliation_log',
    INTERVAL '180 days', if_not_exists => TRUE);

ALTER TABLE analytics.pipeline_reconciliation_log OWNER TO ems_admin;
REVOKE ALL ON analytics.pipeline_reconciliation_log FROM PUBLIC;
GRANT SELECT ON analytics.pipeline_reconciliation_log TO ems_readonly, grafana_reader;

COMMENT ON TABLE analytics.pipeline_reconciliation_log IS
'Migration 213: one row per analytical reconciliation run (7 tiers x their cadences ~= 80 rows/day). window_start/window_end = [checkpoint - reconcile_window, checkpoint) inspected (NULL for SKIPPED_LOCKED / NO_CHECKPOINT). outcome: HEALTHY (no deficit) | REPAIRED (deficits re-driven) | PARTIAL (hit n_max; remainder next run) | FAILED (a refresh_* raised; first_error_* set; earlier re-drives in the run still committed) | SKIPPED_LOCKED (forward job held the advisory lock) | NO_CHECKPOINT (forward checkpoint still NULL). Reconciliation NEVER advances telemetry.pipeline_state.last_received_at. 180-day retention policy. Migration 214 will read this to expose CAGG-older-than-start_offset and persistent-deficit conditions.';

-- ----------------------------------------------------------------------------
-- 2. config.assert_reconciliation_job_config  -- check_config validator.
--    Mirrors config.assert_analytical_lookback_job_config (migration 208/209).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION config.assert_reconciliation_job_config(config jsonb)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_key  TEXT;
    v_ival INTERVAL;
    v_int  INTEGER;
BEGIN
    IF config IS NULL THEN
        RETURN;
    END IF;

    IF jsonb_typeof(config) <> 'object' THEN
        RAISE EXCEPTION
            'reconciliation job config must be a JSON object; got %', jsonb_typeof(config);
    END IF;

    FOR v_key IN SELECT jsonb_object_keys(config)
    LOOP
        IF v_key NOT IN ('reconcile_window', 'coarse', 'n_max', 'lookback') THEN
            RAISE EXCEPTION
                'reconciliation job config: unrecognised key "%"; allowed keys are reconcile_window, coarse, n_max, lookback',
                v_key;
        END IF;
    END LOOP;

    FOREACH v_key IN ARRAY ARRAY['reconcile_window', 'coarse', 'lookback']
    LOOP
        IF config ? v_key THEN
            BEGIN
                v_ival := (config ->> v_key)::INTERVAL;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION
                    'reconciliation job config: % ("%") is not a valid interval',
                    v_key, config ->> v_key;
            END;
            IF v_ival IS NULL OR v_ival <= INTERVAL '0 seconds' THEN
                RAISE EXCEPTION
                    'reconciliation job config: % must be a positive interval; got "%"',
                    v_key, config ->> v_key;
            END IF;
        END IF;
    END LOOP;

    IF config ? 'n_max' THEN
        BEGIN
            v_int := (config ->> 'n_max')::INTEGER;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION
                'reconciliation job config: n_max ("%") is not an integer',
                config ->> 'n_max';
        END;
        IF v_int IS NULL OR v_int <= 0 THEN
            RAISE EXCEPTION
                'reconciliation job config: n_max must be a positive integer; got "%"',
                config ->> 'n_max';
        END IF;
    END IF;
END;
$function$;

ALTER FUNCTION config.assert_reconciliation_job_config(jsonb) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION config.assert_reconciliation_job_config(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.assert_reconciliation_job_config(jsonb) TO ems_admin;

COMMENT ON FUNCTION config.assert_reconciliation_job_config(jsonb) IS
'Migration 213 check_config validator wired onto the seven analytical reconciliation jobs. Rejects, at add_job/alter_job time, a config that is not a JSON object, carries a key other than reconcile_window / coarse / n_max / lookback, whose interval keys are not positive finite intervals, or whose n_max is not a positive integer.';

-- ----------------------------------------------------------------------------
-- 3. analytics.record_reconciliation_run  -- shared log writer (infrastructure,
--    NOT semantic calculation). Every reconcile procedure ends by calling this
--    exactly once.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.record_reconciliation_run(
    p_run_id            uuid,
    p_tier              text,
    p_started           timestamptz,
    p_window_start      timestamptz,
    p_window_end        timestamptz,
    p_coarse_examined   integer,
    p_coarse_mismatch   integer,
    p_rows_examined     bigint,
    p_rows_repaired     bigint,
    p_error_count       integer,
    p_outcome           text,
    p_first_sqlstate    text,
    p_first_errmsg      text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'analytics'
AS $function$
    INSERT INTO analytics.pipeline_reconciliation_log
        (ran_at, run_id, tier, trigger_reason, window_start, window_end,
         coarse_examined, coarse_mismatch, rows_examined, rows_repaired,
         error_count, outcome, first_error_sqlstate, first_error_message, duration_ms)
    VALUES
        (p_started, p_run_id, p_tier, 'SCHEDULED', p_window_start, p_window_end,
         p_coarse_examined, p_coarse_mismatch, p_rows_examined, COALESCE(p_rows_repaired, 0),
         COALESCE(p_error_count, 0), p_outcome, p_first_sqlstate, p_first_errmsg,
         (EXTRACT(EPOCH FROM (clock_timestamp() - p_started)) * 1000)::integer);
$function$;

ALTER FUNCTION analytics.record_reconciliation_run(uuid,text,timestamptz,timestamptz,timestamptz,integer,integer,bigint,bigint,integer,text,text,text) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.record_reconciliation_run(uuid,text,timestamptz,timestamptz,timestamptz,integer,integer,bigint,bigint,integer,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.record_reconciliation_run(uuid,text,timestamptz,timestamptz,timestamptz,integer,integer,bigint,bigint,integer,text,text,text) TO ems_admin;

COMMENT ON FUNCTION analytics.record_reconciliation_run(uuid,text,timestamptz,timestamptz,timestamptz,integer,integer,bigint,bigint,integer,text,text,text) IS
'Migration 213: writes exactly one analytics.pipeline_reconciliation_log row for a reconcile run and fills duration_ms from p_started. Shared infrastructure; contains no reconciliation logic.';

-- ----------------------------------------------------------------------------
-- 4. analytics.reconcile_energy_deficits  -- READ-ONLY per-tier deficit
--    detector for the four helper-driven energy tiers. Returns the DISTINCT set
--    of coarse buckets that contain at least one (device, tier-bucket) whose
--    persisted fingerprint disagrees with the current parent, oldest first,
--    LIMIT p_limit. NO writes. NO refresh_* call. NO CAGG refresh. NO
--    pipeline_state read.
--
--    Fingerprints (verified against the deployed schema):
--      1min / 5min : child.source_sample_count  vs  ca_energy_{1,5}min.sample_count
--                    per (device_id, bucket_start), WITH the same
--                    resolve_site_capture_bucket capture_interval eligibility
--                    filter the calc function applies (<=60 / =300) so a device
--                    belonging to another native interval is not falsely
--                    flagged.
--      15min       : count(native rows) vs child.source_interval_count, AND a
--                    recompute-recency check max(native.calculated_at) >
--                    child.calculated_at (energy_consumption_15min persists
--                    source_interval_count and calculated_at only -- no
--                    source_sample_count column).
--      hourly      : sum(15min.source_interval_count) vs child.source_interval_count,
--                    AND max(15min.calculated_at) > child.calculated_at.
--    A coarse bucket is flagged only when the PARENT side exists (child missing
--    or fingerprint differs); "child present, parent absent" (SOURCE_RETRACTED
--    -- e.g. source rows dropped by a correction or past retention) is NOT
--    flagged for repair.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.reconcile_energy_deficits(
    p_tier         text,
    p_window_start timestamptz,
    p_window_end   timestamptz,
    p_coarse       interval,
    p_limit        integer
)
RETURNS TABLE (coarse_bucket_start timestamptz, mism_rows bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $function$
BEGIN
    IF p_tier = 'energy_consumption_1min' THEN
        RETURN QUERY
        WITH parent AS (
            SELECT ca.device_id, ca.bucket_start,
                   date_trunc('hour', ca.bucket_start) AS coarse,
                   ca.sample_count::bigint AS p_vol
            FROM telemetry.ca_energy_1min ca
            CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(ca.site_id, ca.bucket_start) rp
            WHERE ca.bucket_start >= p_window_start AND ca.bucket_start < p_window_end
              AND rp.policy_id IS NOT NULL
              AND rp.capture_interval_seconds <= 60
        ),
        child AS (
            SELECT c.device_id, c.bucket_start,
                   date_trunc('hour', c.bucket_start) AS coarse,
                   c.source_sample_count::bigint AS c_vol
            FROM analytics.energy_consumption_1min c
            WHERE c.bucket_start >= p_window_start AND c.bucket_start < p_window_end
        ),
        mism AS (
            SELECT COALESCE(p.coarse, c.coarse) AS coarse
            FROM parent p
            FULL JOIN child c ON p.device_id = c.device_id AND p.bucket_start = c.bucket_start
            WHERE p.device_id IS NOT NULL
              AND (c.device_id IS NULL OR p.p_vol IS DISTINCT FROM c.c_vol)
        )
        SELECT m.coarse, count(*)::bigint
        FROM mism m
        GROUP BY m.coarse
        ORDER BY m.coarse
        LIMIT p_limit;

    ELSIF p_tier = 'energy_consumption_5min' THEN
        RETURN QUERY
        WITH parent AS (
            SELECT ca.device_id, ca.bucket_start,
                   date_trunc('hour', ca.bucket_start) AS coarse,
                   ca.sample_count::bigint AS p_vol
            FROM telemetry.ca_energy_5min ca
            CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(ca.site_id, ca.bucket_start) rp
            WHERE ca.bucket_start >= p_window_start AND ca.bucket_start < p_window_end
              AND rp.policy_id IS NOT NULL
              AND rp.capture_interval_seconds = 300
        ),
        child AS (
            SELECT c.device_id, c.bucket_start,
                   date_trunc('hour', c.bucket_start) AS coarse,
                   c.source_sample_count::bigint AS c_vol
            FROM analytics.energy_consumption_5min c
            WHERE c.bucket_start >= p_window_start AND c.bucket_start < p_window_end
        ),
        mism AS (
            SELECT COALESCE(p.coarse, c.coarse) AS coarse
            FROM parent p
            FULL JOIN child c ON p.device_id = c.device_id AND p.bucket_start = c.bucket_start
            WHERE p.device_id IS NOT NULL
              AND (c.device_id IS NULL OR p.p_vol IS DISTINCT FROM c.c_vol)
        )
        SELECT m.coarse, count(*)::bigint
        FROM mism m
        GROUP BY m.coarse
        ORDER BY m.coarse
        LIMIT p_limit;

    ELSIF p_tier = 'energy_consumption_15min' THEN
        RETURN QUERY
        WITH native AS (
            SELECT n.device_id,
                   date_bin('15 minutes', n.bucket_start, TIMESTAMPTZ '2000-01-01 05:30:00+05:30') AS b15,
                   n.calculated_at
            FROM analytics.energy_consumption_1min n
            WHERE n.bucket_start >= p_window_start AND n.bucket_start < p_window_end
            UNION ALL
            SELECT n.device_id,
                   date_bin('15 minutes', n.bucket_start, TIMESTAMPTZ '2000-01-01 05:30:00+05:30') AS b15,
                   n.calculated_at
            FROM analytics.energy_consumption_5min n
            WHERE n.bucket_start >= p_window_start AND n.bucket_start < p_window_end
        ),
        parent AS (
            SELECT device_id, b15,
                   count(*)::bigint  AS p_cnt,
                   max(calculated_at) AS p_calc
            FROM native
            GROUP BY device_id, b15
        ),
        child AS (
            SELECT c.device_id, c.bucket_start AS b15,
                   c.source_interval_count::bigint AS c_cnt,
                   c.calculated_at AS c_calc
            FROM analytics.energy_consumption_15min c
            WHERE c.bucket_start >= p_window_start AND c.bucket_start < p_window_end
        ),
        mism AS (
            SELECT COALESCE(p.b15, c.b15) AS b15
            FROM parent p
            FULL JOIN child c ON p.device_id = c.device_id AND p.b15 = c.b15
            WHERE p.device_id IS NOT NULL
              AND ( c.device_id IS NULL
                    OR p.p_cnt  IS DISTINCT FROM c.c_cnt
                    OR p.p_calc > c.c_calc )
        )
        SELECT date_trunc('hour', m.b15) AS coarse_bucket_start, count(*)::bigint
        FROM mism m
        GROUP BY date_trunc('hour', m.b15)
        ORDER BY 1
        LIMIT p_limit;

    ELSIF p_tier = 'energy_consumption_hourly' THEN
        RETURN QUERY
        WITH parent AS (
            SELECT s.device_id,
                   date_bin('1 hour', s.bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS hr,
                   sum(s.source_interval_count)::bigint AS p_si,
                   max(s.calculated_at) AS p_calc
            FROM analytics.energy_consumption_15min s
            WHERE s.bucket_start >= p_window_start AND s.bucket_start < p_window_end
            GROUP BY s.device_id,
                     date_bin('1 hour', s.bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00')
        ),
        child AS (
            SELECT c.device_id, c.bucket_start AS hr,
                   c.source_interval_count::bigint AS c_si,
                   c.calculated_at AS c_calc
            FROM analytics.energy_consumption_hourly c
            WHERE c.bucket_start >= p_window_start AND c.bucket_start < p_window_end
        ),
        mism AS (
            SELECT COALESCE(p.hr, c.hr) AS hr
            FROM parent p
            FULL JOIN child c ON p.device_id = c.device_id AND p.hr = c.hr
            WHERE p.device_id IS NOT NULL
              AND ( c.device_id IS NULL
                    OR p.p_si   IS DISTINCT FROM c.c_si
                    OR p.p_calc > c.c_calc )
        )
        SELECT m.hr, count(*)::bigint
        FROM mism m
        GROUP BY m.hr
        ORDER BY m.hr
        LIMIT p_limit;

    ELSE
        RAISE EXCEPTION 'analytics.reconcile_energy_deficits: unsupported tier %', p_tier;
    END IF;
END;
$function$;

ALTER FUNCTION analytics.reconcile_energy_deficits(text,timestamptz,timestamptz,interval,integer) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.reconcile_energy_deficits(text,timestamptz,timestamptz,interval,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.reconcile_energy_deficits(text,timestamptz,timestamptz,interval,integer) TO ems_admin, ems_readonly;

COMMENT ON FUNCTION analytics.reconcile_energy_deficits(text,timestamptz,timestamptz,interval,integer) IS
'Migration 213: READ-ONLY deficit detector for the 1min/5min/15min/hourly reconcile procedures. Returns the oldest p_limit coarse buckets containing a (device, tier-bucket) whose persisted fingerprint disagrees with the current parent. No writes, no refresh_*, no refresh_continuous_aggregate, no pipeline_state access.';

-- ----------------------------------------------------------------------------
-- 5a. analytics.reconcile_energy_consumption_1min
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.reconcile_energy_consumption_1min(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'energy_consumption_1min';
    v_fwd_lock  CONSTANT text := 'analytics.run_energy_consumption_1min_job';
    v_rw        INTERVAL := INTERVAL '2 days';
    v_coarse    INTERVAL := INTERVAL '1 hour';
    v_nmax      INTEGER  := 6;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_rows_ex   bigint  := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw     := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'coarse'           THEN v_coarse := (config ->> 'coarse')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax   := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        SELECT coarse_bucket_start, mism_rows
        FROM analytics.reconcile_energy_deficits(v_pipeline, v_ws, v_cp, v_coarse, v_nmax + 1)
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        v_rows_ex  := v_rows_ex + r.mism_rows;
        BEGIN
            v_repaired := v_repaired
                + analytics.refresh_energy_consumption_1min(r.coarse_bucket_start,
                                                            r.coarse_bucket_start + v_coarse);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, v_rows_ex, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 5b. analytics.reconcile_energy_consumption_5min
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.reconcile_energy_consumption_5min(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'energy_consumption_5min';
    v_fwd_lock  CONSTANT text := 'analytics.run_energy_consumption_5min_job';
    v_rw        INTERVAL := INTERVAL '7 days';
    v_coarse    INTERVAL := INTERVAL '1 hour';
    v_nmax      INTEGER  := 6;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_rows_ex   bigint  := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw     := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'coarse'           THEN v_coarse := (config ->> 'coarse')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax   := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        SELECT coarse_bucket_start, mism_rows
        FROM analytics.reconcile_energy_deficits(v_pipeline, v_ws, v_cp, v_coarse, v_nmax + 1)
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        v_rows_ex  := v_rows_ex + r.mism_rows;
        BEGIN
            v_repaired := v_repaired
                + analytics.refresh_energy_consumption_5min(r.coarse_bucket_start,
                                                            r.coarse_bucket_start + v_coarse);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, v_rows_ex, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 5c. analytics.reconcile_energy_consumption_15min
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.reconcile_energy_consumption_15min(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'energy_consumption_15min';
    v_fwd_lock  CONSTANT text := 'analytics.run_energy_consumption_15min_job';
    v_rw        INTERVAL := INTERVAL '8 days';
    v_coarse    INTERVAL := INTERVAL '1 hour';
    v_nmax      INTEGER  := 6;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_rows_ex   bigint  := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw     := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'coarse'           THEN v_coarse := (config ->> 'coarse')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax   := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        SELECT coarse_bucket_start, mism_rows
        FROM analytics.reconcile_energy_deficits(v_pipeline, v_ws, v_cp, v_coarse, v_nmax + 1)
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        v_rows_ex  := v_rows_ex + r.mism_rows;
        BEGIN
            v_repaired := v_repaired
                + analytics.refresh_energy_consumption_15min(r.coarse_bucket_start,
                                                             r.coarse_bucket_start + v_coarse);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, v_rows_ex, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 5d. analytics.reconcile_energy_consumption_hourly
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.reconcile_energy_consumption_hourly(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'energy_consumption_hourly';
    v_fwd_lock  CONSTANT text := 'analytics.run_energy_consumption_hourly_job';
    v_rw        INTERVAL := INTERVAL '10 days';
    v_coarse    INTERVAL := INTERVAL '1 hour';
    v_nmax      INTEGER  := 6;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_rows_ex   bigint  := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw     := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'coarse'           THEN v_coarse := (config ->> 'coarse')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax   := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        SELECT coarse_bucket_start, mism_rows
        FROM analytics.reconcile_energy_deficits(v_pipeline, v_ws, v_cp, v_coarse, v_nmax + 1)
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        v_rows_ex  := v_rows_ex + r.mism_rows;
        BEGIN
            v_repaired := v_repaired
                + analytics.refresh_energy_consumption_hourly(r.coarse_bucket_start,
                                                              r.coarse_bucket_start + v_coarse);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, v_rows_ex, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 5e. analytics.reconcile_energy_consumption_daily  -- INLINE site-local-day
--     detector (site timezone; NOT a UTC fixed-width bucket). source_interval_count
--     = SUM(15min.source_interval_count) over the site-local day, plus a
--     recompute-recency check.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.reconcile_energy_consumption_daily(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'energy_consumption_daily';
    v_fwd_lock  CONSTANT text := 'analytics.run_energy_consumption_daily_job';
    v_rw        INTERVAL := INTERVAL '21 days';
    v_nmax      INTEGER  := 6;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw   := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        WITH sites AS (
            SELECT st.id AS site_id, st.timezone
            FROM metadata.sites st
            WHERE COALESCE(st.lifecycle_status, 'ACTIVE') <> 'DECOMMISSIONED'
        ),
        days AS (
            SELECT si.site_id, si.timezone,
                   (g.d)::date AS local_date,
                   ((g.d)::date::timestamp AT TIME ZONE si.timezone)              AS local_start_utc,
                   (((g.d)::date + 1)::timestamp AT TIME ZONE si.timezone)        AS local_end_utc
            FROM sites si
            CROSS JOIN LATERAL generate_series(
                (v_ws AT TIME ZONE si.timezone)::date,
                (v_cp AT TIME ZONE si.timezone)::date,
                INTERVAL '1 day') g(d)
        ),
        parent AS (
            SELECT s.device_id, dy.local_start_utc, dy.local_end_utc,
                   sum(s.source_interval_count)::bigint AS p_si,
                   max(s.calculated_at) AS p_calc
            FROM days dy
            JOIN analytics.energy_consumption_15min s
              ON s.site_id = dy.site_id
             AND s.bucket_start >= dy.local_start_utc
             AND s.bucket_start <  dy.local_end_utc
            GROUP BY s.device_id, dy.local_start_utc, dy.local_end_utc
        ),
        child AS (
            SELECT c.device_id, c.bucket_start AS local_start_utc,
                   c.source_interval_count::bigint AS c_si,
                   c.calculated_at AS c_calc
            FROM analytics.energy_consumption_daily c
            WHERE c.bucket_start >= v_ws AND c.bucket_start < v_cp
        ),
        mism AS (
            SELECT DISTINCT p.local_start_utc, p.local_end_utc
            FROM parent p
            LEFT JOIN child c ON c.device_id = p.device_id AND c.local_start_utc = p.local_start_utc
            WHERE c.device_id IS NULL
               OR p.p_si   IS DISTINCT FROM c.c_si
               OR p.p_calc > c.c_calc
        )
        SELECT local_start_utc, local_end_utc
        FROM mism
        ORDER BY local_start_utc
        LIMIT v_nmax + 1
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        BEGIN
            v_repaired := v_repaired
                + analytics.refresh_energy_consumption_daily(r.local_start_utc, r.local_end_utc);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, NULL, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 6. analytics.reconcile_demand_intervals  -- demand has NO source-count
--    fingerprint (H11 / migration 210): the repair IS the re-run. Bounded
--    internally by v_max_n = ceil(reconcile_window / demand_interval_seconds)+2
--    per (site x scope) inside refresh_demand_analytics.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.reconcile_demand_intervals(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'demand_intervals';
    v_fwd_lock  CONSTANT text := 'analytics.run_demand_calculation_job';
    v_rw        INTERVAL := INTERVAL '6 hours';
    v_lookback  INTERVAL := INTERVAL '3 hours';
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw       := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'lookback'         THEN v_lookback := (config ->> 'lookback')::INTERVAL; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    -- p_now = clock_timestamp() keeps the live analytics.demand_state block
    -- current; p_finalize_from / p_finalize_to bound ONLY the historical
    -- finalisation loop -> a bounded re-finalisation over [v_ws, v_cp) that does
    -- NOT touch telemetry.pipeline_state('demand_intervals') and applies the
    -- 210 status guard (VALID rows frozen; scope-branched partial-index upsert).
    BEGIN
        CALL analytics.refresh_demand_analytics(clock_timestamp(), v_lookback, v_ws, v_cp);
    EXCEPTION WHEN OTHERS THEN
        v_errs := 1;
        v_sqlstate := SQLSTATE;
        v_errmsg   := left(SQLERRM, 1000);
    END;

    SELECT count(*)::bigint INTO v_repaired
    FROM analytics.demand_intervals
    WHERE interval_start >= v_ws
      AND interval_start <  v_cp
      AND finalized_at   >= v_started;

    v_outcome := CASE WHEN v_errs > 0 THEN 'FAILED'
                      WHEN v_repaired > 0 THEN 'REPAIRED'
                      ELSE 'HEALTHY' END;

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, NULL, NULL, NULL, v_repaired, v_errs, v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 7. telemetry.reconcile_environment_daily  -- INLINE site-local-day detector.
--    STRICT, false-positive-free signal only: a (device, local-day) whose
--    environment_measurements bucket count now EXCEEDS the row's sample_count,
--    OR a (device, local-day) with source but NO environment_daily row. All
--    DST / local-day math stays inside telemetry.refresh_environment_daily.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.reconcile_environment_daily(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'telemetry', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'environment_daily';
    v_fwd_lock  CONSTANT text := 'telemetry.run_environment_daily_job';
    v_rw        INTERVAL := INTERVAL '35 days';
    v_nmax      INTEGER  := 8;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw   := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        WITH sites AS (
            SELECT st.id AS site_id, st.timezone
            FROM metadata.sites st
            WHERE COALESCE(st.lifecycle_status, 'ACTIVE') <> 'DECOMMISSIONED'
        ),
        days AS (
            SELECT si.site_id, si.timezone,
                   ((g.d)::date::timestamp AT TIME ZONE si.timezone)              AS local_start_utc,
                   (((g.d)::date + 1)::timestamp AT TIME ZONE si.timezone)        AS local_end_utc
            FROM sites si
            CROSS JOIN LATERAL generate_series(
                (v_ws AT TIME ZONE si.timezone)::date,
                (v_cp AT TIME ZONE si.timezone)::date,
                INTERVAL '1 day') g(d)
        ),
        src AS (
            SELECT em.device_id, dy.local_start_utc, dy.local_end_utc,
                   count(*)::bigint AS src_buckets
            FROM days dy
            JOIN telemetry.environment_measurements em
              ON em.site_id = dy.site_id
             AND em.bucket_start >= dy.local_start_utc
             AND em.bucket_start <  dy.local_end_utc
            GROUP BY em.device_id, dy.local_start_utc, dy.local_end_utc
        ),
        chi AS (
            SELECT c.device_id, c.bucket_start AS local_start_utc,
                   c.sample_count::bigint AS c_cnt
            FROM telemetry.environment_daily c
            WHERE c.bucket_start >= v_ws AND c.bucket_start < v_cp
        )
        SELECT DISTINCT s.local_start_utc, s.local_end_utc
        FROM src s
        LEFT JOIN chi c ON c.device_id = s.device_id AND c.local_start_utc = s.local_start_utc
        WHERE c.device_id IS NULL
           OR s.src_buckets > c.c_cnt
        ORDER BY s.local_start_utc
        LIMIT v_nmax + 1
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        BEGIN
            v_repaired := v_repaired
                + telemetry.refresh_environment_daily(r.local_start_utc, r.local_end_utc);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, NULL, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

-- ----------------------------------------------------------------------------
-- 8. Ownership / least privilege for the seven reconcile procedures.
-- ----------------------------------------------------------------------------
ALTER PROCEDURE analytics.reconcile_energy_consumption_1min(integer, jsonb)   OWNER TO ems_admin;
ALTER PROCEDURE analytics.reconcile_energy_consumption_5min(integer, jsonb)   OWNER TO ems_admin;
ALTER PROCEDURE analytics.reconcile_energy_consumption_15min(integer, jsonb)  OWNER TO ems_admin;
ALTER PROCEDURE analytics.reconcile_energy_consumption_hourly(integer, jsonb) OWNER TO ems_admin;
ALTER PROCEDURE analytics.reconcile_energy_consumption_daily(integer, jsonb)  OWNER TO ems_admin;
ALTER PROCEDURE analytics.reconcile_demand_intervals(integer, jsonb)         OWNER TO ems_admin;
ALTER PROCEDURE telemetry.reconcile_environment_daily(integer, jsonb)        OWNER TO ems_admin;

REVOKE ALL ON PROCEDURE analytics.reconcile_energy_consumption_1min(integer, jsonb)   FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.reconcile_energy_consumption_5min(integer, jsonb)   FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.reconcile_energy_consumption_15min(integer, jsonb)  FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.reconcile_energy_consumption_hourly(integer, jsonb) FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.reconcile_energy_consumption_daily(integer, jsonb)  FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.reconcile_demand_intervals(integer, jsonb)         FROM PUBLIC;
REVOKE ALL ON PROCEDURE telemetry.reconcile_environment_daily(integer, jsonb)        FROM PUBLIC;

GRANT EXECUTE ON PROCEDURE analytics.reconcile_energy_consumption_1min(integer, jsonb)   TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_energy_consumption_5min(integer, jsonb)   TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_energy_consumption_15min(integer, jsonb)  TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_energy_consumption_hourly(integer, jsonb) TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_energy_consumption_daily(integer, jsonb)  TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_demand_intervals(integer, jsonb)         TO ems_admin;
GRANT EXECUTE ON PROCEDURE telemetry.reconcile_environment_daily(integer, jsonb)        TO ems_admin;

COMMENT ON PROCEDURE analytics.reconcile_energy_consumption_1min(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for analytics.energy_consumption_1min. Takes hashtextextended(''analytics.run_energy_consumption_1min_job'',0) as a transaction-scoped advisory lock (SKIPPED_LOCKED on contention). Detector: analytics.reconcile_energy_deficits (source_sample_count vs ca_energy_1min.sample_count per (device,minute), with the calc function''s capture_interval_seconds<=60 filter). Repair: analytics.refresh_energy_consumption_1min over each mismatching 1-hour coarse bucket, up to n_max (ships 6). NEVER writes telemetry.pipeline_state.last_received_at. NO refresh_continuous_aggregate. reconcile_window default 2 days = ca_energy_1min start_offset; older backfill is an operator-remediation condition, not auto-repaired and not reported HEALTHY.';
COMMENT ON PROCEDURE analytics.reconcile_energy_consumption_5min(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for analytics.energy_consumption_5min. As reconcile_energy_consumption_1min but against ca_energy_5min with capture_interval_seconds=300; reconcile_window default 7 days = ca_energy_5min start_offset. Empty-by-design for the all-60s fleet -> always HEALTHY.';
COMMENT ON PROCEDURE analytics.reconcile_energy_consumption_15min(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for analytics.energy_consumption_15min. Detector: count(energy_consumption_1min UNION ALL energy_consumption_5min rows per (device, IST-origin 15-min bucket)) vs source_interval_count, plus max(native.calculated_at) > child.calculated_at. Repair: analytics.refresh_energy_consumption_15min per mismatching 1-hour coarse bucket. reconcile_window default 8 days (>= ca_energy_5min start_offset 7d).';
COMMENT ON PROCEDURE analytics.reconcile_energy_consumption_hourly(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for analytics.energy_consumption_hourly. Detector: sum(energy_consumption_15min.source_interval_count per (device, hour)) vs source_interval_count, plus calculated_at recency. Repair: analytics.refresh_energy_consumption_hourly per mismatching hour. reconcile_window default 10 days.';
COMMENT ON PROCEDURE analytics.reconcile_energy_consumption_daily(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for analytics.energy_consumption_daily. Inline SITE-LOCAL-day detector (metadata.sites.timezone): sum(energy_consumption_15min.source_interval_count over the local day) vs source_interval_count, plus calculated_at recency. Repair: analytics.refresh_energy_consumption_daily(local_start_utc, local_end_utc) per mismatching local day, up to n_max (ships 6). reconcile_window default 21 days.';
COMMENT ON PROCEDURE analytics.reconcile_demand_intervals(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for analytics.demand_intervals. Demand has no source-count fingerprint; the repair IS the re-run: CALL analytics.refresh_demand_analytics(clock_timestamp(), lookback, p_finalize_from => checkpoint - reconcile_window, p_finalize_to => checkpoint). Applies the migration-210 status guard (VALID frozen; scope-branched SITE/ASSET partial-index upsert). The live demand_state block stays keyed to p_now. NEVER writes telemetry.pipeline_state.last_received_at. reconcile_window default 6 hours (the audit''s 12h recommendation is conditional on an unperformed staging cost read; raise via alter_job, not a migration). demand max_catchup_window is unchanged.';
COMMENT ON PROCEDURE telemetry.reconcile_environment_daily(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for telemetry.environment_daily. Inline SITE-LOCAL-day detector: a (device, local-day) whose telemetry.environment_measurements bucket count now exceeds environment_daily.sample_count, OR with source but no environment_daily row. Repair: telemetry.refresh_environment_daily(local_start_utc, local_end_utc) per candidate day, up to n_max (ships 8). All DST / local-day / partial-day semantics stay inside refresh_environment_daily. NEVER writes telemetry.pipeline_state.last_received_at. reconcile_window default 35 days.';

-- ----------------------------------------------------------------------------
-- 9. Register the seven reconciliation jobs (guarded / idempotent). Job IDs are
--    assigned by add_job at apply time and are looked up by (proc_schema,
--    proc_name) everywhere else. initial_start = next hour + a per-tier phase
--    offset so a reconcile does not perpetually lose the advisory-lock race to
--    a forward run.
-- ----------------------------------------------------------------------------
DO $jobs$
DECLARE
    r        RECORD;
    v_anchor timestamptz := date_trunc('hour', now()) + INTERVAL '1 hour';
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('analytics'::text, 'reconcile_energy_consumption_1min'::text,   INTERVAL '1 hour',   INTERVAL '31 minutes',
                 jsonb_build_object('reconcile_window','2 days','coarse','1 hour','n_max',6)),
            ('analytics',       'reconcile_energy_consumption_5min',          INTERVAL '1 hour',   INTERVAL '33 minutes',
                 jsonb_build_object('reconcile_window','7 days','coarse','1 hour','n_max',6)),
            ('analytics',       'reconcile_energy_consumption_15min',         INTERVAL '6 hours',  INTERVAL '37 minutes',
                 jsonb_build_object('reconcile_window','8 days','coarse','1 hour','n_max',6)),
            ('analytics',       'reconcile_energy_consumption_hourly',        INTERVAL '12 hours', INTERVAL '41 minutes',
                 jsonb_build_object('reconcile_window','10 days','coarse','1 hour','n_max',6)),
            ('analytics',       'reconcile_energy_consumption_daily',         INTERVAL '24 hours', INTERVAL '47 minutes',
                 jsonb_build_object('reconcile_window','21 days','coarse','1 day','n_max',6)),
            ('analytics',       'reconcile_demand_intervals',                 INTERVAL '1 hour',   INTERVAL '29 minutes',
                 jsonb_build_object('reconcile_window','6 hours','lookback','3 hours')),
            ('telemetry',       'reconcile_environment_daily',                INTERVAL '24 hours', INTERVAL '51 minutes',
                 jsonb_build_object('reconcile_window','35 days','n_max',8))
        ) AS t(sch, prc, sched, offs, cfg)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM timescaledb_information.jobs
            WHERE proc_schema = r.sch AND proc_name = r.prc
        ) THEN
            PERFORM add_job(
                (r.sch || '.' || r.prc)::regproc,
                schedule_interval => r.sched,
                initial_start     => v_anchor + r.offs,
                config            => r.cfg,
                check_config      => 'config.assert_reconciliation_job_config'::regproc,
                fixed_schedule    => TRUE
            );
            RAISE NOTICE 'Migration 213: registered reconcile job %.%', r.sch, r.prc;
        ELSE
            RAISE NOTICE 'Migration 213: reconcile job %.% already registered, left as-is', r.sch, r.prc;
        END IF;
    END LOOP;
END
$jobs$;

-- Finite runtime / retry policy on the seven reconcile jobs (add_job does not
-- accept these directly). Fast tiers: 5-minute runtime; slow tiers: 10 minutes.
DO $rt$
DECLARE
    r        RECORD;
    v_job_id integer;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('reconcile_energy_consumption_1min'::text,   INTERVAL '5 minutes',  INTERVAL '15 minutes'),
            ('reconcile_energy_consumption_5min',          INTERVAL '5 minutes',  INTERVAL '15 minutes'),
            ('reconcile_energy_consumption_15min',         INTERVAL '10 minutes', INTERVAL '30 minutes'),
            ('reconcile_energy_consumption_hourly',        INTERVAL '10 minutes', INTERVAL '30 minutes'),
            ('reconcile_energy_consumption_daily',         INTERVAL '10 minutes', INTERVAL '30 minutes'),
            ('reconcile_demand_intervals',                 INTERVAL '10 minutes', INTERVAL '15 minutes'),
            ('reconcile_environment_daily',                INTERVAL '10 minutes', INTERVAL '30 minutes')
        ) AS t(prc, mrt, rp)
    LOOP
        FOR v_job_id IN
            SELECT job_id FROM timescaledb_information.jobs
            WHERE proc_name = r.prc AND proc_schema IN ('analytics','telemetry')
        LOOP
            PERFORM alter_job(
                v_job_id,
                max_runtime  => r.mrt,
                max_retries  => 3,
                retry_period => r.rp,
                scheduled    => TRUE
            );
            RAISE NOTICE 'Migration 213: hardened reconcile job % (id %) -> max_runtime %, max_retries 3, retry_period %',
                r.prc, v_job_id, r.mrt, r.rp;
        END LOOP;
    END LOOP;
END
$rt$;

-- ----------------------------------------------------------------------------
-- 10. N2: analytics.run_energy_consumption_15min_job config.reconcile_window
--     3 days -> 8 days. (15min consumes energy_consumption_1min UNION ALL
--     energy_consumption_5min; a ca_energy_5min-fed 5min repair can be up to
--     that CAgg's 7-day start_offset old, so a 3-day 15min reconcile window
--     would fail to propagate it.) The forward job's window derivation,
--     schedule, runtime, retries, check_config and every other config key are
--     unchanged.
-- ----------------------------------------------------------------------------
DO $n2$
DECLARE
    v_job_id integer;
BEGIN
    FOR v_job_id IN
        SELECT job_id FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'run_energy_consumption_15min_job'
    LOOP
        PERFORM alter_job(
            v_job_id,
            config => (
                SELECT COALESCE(config, '{}'::jsonb) || jsonb_build_object('reconcile_window', '8 days')
                FROM timescaledb_information.jobs WHERE job_id = v_job_id
            )
        );
        RAISE NOTICE 'Migration 213: run_energy_consumption_15min_job config.reconcile_window 3 days -> 8 days (job %)', v_job_id;
    END LOOP;
END
$n2$;

COMMIT;
