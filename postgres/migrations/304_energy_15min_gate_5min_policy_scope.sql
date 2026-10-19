-- ============================================================================
-- Migration 304
-- 15-minute energy tier: wait for the 5-minute tier's checkpoint only while a
-- 300 s capture policy applies (staging optimization plan T3.5 step 1).
--
-- WHAT THE GATE IS
--   analytics.run_energy_consumption_15min_job (job 1099, migration 209) caps
--   each run at
--       v_parent = LEAST(cp('energy_consumption_1min'), cp('energy_consumption_5min'))
--   because analytics.energy_consumption_15min is rolled up from
--   analytics.v_energy_consumption_native = energy_consumption_1min UNION ALL
--   energy_consumption_5min. The 1-minute tier holds buckets whose effective
--   capture policy is <= 60 s, the 5-minute tier only buckets whose policy is
--   exactly 300 s (refresh_energy_consumption_1min / _5min, migration 216).
--
-- WHY IT CHANGES
--   With no 300 s policy the 5-minute tier is empty (staging 2026-10-19: 0
--   rows in 2 days; policies 60 s only), yet its checkpoint (job 1080, every
--   minute, following the ca_energy_5min watermark of the drifting CAGG
--   refresh 1063) still gates the 15-minute tier and, through it, the hourly,
--   daily and alert-materiality tiers. Job 1080 can therefore not be slowed or
--   parked (plan v17, T3.5) without stalling them.
--
-- NEW GATE
--   The run first computes its window from the 1-minute checkpoint alone,
--   [v_start - overlap, v_to). It also waits for the 5-minute checkpoint
--   (exactly the migration-209 LEAST) when any of these holds:
--     - an ENABLED 300 s capture policy (site or platform default) has an
--       effective range overlapping that window
--       (analytics.energy_5min_capture_policy_overlaps);
--     - the 1-minute checkpoint is NULL;
--     - the window is empty (v_to <= v_start).
--   The 5-minute tier only holds rows whose bucket_start lies inside a 300 s
--   policy's [effective_from, effective_to) (telemetry.resolve_site_capture_bucket),
--   so when no such range overlaps the window the 5-minute tier contributes
--   no row to it, and waiting for it cannot change the result.
--   Mixed fleets: one 300 s site anywhere makes the gate the 209 LEAST for
--   every window that overlaps its policy. The check is deliberately
--   conservative: a 300 s platform default shadowed by site policies, or a
--   300 s policy on a site without energy meters, still gates.
--
-- Unchanged: every other byte of the 209 body (postcondition: swapping the
--   fragment back gives the 209 md5 81b9d8d5..., the definition live on
--   staging 2026-10-19), signature, owner ems_admin, SECURITY DEFINER,
--   search_path; jobs, schedules, configs, capture policies, the 1-minute /
--   5-minute / hourly / daily procedures, refresh functions, reconcilers,
--   v_pipeline_health, data. Job 1080 keeps running as before; parking or
--   slowing it is a separate, approved step (T3.5 step 2).
--   Known limitation, unchanged from 209: a 300 s policy inserted or enabled
--   with an effective_from in the past is not re-processed by the forward
--   jobs (the 5-minute checkpoint has already advanced past it either way);
--   reconcilers 1117 (7 d) and 1118 (8 d) repair those windows.
--
-- Rollback: re-apply migration 209's CREATE OR REPLACE PROCEDURE
--   analytics.run_energy_consumption_15min_job, then
--   DROP FUNCTION analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz).
--   Applying this migration changes no data.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('analytics.run_energy_consumption_15min_job(integer, jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 304 precondition failed: analytics.run_energy_consumption_15min_job(integer, jsonb) is missing.';
    END IF;
    IF md5(pg_get_functiondef('analytics.run_energy_consumption_15min_job(integer, jsonb)'::regprocedure)) <> '81b9d8d5bb131406bc6c27c9258f75b1' THEN
        RAISE EXCEPTION 'Migration 304 precondition failed: the 15-minute job procedure differs from the migration 209 definition.';
    END IF;
    IF to_regprocedure('analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 304 precondition failed: analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz) already exists.';
    END IF;
END;
$pre$;

CREATE FUNCTION analytics.energy_5min_capture_policy_overlaps(p_from timestamptz, p_to timestamptz)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM config.telemetry_capture_policies AS p
        WHERE p.is_enabled
          AND p.capture_interval_seconds = 300
          -- [effective_from, effective_to) overlaps [p_from, p_to); plain
          -- comparisons, so an empty or inverted window never raises.
          AND p.effective_from < p_to
          AND (p.effective_to IS NULL OR p.effective_to > p_from)
    );
$function$;

ALTER FUNCTION analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz) FROM ems_app;
REVOKE ALL ON FUNCTION analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz) FROM grafana_reader;

COMMENT ON FUNCTION analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz) IS
'TRUE when an enabled 300 s capture policy (site or platform default) has an effective range overlapping [p_from, p_to). The 5-minute energy tier only holds buckets inside such a range, so the 15-minute job waits for the 5-minute checkpoint only then (migration 304, plan T3.5). Called by analytics.run_energy_consumption_15min_job only.';

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_15min_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name    CONSTANT TEXT := 'energy_consumption_15min';
    v_lookback         INTERVAL := INTERVAL '2 hours';
    v_max_catchup      INTERVAL := INTERVAL '6 hours';
    v_overlap          INTERVAL := INTERVAL '30 minutes';
    v_ckpt             TIMESTAMPTZ;
    v_parent           TIMESTAMPTZ;
    v_now_binned       TIMESTAMPTZ;
    v_start            TIMESTAMPTZ;
    v_to               TIMESTAMPTZ;
    v_from             TIMESTAMPTZ;
    v_rows             BIGINT := 0;
    v_lock_acquired    BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'energy consumption 15-minute config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)', v_lookback, v_max_catchup, v_overlap;
    END IF;

    v_lock_acquired := pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Parent availability (migration 304): the 1-minute child checkpoint, and
    -- also the 5-minute one (LEAST ignores NULLs) when an enabled 300 s
    -- capture policy overlaps this run's window -- the 5-minute tier only
    -- holds buckets inside such a policy -- or when there is no 1-minute
    -- window to check.
    v_parent := (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_1min');
    v_now_binned := date_bin(INTERVAL '15 minutes', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);
    IF v_parent IS NULL OR v_to <= v_start
       OR analytics.energy_5min_capture_policy_overlaps(v_start - v_overlap, v_to) THEN
        v_parent := LEAST(
            v_parent,
            (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_5min')
        );
        v_to     := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);
    END IF;

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := v_start - v_overlap;
    v_rows := analytics.refresh_energy_consumption_15min(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

DO $post$
DECLARE
    v_sig   CONSTANT TEXT := 'analytics.run_energy_consumption_15min_job(integer, jsonb)';
    v_fn    CONSTANT TEXT := 'analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz)';
    v_def   TEXT;
    v_old   CONSTANT TEXT := $old$    -- Parent availability: the LESSER of the two upstream child checkpoints.
    -- LEAST() ignores NULLs (Postgres), so a not-yet-started or empty 5-minute
    -- tier falls back to the 1-minute checkpoint; only BOTH being NULL blocks.
    v_parent := LEAST(
        (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_1min'),
        (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_5min')
    );
    v_now_binned := date_bin(INTERVAL '15 minutes', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);
$old$;
    v_new   CONSTANT TEXT := $new$    -- Parent availability (migration 304): the 1-minute child checkpoint, and
    -- also the 5-minute one (LEAST ignores NULLs) when an enabled 300 s
    -- capture policy overlaps this run's window -- the 5-minute tier only
    -- holds buckets inside such a policy -- or when there is no 1-minute
    -- window to check.
    v_parent := (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_1min');
    v_now_binned := date_bin(INTERVAL '15 minutes', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);
    IF v_parent IS NULL OR v_to <= v_start
       OR analytics.energy_5min_capture_policy_overlaps(v_start - v_overlap, v_to) THEN
        v_parent := LEAST(
            v_parent,
            (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_5min')
        );
        v_to     := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);
    END IF;
$new$;
BEGIN
    v_def := pg_get_functiondef(v_sig::regprocedure);
    IF (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new) <> 1 THEN
        RAISE EXCEPTION 'Migration 304 postcondition failed: the new gate is not present exactly once.';
    END IF;
    IF md5(replace(v_def, v_new, v_old)) <> '81b9d8d5bb131406bc6c27c9258f75b1' THEN
        RAISE EXCEPTION 'Migration 304 postcondition failed: the 15-minute job differs from migration 209 outside the gate fragment.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 304 postcondition failed: the 15-minute job is not SECURITY DEFINER / owned by ems_admin / search_path-pinned.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner JOIN pg_language l ON l.oid = p.prolang
        WHERE p.oid = v_fn::regprocedure
          AND l.lanname = 'sql' AND p.provolatile = 's' AND NOT p.prosecdef AND p.proconfig IS NULL
          AND r.rolname = 'ems_admin'
    ) OR has_function_privilege('public', v_fn, 'EXECUTE')
       OR has_function_privilege('ems_app', v_fn, 'EXECUTE')
       OR has_function_privilege('grafana_reader', v_fn, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 304 postcondition failed: the helper must be LANGUAGE sql, STABLE, SECURITY INVOKER, without SET, owned by ems_admin, not executable by PUBLIC / ems_app / grafana_reader.';
    END IF;
    RAISE NOTICE 'Migration 304: all postconditions passed; 300 s policy overlapping the last 24 h: %.',
        analytics.energy_5min_capture_policy_overlaps(now() - INTERVAL '24 hours', now());
END;
$post$;
