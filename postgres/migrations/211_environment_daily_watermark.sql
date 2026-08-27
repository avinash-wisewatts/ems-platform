-- ============================================================================
-- Migration 211
-- Phase 2 Foundation, Phase 1 (3/4): environment_daily child watermark +
-- bounded catch-up over site-local days.
--
-- Root cause (same class as 205/207/209/210): telemetry.run_environment_daily_job
-- (job "run_environment_daily_job", canonical id varies -- 1075 local / 1107
-- staging) derives its processing window as a FIXED wall-clock lookback --
--     v_to := clock_timestamp();  v_from := v_to - v_lookback;   (lookback 8 days)
-- -- every hour, and telemetry.pipeline_state('environment_daily').last_received_at
-- is never read or written (migration 208 created the row but added no
-- watermark). So:
--   * a site-local day that fell outside the trailing 8-day window when it was
--     first (and only) processed is never revisited, even if environment source
--     data for it arrives later;
--   * the job re-scans and re-UPSERTs every row in the last 8 days every hour
--     (calculated_at churn) whether or not anything changed.
--
-- This migration makes the job watermark-driven, WITHOUT touching the
-- calculation:
--
--   1. telemetry.refresh_environment_daily(p_from, p_to) is NOT modified. Its
--      body is reproduced nowhere here. It already:
--        * reads telemetry.environment_measurements DIRECTLY (never a
--          ca_environment_* CAGG) by e.bucket_start;
--        * localises each bucket to metadata.sites.timezone (IANA, DST-aware)
--          and groups by (device_id, site-local calendar day);
--        * emits a (device, local-day) row ONLY where that local day's END
--          instant (local_day_end, = next local midnight in UTC) satisfies
--          local_day_end > p_from AND local_day_end <= p_to -- i.e. only
--          COMPLETE site-local days whose end falls in the window; today's
--          partial local day is never written; a day/device with no source
--          rows produces NO row (there is no NO_DATA sentinel and no
--          quality_status column);
--        * scans source back to p_from - INTERVAL '1 day' so a local day whose
--          end lands just inside the window still has all its buckets;
--        * writes INSERT ... ON CONFLICT (device_id, bucket_start) DO UPDATE
--          (single unique index; already an upsert).
--
--   2. telemetry.run_environment_daily_job becomes watermark-driven. The
--      migration-208 scaffolding is preserved VERBATIM (advisory
--      pg_try_advisory_xact_lock on its own identity -> SKIPPED_LOCKED + RETURN;
--      RUNNING transition; EXCEPTION WHEN OTHERS -> FAILED -> RAISE; SECURITY
--      DEFINER; search_path; owner ems_admin). Only the DECLARE block and the
--      "Window derivation" section change. Per run, inside the advisory lock,
--      with v_ckpt read FOR UPDATE:
--
--        v_grace := make_interval(secs =>
--              COALESCE(max(config.telemetry_capture_policies.late_arrival_tolerance_seconds)
--                       FILTER (WHERE is_enabled), 900)
--            + COALESCE(max(config.telemetry_capture_policies.capture_interval_seconds)
--                       FILTER (WHERE is_enabled), 900)
--            + 300)
--          -- a site-local day may only be finalized once EVERY one of its
--          -- environment_measurements buckets has passed its capture-bucket
--          -- correction deadline
--          -- (telemetry.capture_bucket_correction_deadline =
--          --  bucket_start + capture_interval_seconds + late_arrival_tolerance_seconds).
--          -- Derived from config.telemetry_capture_policies -- NOT
--          -- config.site_demand_policies (that governs demand, a different
--          -- pipeline, and has a different CHECK ceiling).
--
--        v_avail := (SELECT max(bucket_start) FROM telemetry.environment_measurements)
--          -- PARENT AVAILABILITY = the actual newest closed environment source
--          -- bucket. This is a real persisted timestamp; it CANNOT run ahead of
--          -- real data (contrast the ca_energy_* materialization watermark used
--          -- by migration 209's 1min/5min tiers). NOT ca_environment_*. NOT
--          -- telemetry.pipeline_state('environment_measurements') (that routing
--          -- checkpoint is keyed on platform_received_at = ingest time, not a
--          -- bucket boundary).
--
--        v_start := COALESCE(v_ckpt, clock_timestamp() - v_lookback)
--          -- lookback is now ONLY the first-run bootstrap floor.
--
--        v_to := date_bin(INTERVAL '1 day',
--                  LEAST(LEAST(clock_timestamp() - v_grace, v_avail),   -- finalizable frontier
--                        v_start + v_max_catchup),                      -- bounded slice
--                  TIMESTAMPTZ '2000-01-01 00:00:00+00')
--          -- floored to a UTC day boundary (date_bin origin at UTC midnight ->
--          -- deterministic regardless of session TimeZone) so the checkpoint is
--          -- always a clean, timezone-independent mark meaning exactly
--          -- "every site-local day whose local_day_end <= v_to has been
--          --  finalized". The watermark can therefore NEVER jump past a
--          -- complete/finalizable local-day frontier.
--
--        IF v_avail IS NULL OR v_to IS NULL OR v_to <= v_start THEN
--            -> pipeline_state NO_SOURCE_DATA (or SUCCESS if v_to = v_ckpt);
--               DO NOT advance; RETURN.
--
--        v_from := v_start - v_overlap
--        v_rows := telemetry.refresh_environment_daily(v_from, v_to)   -- UNCHANGED
--        -- on success, LAST write of the single job transaction:
--        pipeline_state('environment_daily').last_received_at := v_to
--        -- EXCEPTION WHEN OTHERS -> FAILED -> RAISE => the TimescaleDB job
--        --   runner aborts the whole job transaction (the advance, every
--        --   environment_daily upsert, RUNNING and FAILED all roll back), so a
--        --   failed / cancelled / timed-out run leaves last_received_at exactly
--        --   at its pre-run value and the retry reprocesses the identical
--        --   window.
--
--      v_overlap re-scans one already-finalized local day per run so an
--      environment_measurements bucket that arrives just after a local day was
--      finalized (but within grace + one run interval) is folded back in on the
--      next run; anything older is left to migration 212's bounded trailing
--      reconciliation (reconcile_window).
--
--   3. Job config gains "max_catchup_window" (2 days), "overlap" (1 day), and
--      "reconcile_window" (35 days). reconcile_window is stored now and consumed
--      by migration 212 only (this migration adds NO reconciliation framework).
--      "lookback" (8 days, now the first-run floor), schedule_interval (1 hour),
--      max_runtime (10 minutes), max_retries (3), retry_period (5 minutes), and
--      the migration-208 check_config validator are UNCHANGED. The
--      config.assert_analytical_lookback_job_config validator already accepts
--      all four keys (extended in migration 209).
--
-- NOT touched: telemetry.refresh_environment_daily, the environment_daily
-- schema / PK / indexes, any CAGG (ca_environment_15min / ca_environment_hourly
-- or their refresh policies), retention, compression, any Grafana object,
-- the job schedule / runtime / retry settings, metadata.sites.timezone
-- handling, the routing pipeline (jobs 1001/1012).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. telemetry.run_environment_daily_job -- bounded watermark-driven wrapper.
--    Migration-208 advisory-lock / RUNNING / FAILED->RAISE scaffolding, SECURITY
--    DEFINER, search_path and owner preserved. telemetry.refresh_environment_daily
--    is NOT redefined.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.run_environment_daily_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'telemetry'
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'environment_daily';
    v_lookback      INTERVAL := INTERVAL '8 days';       -- FIRST-RUN FLOOR only
    v_max_catchup   INTERVAL := INTERVAL '2 days';
    v_overlap       INTERVAL := INTERVAL '1 day';
    v_grace         INTERVAL;
    v_ckpt          TIMESTAMPTZ;
    v_avail         TIMESTAMPTZ;
    v_start         TIMESTAMPTZ;
    v_to            TIMESTAMPTZ;
    v_from          TIMESTAMPTZ;
    v_rows          BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'environment daily config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)',
            v_lookback, v_max_catchup, v_overlap;
    END IF;

    -- Phase 0b (migration 208): self-overlap guard (see analytics.run_energy_consumption_1min_job).
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('telemetry.run_environment_daily_job', 0)
    );
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Migration 211: child-watermark + bounded catch-up over site-local days.
    -- Grace prevents finalizing a local day while any of its
    -- environment_measurements buckets could still be corrected. Derived from
    -- config.telemetry_capture_policies (NOT config.site_demand_policies).
    v_grace := make_interval(secs =>
          COALESCE((SELECT max(late_arrival_tolerance_seconds)
                    FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + COALESCE((SELECT max(capture_interval_seconds)
                    FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + 300);

    -- Parent availability = the actual newest closed environment source bucket
    -- (a real persisted timestamp; cannot run ahead of real data). NOT a CAGG
    -- watermark; NOT the routing pipeline_state checkpoint (ingest time).
    SELECT max(bucket_start) INTO v_avail FROM telemetry.environment_measurements;

    v_start := COALESCE(v_ckpt, clock_timestamp() - v_lookback);

    -- Finalizable-local-day frontier: past grace AND backed by real source data,
    -- bounded by one catch-up slice, floored to a UTC day boundary (date_bin
    -- origin at UTC midnight -> deterministic regardless of session TimeZone).
    v_to := date_bin(
              INTERVAL '1 day',
              LEAST(LEAST(clock_timestamp() - v_grace, v_avail), v_start + v_max_catchup),
              TIMESTAMPTZ '2000-01-01 00:00:00+00');

    IF v_avail IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := v_start - v_overlap;

    -- telemetry.refresh_environment_daily is UNCHANGED. Its own
    -- local_day_end > p_from AND local_day_end <= p_to filter guarantees only
    -- complete site-local days ending in (v_from, v_to] are (re-)finalized.
    v_rows := telemetry.refresh_environment_daily(v_from, v_to);

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
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

ALTER PROCEDURE telemetry.run_environment_daily_job(integer, jsonb) OWNER TO ems_admin;

COMMENT ON PROCEDURE telemetry.run_environment_daily_job(integer, jsonb) IS
'TimescaleDB background action for the site-local daily environment historian. Migration 211: watermark-driven. Reads telemetry.pipeline_state(''environment_daily'').last_received_at (FOR UPDATE), derives parent availability = max(telemetry.environment_measurements.bucket_start) (the real newest closed source bucket -- never a ca_environment_* watermark, never the routing pipeline_state checkpoint), a grace = max(late_arrival_tolerance_seconds)+max(capture_interval_seconds)+300 over enabled config.telemetry_capture_policies, and CALLs the UNCHANGED telemetry.refresh_environment_daily(v_from, v_to) with v_to = date_bin(''1 day'', LEAST(LEAST(now - grace, parent_available), checkpoint + max_catchup_window)) and v_from = checkpoint - overlap. Advances last_received_at = v_to (a UTC-day boundary meaning "every site-local day ending <= v_to is finalized") ONLY as the last write of the successful single transaction; any failure / cancel / timeout rolls the whole run back and leaves the checkpoint unchanged. lookback is the first-run floor only. The migration-208 advisory lock (-> SKIPPED_LOCKED) is preserved.';

-- ----------------------------------------------------------------------------
-- 2. pipeline_state row (already created by migration 208; idempotent).
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name)
VALUES ('environment_daily')
ON CONFLICT (pipeline_name) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 3. Job config: add the Phase-1 keys. lookback / schedule / runtime / retries
--    / check_config UNCHANGED. reconcile_window is consumed by migration 212.
-- ----------------------------------------------------------------------------
DO $cfg$
DECLARE
    v_job_id INTEGER;
BEGIN
    FOR v_job_id IN
        SELECT job_id FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_environment_daily_job'
    LOOP
        PERFORM alter_job(
            v_job_id,
            config => (
                SELECT COALESCE(config, '{}'::jsonb)
                       || jsonb_build_object(
                            'max_catchup_window', '2 days',
                            'overlap',            '1 day',
                            'reconcile_window',   '35 days')
                FROM timescaledb_information.jobs WHERE job_id = v_job_id
            )
        );
        RAISE NOTICE 'Migration 211: job % (telemetry.run_environment_daily_job) config += max_catchup_window=2 days, overlap=1 day, reconcile_window=35 days',
            v_job_id;
    END LOOP;
END
$cfg$;

COMMIT;
