-- ============================================================================
-- Migration 303
-- Routing loaders: forward reads bounded to uncompressed normalized_points
-- chunks, plus an hourly late-data sweep for rows that land in compressed
-- chunks.
--
-- WHY
--   Both routing loaders (telemetry.load_energy_measurements_incremental,
--   telemetry.load_environment_measurements_incremental) select their window
--   with
--       WHERE np.platform_received_at > v_window_start
--         AND np.platform_received_at <= v_window_end
--   normalized_points is partitioned on event_time (7-day chunks) and
--   compressed 1 day after a chunk ends, so nothing in that predicate lets
--   TimescaleDB exclude a chunk: every run sequentially reads the batch
--   metadata of every compressed chunk (filtering on the platform_received_at
--   min/max) plus an index scan of the open chunk. Migration 267 bounded only
--   the window-END lookup, not this read.
--   Production, read-only, 2026-10-16: 12 compressed chunks (353 MB compressed
--   heap); the read hit the 30 s statement timeout 6 / 6 times; energy routing
--   runs took p50 546 s and environment routing p50 504 s on an IO-saturated
--   host. Staging: 8 chunks (287 MB), 0.12-0.21 s with warm cache.
--
-- WHAT
--   1. Forward scope (the scheduled 1001 / 1012 jobs, unchanged wrappers):
--      window_events additionally requires
--          event_time >= v_event_min   -- = max(range_end) of the compressed
--                                      --   normalized_points chunks
--      read from timescaledb_information.chunks once per run. Every compressed
--      chunk ends at or before that floor, so startup chunk exclusion removes
--      them all; only uncompressed chunks are read (index on
--      platform_received_at). A row whose event_time is in an uncompressed
--      chunk is routed exactly as before, however late it arrives.
--   2. Late-sweep scope: telemetry.run_routing_late_sweep_job (new, hourly,
--      fixed schedule at hh:31:30 UTC) sets the transaction-local setting
--      ems.routing_scope = 'late_sweep' and CALLs each loader. In that scope
--      the loader uses its own checkpoint row
--      (<pipeline>_late_sweep), reads only event_time < the floor, and caps
--      its window end at the forward checkpoint, so it only re-examines
--      receipt ranges the forward runs have already processed.
--   Everything else in both bodies is byte-for-byte unchanged (postconditions
--   below): window-end lookup, NULL -> NO_SOURCE_DATA, max_window cap, the
--   1-minute overlap, point selection, re-fetch, upserts, checkpoint write,
--   advisory lock and the EXCEPTION / rollback contract.
--
-- SEMANTICS
--   * Completeness. Let F(t) be the floor at time t. A compressed chunk only
--     ever becomes compressed (or is dropped by retention, which removes the
--     oldest), so F never decreases. A row r (receipt R, event E) that the
--     forward run processing R's window at time t skipped has E < F(t). The
--     sweep reaches R's window at some s > t (its window end never passes the
--     forward checkpoint), where E < F(t) <= F(s), so it routes r. A row
--     with E >= F(t) is routed by the forward run as before.
--   * Not covered: manually decompressing a normalized_points chunk lowers F.
--     Do not decompress these chunks; if one is decompressed, run the sweep
--     procedure by hand with a window covering the affected receipts.
--   * Idempotency. The sweep re-uses the unchanged upserts: energy updates an
--     existing bucket only while it is inside its correction deadline and only
--     with an equal-or-newer receipt; environment inserts with ON CONFLICT DO
--     NOTHING and updates only correctable buckets (migration 291). Rows older
--     than the floor are long past their correction deadline, so the sweep
--     only ever inserts missing buckets. Re-running any window changes nothing.
--   * Retries / checkpoints. Each scope advances only its own checkpoint, as
--     the last write of its single transaction; a failure rolls back data and
--     checkpoint together. The sweep's window end is
--     GREATEST(LEAST(window end, forward checkpoint), sweep checkpoint), so it
--     never moves backwards and never passes the forward checkpoint.
--   * Locking. Both scopes take the loader's existing advisory lock, so a sweep
--     and a forward run of the same loader never overlap; the one that loses
--     records SKIPPED_LOCKED and the next run catches up through the overlap.
--   * Latency. Only rows that arrive after their chunk was compressed (at least
--     1 day late) wait for the sweep: at most about an hour more. Staging,
--     2026-10-16, compressed batch metadata: no batch shows a receipt more than
--     ~1.5 minutes after its newest event, so such rows are rare.
--   * Demand. Unchanged: demand finalizes up to max(energy_measurements
--     .bucket_start) (migration 210), which the forward runs keep advancing.
--   * No runtime-dynamic SQL, no planner setting, no job / schedule change to
--     the existing jobs. One new job; two new pipeline_state rows.
--
-- SOURCES
--   Energy body: migration 267 (CR-normalized md5 d271e2b8b722729b47d5991ac9504ff7) plus the
--   four fragments; new md5 ee8c1867c0426587cda0d40467be57a2.
--   Environment body: the offline generator's committed artifact
--   scripts/codegen/generated/load_environment_measurements_incremental.generated.sql,
--   regenerated from the updated template (previous md5 d0708b46eb9ab81a6b2cc37ee0d85ef5, the
--   migration-291 body; new md5 be09c0efb5cc8f5f819f2bb30b8d5370).
--   Tests: app/tests/test_routing_forward_floor_late_sweep.py,
--   app/tests/test_routing_generator_contract.py.
--
-- ROLLBACK (forward migration, needs its own approval)
--   1. SELECT delete_job(job_id) FROM timescaledb_information.jobs
--      WHERE proc_schema = 'telemetry' AND proc_name = 'run_routing_late_sweep_job';
--   2. Re-issue the migration-267 energy body and the migration-291
--      environment body (CREATE OR REPLACE, verbatim).
--   3. DROP PROCEDURE telemetry.run_routing_late_sweep_job(integer, jsonb);
--      DELETE FROM telemetry.pipeline_state WHERE pipeline_name IN
--      ('energy_measurements_late_sweep', 'environment_measurements_late_sweep');
--   No routed data needs restoring: both scopes write what the pre-303 body
--   would have written. Rows routed only by a sweep stay (they are correct).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Job-id sequence guard (migration 213): before add_job.
-- ----------------------------------------------------------------------------
DO $seqfix$
BEGIN
    IF to_regclass('_timescaledb_catalog.bgw_job_id_seq') IS NOT NULL THEN
        PERFORM setval(
            '_timescaledb_catalog.bgw_job_id_seq',
            GREATEST(
                (SELECT last_value FROM _timescaledb_catalog.bgw_job_id_seq),
                (SELECT COALESCE(max(id), 0) FROM _timescaledb_config.bgw_job)
            ),
            true
        );
    END IF;
END
$seqfix$;


-- ----------------------------------------------------------------------------
-- 1. Preconditions: exact source bodies; normalized_points partitioned on
--    event_time; the scope setting is not set at database or role level.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure)
       IS DISTINCT FROM 'd271e2b8b722729b47d5991ac9504ff7' THEN
        RAISE EXCEPTION 'Migration 303 precondition failed: load_energy_measurements_incremental differs from the expected (migration 267) body.';
    END IF;

    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure)
       IS DISTINCT FROM 'd0708b46eb9ab81a6b2cc37ee0d85ef5' THEN
        RAISE EXCEPTION 'Migration 303 precondition failed: load_environment_measurements_incremental differs from the expected (migration 291) body.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.dimensions
        WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'normalized_points'
          AND column_name = 'event_time' AND dimension_number = 1
    ) THEN
        RAISE EXCEPTION 'Migration 303 precondition failed: telemetry.normalized_points is not partitioned on event_time.';
    END IF;

    IF COALESCE(current_setting('ems.routing_scope', true), '') <> '' THEN
        RAISE EXCEPTION 'Migration 303 precondition failed: ems.routing_scope is set (%); it must only be set transaction-locally by the late-sweep job.',
            current_setting('ems.routing_scope', true);
    END IF;

    IF EXISTS (SELECT 1 FROM timescaledb_information.jobs
               WHERE proc_schema = 'telemetry' AND proc_name = 'run_routing_late_sweep_job') THEN
        RAISE EXCEPTION 'Migration 303 precondition failed: a run_routing_late_sweep_job is already registered.';
    END IF;
END
$pre$;


-- ----------------------------------------------------------------------------
-- 2. Energy loader: the migration-267 body plus the four migration-303 fragments.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental(IN p_overlap interval DEFAULT '00:15:00'::interval, IN p_max_window interval DEFAULT NULL)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
  -- Migration 303: ems.routing_scope (transaction-local; set only by
  -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
  v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting('ems.routing_scope', true), ''), 'forward');
  v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = 'late_sweep' THEN 'energy_measurements_late_sweep' ELSE 'energy_measurements' END;
  v_event_min TIMESTAMPTZ;
  v_event_max TIMESTAMPTZ;
  v_forward_checkpoint TIMESTAMPTZ;
  v_previous_checkpoint TIMESTAMPTZ;
  v_window_start TIMESTAMPTZ;
  v_window_end TIMESTAMPTZ;
  v_affected_rows BIGINT := 0;
  v_lock_acquired BOOLEAN;
  v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
    RAISE EXCEPTION 'p_overlap must be zero or a positive interval; received %', p_overlap;
  END IF;

  -- Migration 207: reject a non-positive explicit bound. NULL (the
  -- default, and what a direct/manual invocation passes) means "no
  -- bound" -- byte-for-byte the pre-207 behaviour.
  IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
    RAISE EXCEPTION 'p_max_window must be positive when supplied; received %', p_max_window;
  END IF;

  -- Migration 303: reject an unknown scope.
  IF v_scope NOT IN ('forward', 'late_sweep') THEN
    RAISE EXCEPTION 'ems.routing_scope must be forward or late_sweep; received %', v_scope;
  END IF;

  SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.load_energy_measurements_incremental',0))
  INTO v_lock_acquired;
  IF NOT v_lock_acquired THEN
    UPDATE telemetry.pipeline_state SET last_status='SKIPPED_LOCKED',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  SELECT last_received_at INTO v_previous_checkpoint
  FROM telemetry.pipeline_state WHERE pipeline_name=v_pipeline_name FOR UPDATE;

  UPDATE telemetry.pipeline_state
  SET last_started_at=clock_timestamp(),last_status='RUNNING',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;

  -- Migration 267: bound the window-end lookup to recent event_time so it only
  -- reads uncompressed chunks (normalized_points compress_after = 1 day). The
  -- bounded max can only be lower than the global max, which delays -- never
  -- skips -- rows; the global lookup remains the fallback when no row has a
  -- recent event_time.
  SELECT max(platform_received_at) INTO v_window_end
  FROM telemetry.normalized_points
  WHERE platform_received_at IS NOT NULL
    AND event_time >= now() - INTERVAL '1 day';
  IF v_window_end IS NULL THEN
    SELECT max(platform_received_at) INTO v_window_end
    FROM telemetry.normalized_points
    WHERE platform_received_at IS NOT NULL;
  END IF;
  IF v_window_end IS NULL THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='NO_SOURCE_DATA',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  -- Migration 207: cap the forward processing boundary to the previous
  -- checkpoint plus p_max_window when a caller supplies one and a
  -- previous checkpoint already exists. NULL (the default) leaves
  -- v_window_end exactly as computed above -- byte-for-byte the pre-207
  -- behaviour. The scheduled wrapper telemetry.run_energy_routing_job
  -- passes a bounded value so an unattended multi-hour
  -- normalized_points backlog self-drains over successive 1-minute runs
  -- instead of being attempted as one unbounded, max_runtime-exceeding
  -- transaction -- the job-1000 stall class, fixed for normalization by
  -- migration 205 and extended here to energy/environment routing. A
  -- direct manual CALL that omits the argument (or passes NULL) still
  -- performs unrestricted catch-up. Advisory lock, checkpoint keying,
  -- overlap semantics, the routing/calculation SQL below, and the
  -- EXCEPTION-rolls-back-the-watermark contract are all unchanged.
  IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
    v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
  END IF;

  -- Migration 303: forward runs read only normalized_points chunks newer
  -- than the newest compressed chunk (event_time >= its range_end), so
  -- chunk exclusion skips every compressed chunk instead of scanning its
  -- batch metadata on every run. Rows older than that floor (late data in
  -- compressed chunks) are routed by the hourly late-data sweep, which reads
  -- only event_time < floor and never passes the forward checkpoint.
  SELECT max(c.range_end) INTO v_event_min
  FROM timescaledb_information.chunks c
  WHERE c.hypertable_schema='telemetry'
    AND c.hypertable_name='normalized_points'
    AND c.is_compressed;
  v_event_min := COALESCE(v_event_min, '-infinity'::timestamptz);
  v_event_max := 'infinity'::timestamptz;
  IF v_scope = 'late_sweep' THEN
    v_event_max := v_event_min;
    v_event_min := '-infinity'::timestamptz;
    SELECT last_received_at INTO v_forward_checkpoint
    FROM telemetry.pipeline_state WHERE pipeline_name='energy_measurements';
    v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, '-infinity'::timestamptz));
    IF v_previous_checkpoint IS NOT NULL THEN
      v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
    END IF;
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
  -- A one-minute replay is sufficient to protect timestamp-boundary races
  -- without rescanning the full late-arrival tolerance on every run.
  p_overlap := LEAST(p_overlap, INTERVAL '1 minute');

  v_window_start := CASE WHEN v_previous_checkpoint IS NULL THEN '-infinity'::timestamptz ELSE v_previous_checkpoint-p_overlap END;

  WITH window_events AS MATERIALIZED
  (
    SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
    FROM telemetry.normalized_points np
    WHERE np.platform_received_at > v_window_start
      AND np.platform_received_at <= v_window_end
      AND np.event_time >= v_event_min
      AND np.event_time < v_event_max
    GROUP BY np.device_id,np.event_time
  ),
  full_resolution AS MATERIALIZED
  (
WITH profile_context AS
(
  SELECT
    np.event_time,
    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id,
    np.logical_point_id,
    np.device_uid,
    np.logical_point,
    np.raw_field_name,
    np.raw_value,
    np.numeric_value,
    np.quality_code,
    np.mapping_source,
    np.created_at,
    np.platform_received_at,
    np.raw_message_id,
    d.profile_id,
    dp.profile_code
  FROM window_events we
  CROSS JOIN LATERAL
  (
    SELECT src_np.*
    FROM telemetry.normalized_points src_np
    WHERE src_np.device_id = we.device_id
      AND src_np.event_time = we.event_time
    OFFSET 0
  ) np
  JOIN metadata.devices d ON d.id=np.device_id
  LEFT JOIN config.device_profiles dp ON dp.id=d.profile_id
),
register_scales AS
(
  SELECT pc.*, ers.scale_to_normalized_unit
  FROM profile_context pc
  LEFT JOIN config.energy_register_semantics ers
    ON ers.profile_id=pc.profile_id
   AND ers.logical_point_id=pc.logical_point_id
   AND ers.is_active=TRUE
),
pivoted AS
(
  SELECT
        rs.event_time AS received_at,
        rs.event_time AS source_timestamp,
        rs.organization_id,
        rs.site_id,
        rs.gateway_id,
        rs.device_id,
        NULL::UUID AS asset_id,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_total_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l1_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l2_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l3_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_total_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l1_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l2_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l3_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_TOTAL', 'ENERGY_REACTIVE_ENERGY_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L1', 'ENERGY_REACTIVE_ENERGY_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L2', 'ENERGY_REACTIVE_ENERGY_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L3', 'ENERGY_REACTIVE_ENERGY_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l3_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l3_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_TOTAL', 'ENERGY_APPARENT_ENERGY_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_total_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L1', 'ENERGY_APPARENT_ENERGY_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l1_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L2', 'ENERGY_APPARENT_ENERGY_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l2_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L3', 'ENERGY_APPARENT_ENERGY_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l3_vah,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_TOTAL', 'ENERGY_ACTIVE_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_total_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L1', 'ENERGY_ACTIVE_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l1_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L2', 'ENERGY_ACTIVE_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l2_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L3', 'ENERGY_ACTIVE_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l3_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_TOTAL', 'ENERGY_REACTIVE_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_total_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L1', 'ENERGY_REACTIVE_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l1_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L2', 'ENERGY_REACTIVE_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l2_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L3', 'ENERGY_REACTIVE_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l3_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_TOTAL', 'ENERGY_APPARENT_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_total_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L1', 'ENERGY_APPARENT_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l1_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L2', 'ENERGY_APPARENT_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l2_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L3', 'ENERGY_APPARENT_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l3_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_LN_AVG'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_ln_avg_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l1_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l2_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l3_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_LL_AVG'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_ll_avg_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L12'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l12_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L23'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l23_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L31'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l31_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_total_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l1_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l2_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l3_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_NEUTRAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS neutral_current_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_total,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l1,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l2,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l3,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'FREQUENCY'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS frequency_hz,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l1_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l2_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l3_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_total_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l1_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l2_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l3_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PULSE_COUNT'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::BIGINT AS pulse_count,

        COUNT(*) FILTER (WHERE rs.quality_code='GOOD' AND rs.numeric_value IS NOT NULL) AS populated_point_count,
        COUNT(*) FILTER (WHERE rs.quality_code='INVALID_NUMERIC') AS invalid_point_count
  FROM register_scales rs
  GROUP BY rs.event_time, rs.organization_id, rs.site_id, rs.gateway_id, rs.device_id
)
SELECT *
FROM pivoted
WHERE num_nonnulls
(
    import_energy_total_wh,
    import_energy_l1_wh,
    import_energy_l2_wh,
    import_energy_l3_wh,
    export_energy_total_wh,
    export_energy_l1_wh,
    export_energy_l2_wh,
    export_energy_l3_wh,
    reactive_energy_total_varh,
    reactive_energy_l1_varh,
    reactive_energy_l2_varh,
    reactive_energy_l3_varh,
    reactive_export_energy_total_varh,
    reactive_export_energy_l1_varh,
    reactive_export_energy_l2_varh,
    reactive_export_energy_l3_varh,
    apparent_energy_total_vah,
    apparent_energy_l1_vah,
    apparent_energy_l2_vah,
    apparent_energy_l3_vah,
    active_power_total_w,
    active_power_l1_w,
    active_power_l2_w,
    active_power_l3_w,
    reactive_power_total_var,
    reactive_power_l1_var,
    reactive_power_l2_var,
    reactive_power_l3_var,
    apparent_power_total_va,
    apparent_power_l1_va,
    apparent_power_l2_va,
    apparent_power_l3_va,
    voltage_ln_avg_v,
    voltage_l1_v,
    voltage_l2_v,
    voltage_l3_v,
    voltage_ll_avg_v,
    voltage_l12_v,
    voltage_l23_v,
    voltage_l31_v,
    current_total_a,
    current_l1_a,
    current_l2_a,
    current_l3_a,
    neutral_current_a,
    power_factor_total,
    power_factor_l1,
    power_factor_l2,
    power_factor_l3,
    frequency_hz,
    phase_angle_l1_deg,
    phase_angle_l2_deg,
    phase_angle_l3_deg,
    current_thd_total_percent,
    current_thd_l1_percent,
    current_thd_l2_percent,
    current_thd_l3_percent,
    pulse_count
) > 0
  ),
  resolved AS
  (
    SELECT fr.*,bucket.policy_id,bucket.capture_interval_seconds,
           bucket.late_arrival_tolerance_seconds,bucket.bucket_start
    FROM full_resolution fr
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
      (fr.site_id,COALESCE(fr.source_timestamp,fr.received_at)) AS bucket
  ),
  ranked AS
  (
    SELECT resolved.*,
           row_number() OVER
           (
             PARTITION BY resolved.device_id,resolved.policy_id,resolved.bucket_start
             ORDER BY COALESCE(resolved.source_timestamp,resolved.received_at) DESC,
                      resolved.received_at DESC
           ) AS sample_rank
    FROM resolved
  )
  INSERT INTO telemetry.energy_measurements
  (
        bucket_start, received_at, source_timestamp, organization_id, site_id, gateway_id, device_id, asset_id,
        import_energy_total_wh,
        import_energy_l1_wh,
        import_energy_l2_wh,
        import_energy_l3_wh,
        export_energy_total_wh,
        export_energy_l1_wh,
        export_energy_l2_wh,
        export_energy_l3_wh,
        reactive_energy_total_varh,
        reactive_energy_l1_varh,
        reactive_energy_l2_varh,
        reactive_energy_l3_varh,
        reactive_export_energy_total_varh,
        reactive_export_energy_l1_varh,
        reactive_export_energy_l2_varh,
        reactive_export_energy_l3_varh,
        apparent_energy_total_vah,
        apparent_energy_l1_vah,
        apparent_energy_l2_vah,
        apparent_energy_l3_vah,
        active_power_total_w,
        active_power_l1_w,
        active_power_l2_w,
        active_power_l3_w,
        reactive_power_total_var,
        reactive_power_l1_var,
        reactive_power_l2_var,
        reactive_power_l3_var,
        apparent_power_total_va,
        apparent_power_l1_va,
        apparent_power_l2_va,
        apparent_power_l3_va,
        voltage_ln_avg_v,
        voltage_l1_v,
        voltage_l2_v,
        voltage_l3_v,
        voltage_ll_avg_v,
        voltage_l12_v,
        voltage_l23_v,
        voltage_l31_v,
        current_total_a,
        current_l1_a,
        current_l2_a,
        current_l3_a,
        neutral_current_a,
        power_factor_total,
        power_factor_l1,
        power_factor_l2,
        power_factor_l3,
        frequency_hz,
        phase_angle_l1_deg,
        phase_angle_l2_deg,
        phase_angle_l3_deg,
        current_thd_total_percent,
        current_thd_l1_percent,
        current_thd_l2_percent,
        current_thd_l3_percent,
        pulse_count,
        is_estimated
  )
  SELECT
        r.bucket_start, we.platform_received_at, r.source_timestamp, r.organization_id, r.site_id, r.gateway_id, r.device_id, r.asset_id,
        r.import_energy_total_wh,
        r.import_energy_l1_wh,
        r.import_energy_l2_wh,
        r.import_energy_l3_wh,
        r.export_energy_total_wh,
        r.export_energy_l1_wh,
        r.export_energy_l2_wh,
        r.export_energy_l3_wh,
        r.reactive_energy_total_varh,
        r.reactive_energy_l1_varh,
        r.reactive_energy_l2_varh,
        r.reactive_energy_l3_varh,
        r.reactive_export_energy_total_varh,
        r.reactive_export_energy_l1_varh,
        r.reactive_export_energy_l2_varh,
        r.reactive_export_energy_l3_varh,
        r.apparent_energy_total_vah,
        r.apparent_energy_l1_vah,
        r.apparent_energy_l2_vah,
        r.apparent_energy_l3_vah,
        r.active_power_total_w,
        r.active_power_l1_w,
        r.active_power_l2_w,
        r.active_power_l3_w,
        r.reactive_power_total_var,
        r.reactive_power_l1_var,
        r.reactive_power_l2_var,
        r.reactive_power_l3_var,
        r.apparent_power_total_va,
        r.apparent_power_l1_va,
        r.apparent_power_l2_va,
        r.apparent_power_l3_va,
        r.voltage_ln_avg_v,
        r.voltage_l1_v,
        r.voltage_l2_v,
        r.voltage_l3_v,
        r.voltage_ll_avg_v,
        r.voltage_l12_v,
        r.voltage_l23_v,
        r.voltage_l31_v,
        r.current_total_a,
        r.current_l1_a,
        r.current_l2_a,
        r.current_l3_a,
        r.neutral_current_a,
        r.power_factor_total,
        r.power_factor_l1,
        r.power_factor_l2,
        r.power_factor_l3,
        r.frequency_hz,
        r.phase_angle_l1_deg,
        r.phase_angle_l2_deg,
        r.phase_angle_l3_deg,
        r.current_thd_total_percent,
        r.current_thd_l1_percent,
        r.current_thd_l2_percent,
        r.current_thd_l3_percent,
        r.pulse_count,
        FALSE
  FROM ranked r
  JOIN window_events we
    ON we.device_id=r.device_id AND we.event_time=r.source_timestamp
  WHERE r.sample_rank=1
    AND r.bucket_start + make_interval(secs => COALESCE(r.capture_interval_seconds,1)) <= v_now
  ON CONFLICT (bucket_start,device_id) DO UPDATE
  SET
        received_at=EXCLUDED.received_at,
        source_timestamp=EXCLUDED.source_timestamp,
        organization_id=EXCLUDED.organization_id,
        site_id=EXCLUDED.site_id,
        gateway_id=EXCLUDED.gateway_id,
        asset_id=COALESCE(EXCLUDED.asset_id,telemetry.energy_measurements.asset_id),
        import_energy_total_wh = COALESCE(EXCLUDED.import_energy_total_wh, telemetry.energy_measurements.import_energy_total_wh),

        import_energy_l1_wh = COALESCE(EXCLUDED.import_energy_l1_wh, telemetry.energy_measurements.import_energy_l1_wh),

        import_energy_l2_wh = COALESCE(EXCLUDED.import_energy_l2_wh, telemetry.energy_measurements.import_energy_l2_wh),

        import_energy_l3_wh = COALESCE(EXCLUDED.import_energy_l3_wh, telemetry.energy_measurements.import_energy_l3_wh),

        export_energy_total_wh = COALESCE(EXCLUDED.export_energy_total_wh, telemetry.energy_measurements.export_energy_total_wh),

        export_energy_l1_wh = COALESCE(EXCLUDED.export_energy_l1_wh, telemetry.energy_measurements.export_energy_l1_wh),

        export_energy_l2_wh = COALESCE(EXCLUDED.export_energy_l2_wh, telemetry.energy_measurements.export_energy_l2_wh),

        export_energy_l3_wh = COALESCE(EXCLUDED.export_energy_l3_wh, telemetry.energy_measurements.export_energy_l3_wh),

        reactive_energy_total_varh = COALESCE(EXCLUDED.reactive_energy_total_varh, telemetry.energy_measurements.reactive_energy_total_varh),

        reactive_energy_l1_varh = COALESCE(EXCLUDED.reactive_energy_l1_varh, telemetry.energy_measurements.reactive_energy_l1_varh),

        reactive_energy_l2_varh = COALESCE(EXCLUDED.reactive_energy_l2_varh, telemetry.energy_measurements.reactive_energy_l2_varh),

        reactive_energy_l3_varh = COALESCE(EXCLUDED.reactive_energy_l3_varh, telemetry.energy_measurements.reactive_energy_l3_varh),

        reactive_export_energy_total_varh = COALESCE(EXCLUDED.reactive_export_energy_total_varh, telemetry.energy_measurements.reactive_export_energy_total_varh),

        reactive_export_energy_l1_varh = COALESCE(EXCLUDED.reactive_export_energy_l1_varh, telemetry.energy_measurements.reactive_export_energy_l1_varh),

        reactive_export_energy_l2_varh = COALESCE(EXCLUDED.reactive_export_energy_l2_varh, telemetry.energy_measurements.reactive_export_energy_l2_varh),

        reactive_export_energy_l3_varh = COALESCE(EXCLUDED.reactive_export_energy_l3_varh, telemetry.energy_measurements.reactive_export_energy_l3_varh),

        apparent_energy_total_vah = COALESCE(EXCLUDED.apparent_energy_total_vah, telemetry.energy_measurements.apparent_energy_total_vah),

        apparent_energy_l1_vah = COALESCE(EXCLUDED.apparent_energy_l1_vah, telemetry.energy_measurements.apparent_energy_l1_vah),

        apparent_energy_l2_vah = COALESCE(EXCLUDED.apparent_energy_l2_vah, telemetry.energy_measurements.apparent_energy_l2_vah),

        apparent_energy_l3_vah = COALESCE(EXCLUDED.apparent_energy_l3_vah, telemetry.energy_measurements.apparent_energy_l3_vah),

        active_power_total_w = COALESCE(EXCLUDED.active_power_total_w, telemetry.energy_measurements.active_power_total_w),

        active_power_l1_w = COALESCE(EXCLUDED.active_power_l1_w, telemetry.energy_measurements.active_power_l1_w),

        active_power_l2_w = COALESCE(EXCLUDED.active_power_l2_w, telemetry.energy_measurements.active_power_l2_w),

        active_power_l3_w = COALESCE(EXCLUDED.active_power_l3_w, telemetry.energy_measurements.active_power_l3_w),

        reactive_power_total_var = COALESCE(EXCLUDED.reactive_power_total_var, telemetry.energy_measurements.reactive_power_total_var),

        reactive_power_l1_var = COALESCE(EXCLUDED.reactive_power_l1_var, telemetry.energy_measurements.reactive_power_l1_var),

        reactive_power_l2_var = COALESCE(EXCLUDED.reactive_power_l2_var, telemetry.energy_measurements.reactive_power_l2_var),

        reactive_power_l3_var = COALESCE(EXCLUDED.reactive_power_l3_var, telemetry.energy_measurements.reactive_power_l3_var),

        apparent_power_total_va = COALESCE(EXCLUDED.apparent_power_total_va, telemetry.energy_measurements.apparent_power_total_va),

        apparent_power_l1_va = COALESCE(EXCLUDED.apparent_power_l1_va, telemetry.energy_measurements.apparent_power_l1_va),

        apparent_power_l2_va = COALESCE(EXCLUDED.apparent_power_l2_va, telemetry.energy_measurements.apparent_power_l2_va),

        apparent_power_l3_va = COALESCE(EXCLUDED.apparent_power_l3_va, telemetry.energy_measurements.apparent_power_l3_va),

        voltage_ln_avg_v = COALESCE(EXCLUDED.voltage_ln_avg_v, telemetry.energy_measurements.voltage_ln_avg_v),

        voltage_l1_v = COALESCE(EXCLUDED.voltage_l1_v, telemetry.energy_measurements.voltage_l1_v),

        voltage_l2_v = COALESCE(EXCLUDED.voltage_l2_v, telemetry.energy_measurements.voltage_l2_v),

        voltage_l3_v = COALESCE(EXCLUDED.voltage_l3_v, telemetry.energy_measurements.voltage_l3_v),

        voltage_ll_avg_v = COALESCE(EXCLUDED.voltage_ll_avg_v, telemetry.energy_measurements.voltage_ll_avg_v),

        voltage_l12_v = COALESCE(EXCLUDED.voltage_l12_v, telemetry.energy_measurements.voltage_l12_v),

        voltage_l23_v = COALESCE(EXCLUDED.voltage_l23_v, telemetry.energy_measurements.voltage_l23_v),

        voltage_l31_v = COALESCE(EXCLUDED.voltage_l31_v, telemetry.energy_measurements.voltage_l31_v),

        current_total_a = COALESCE(EXCLUDED.current_total_a, telemetry.energy_measurements.current_total_a),

        current_l1_a = COALESCE(EXCLUDED.current_l1_a, telemetry.energy_measurements.current_l1_a),

        current_l2_a = COALESCE(EXCLUDED.current_l2_a, telemetry.energy_measurements.current_l2_a),

        current_l3_a = COALESCE(EXCLUDED.current_l3_a, telemetry.energy_measurements.current_l3_a),

        neutral_current_a = COALESCE(EXCLUDED.neutral_current_a, telemetry.energy_measurements.neutral_current_a),

        power_factor_total = COALESCE(EXCLUDED.power_factor_total, telemetry.energy_measurements.power_factor_total),

        power_factor_l1 = COALESCE(EXCLUDED.power_factor_l1, telemetry.energy_measurements.power_factor_l1),

        power_factor_l2 = COALESCE(EXCLUDED.power_factor_l2, telemetry.energy_measurements.power_factor_l2),

        power_factor_l3 = COALESCE(EXCLUDED.power_factor_l3, telemetry.energy_measurements.power_factor_l3),

        frequency_hz = COALESCE(EXCLUDED.frequency_hz, telemetry.energy_measurements.frequency_hz),

        phase_angle_l1_deg = COALESCE(EXCLUDED.phase_angle_l1_deg, telemetry.energy_measurements.phase_angle_l1_deg),

        phase_angle_l2_deg = COALESCE(EXCLUDED.phase_angle_l2_deg, telemetry.energy_measurements.phase_angle_l2_deg),

        phase_angle_l3_deg = COALESCE(EXCLUDED.phase_angle_l3_deg, telemetry.energy_measurements.phase_angle_l3_deg),

        current_thd_total_percent = COALESCE(EXCLUDED.current_thd_total_percent, telemetry.energy_measurements.current_thd_total_percent),

        current_thd_l1_percent = COALESCE(EXCLUDED.current_thd_l1_percent, telemetry.energy_measurements.current_thd_l1_percent),

        current_thd_l2_percent = COALESCE(EXCLUDED.current_thd_l2_percent, telemetry.energy_measurements.current_thd_l2_percent),

        current_thd_l3_percent = COALESCE(EXCLUDED.current_thd_l3_percent, telemetry.energy_measurements.current_thd_l3_percent),

        pulse_count = COALESCE(EXCLUDED.pulse_count, telemetry.energy_measurements.pulse_count),
        is_estimated=FALSE
  WHERE
        COALESCE(EXCLUDED.source_timestamp, EXCLUDED.received_at)
            > COALESCE(
                telemetry.energy_measurements.source_timestamp,
                telemetry.energy_measurements.received_at,
                '-infinity'::timestamptz
              )
    AND v_now <= telemetry.capture_bucket_correction_deadline
    (
        EXCLUDED.site_id,
        EXCLUDED.bucket_start
    );

  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
  UPDATE telemetry.pipeline_state
  SET last_received_at=v_window_end,last_completed_at=clock_timestamp(),last_inserted_rows=v_affected_rows,
      last_status='SUCCESS',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE NOTICE 'Closed-bucket energy routing succeeded: window=(%, %], affected_rows=%',v_window_start,v_window_end,v_affected_rows;
EXCEPTION WHEN OTHERS THEN
  UPDATE telemetry.pipeline_state
  SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='FAILED',
      last_error=SQLSTATE||': '||SQLERRM,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE;
END;
$procedure$;


-- ----------------------------------------------------------------------------
-- 3. Environment loader: the regenerated offline-generator artifact, verbatim.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental(IN p_overlap interval DEFAULT '00:15:00'::interval, IN p_max_window interval DEFAULT NULL)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    -- Migration 303: ems.routing_scope (transaction-local; set only by
    -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
    v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting('ems.routing_scope', true), ''), 'forward');
    v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = 'late_sweep' THEN 'environment_measurements_late_sweep' ELSE 'environment_measurements' END;
    v_event_min TIMESTAMPTZ;
    v_event_max TIMESTAMPTZ;
    v_forward_checkpoint TIMESTAMPTZ;
    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
    v_updated BIGINT := 0;
    v_inserted BIGINT := 0;
    v_lock_acquired BOOLEAN;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_update_floor TIMESTAMPTZ;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_overlap must be zero or positive';
    END IF;

    -- Migration 207: reject a non-positive explicit bound. NULL (the
    -- default, and what a direct/manual invocation passes) means "no
    -- bound" -- byte-for-byte the pre-207 behaviour.
    IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_max_window must be positive when supplied; received %', p_max_window;
    END IF;

    -- Migration 303: reject an unknown scope.
    IF v_scope NOT IN ('forward', 'late_sweep') THEN
        RAISE EXCEPTION 'ems.routing_scope must be forward or late_sweep; received %', v_scope;
    END IF;

    SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.load_environment_measurements_incremental',0))
    INTO v_lock_acquired;
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status='SKIPPED_LOCKED', last_error=NULL, updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name=v_pipeline_name
    FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at=clock_timestamp(), last_status='RUNNING', last_error=NULL, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    -- Migration 267: bound the window-end lookup to recent event_time so it only
    -- reads uncompressed chunks (normalized_points compress_after = 1 day). The
    -- bounded max can only be lower than the global max, which delays -- never
    -- skips -- rows; the global lookup remains the fallback when no row has a
    -- recent event_time.
    SELECT max(platform_received_at) INTO v_window_end
    FROM telemetry.normalized_points
    WHERE platform_received_at IS NOT NULL
      AND event_time >= now() - INTERVAL '1 day';
    IF v_window_end IS NULL THEN
      SELECT max(platform_received_at) INTO v_window_end
      FROM telemetry.normalized_points
      WHERE platform_received_at IS NOT NULL;
    END IF;
    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
            last_status='NO_SOURCE_DATA', updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    -- Migration 207: cap the forward processing boundary to the previous
    -- checkpoint plus p_max_window when a caller supplies one and a
    -- previous checkpoint already exists. NULL (the default) leaves
    -- v_window_end exactly as computed above -- byte-for-byte the
    -- pre-207 behaviour. See telemetry.load_energy_measurements_incremental
    -- for the full rationale; this is the identical bound applied to the
    -- environment routing loader. Advisory lock, checkpoint keying,
    -- overlap semantics, the routing/calculation SQL below, and the
    -- EXCEPTION-rolls-back-the-watermark contract are all unchanged.
    IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Migration 303: forward runs read only normalized_points chunks newer
    -- than the newest compressed chunk (event_time >= its range_end), so
    -- chunk exclusion skips every compressed chunk instead of scanning its
    -- batch metadata on every run. Rows older than that floor (late data in
    -- compressed chunks) are routed by the hourly late-data sweep, which reads
    -- only event_time < floor and never passes the forward checkpoint.
    SELECT max(c.range_end) INTO v_event_min
    FROM timescaledb_information.chunks c
    WHERE c.hypertable_schema='telemetry'
      AND c.hypertable_name='normalized_points'
      AND c.is_compressed;
    v_event_min := COALESCE(v_event_min, '-infinity'::timestamptz);
    v_event_max := 'infinity'::timestamptz;
    IF v_scope = 'late_sweep' THEN
        v_event_max := v_event_min;
        v_event_min := '-infinity'::timestamptz;
        SELECT last_received_at INTO v_forward_checkpoint
        FROM telemetry.pipeline_state WHERE pipeline_name='environment_measurements';
        v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, '-infinity'::timestamptz));
        IF v_previous_checkpoint IS NOT NULL THEN
            v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
        END IF;
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
    -- discovered by their new platform receipt timestamp, so the historical
    -- correction tolerance does not need to be rescanned every minute.
    p_overlap := LEAST(p_overlap, INTERVAL '1 minute');

    v_window_start := CASE WHEN v_previous_checkpoint IS NULL
                           THEN '-infinity'::TIMESTAMPTZ
                           ELSE v_previous_checkpoint - p_overlap END;

    CREATE TEMP TABLE tmp_environment_candidates ON COMMIT DROP AS
    WITH window_events AS MATERIALIZED
    (
      SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
      FROM telemetry.normalized_points np
      JOIN metadata.devices d ON d.id=np.device_id
      JOIN config.device_profiles dp ON dp.id=d.profile_id
      WHERE np.platform_received_at > v_window_start
        AND np.platform_received_at <= v_window_end
        AND np.event_time >= v_event_min
        AND np.event_time < v_event_max
        AND dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND np.logical_point IN
        (
            'ENV_TEMPERATURE',
            'ENV_RELATIVE_HUMIDITY',
            'ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY',
            'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW',
            'EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE',
            'BATTERY_VOLTAGE',
            'DEVICE_STATUS_CODE'
        )
      GROUP BY np.device_id,np.event_time
    ),
    full_resolution AS MATERIALIZED
    (
SELECT
    MAX(np.platform_received_at) AS received_at,
    np.event_time AS source_timestamp,
    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id,
    NULL::UUID AS asset_id,
    NULL::SMALLINT AS measurement_interval_seconds,
    NULL::SMALLINT AS quality_code,
    FALSE AS is_estimated,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_TEMPERATURE')::DOUBLE PRECISION AS temperature_c,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_RELATIVE_HUMIDITY')::DOUBLE PRECISION AS humidity_percent,
    NULL::DOUBLE PRECISION AS pressure_hpa,
    NULL::DOUBLE PRECISION AS co2_ppm,
    NULL::DOUBLE PRECISION AS voc_ppb,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point IN ('BATTERY_VOLTAGE','DEVICE_BATTERY_VOLTAGE'))::DOUBLE PRECISION AS battery_voltage_v,
    NULL::DOUBLE PRECISION AS signal_strength_dbm,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_ILLUMINANCE_LUX')::DOUBLE PRECISION AS illuminance_lux,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'OCCUPANCY_ACTIVITY')::DOUBLE PRECISION AS occupancy_activity,
    NULL::BIGINT AS raw_archive_id,
    ROUND(MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT'))::INTEGER AS seconds_since_last_pir_event,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'PULSE_INPUT_1_RAW')::DOUBLE PRECISION AS pulse_input_1_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_1_RAW')::DOUBLE PRECISION AS external_input_1_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_2_RAW')::DOUBLE PRECISION AS external_input_2_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_3_RAW')::DOUBLE PRECISION AS external_input_3_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_4_RAW')::DOUBLE PRECISION AS external_input_4_raw,
    ROUND(MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'DEVICE_STATUS_CODE'))::INTEGER AS device_status_code
FROM window_events we
CROSS JOIN LATERAL
(
  SELECT src_np.*
  FROM telemetry.normalized_points src_np
  WHERE src_np.device_id = we.device_id
    AND src_np.event_time = we.event_time
  OFFSET 0
) np
JOIN metadata.devices d ON d.id = np.device_id
JOIN config.device_profiles dp ON dp.id = d.profile_id
WHERE dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
  AND np.logical_point IN
  (
      'ENV_TEMPERATURE',
      'ENV_RELATIVE_HUMIDITY',
      'ENV_ILLUMINANCE_LUX',
      'OCCUPANCY_ACTIVITY',
      'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
      'PULSE_INPUT_1_RAW',
      'EXTERNAL_SENSOR_INPUT_1_RAW',
      'EXTERNAL_SENSOR_INPUT_2_RAW',
      'EXTERNAL_SENSOR_INPUT_3_RAW',
      'EXTERNAL_SENSOR_INPUT_4_RAW',
      'DEVICE_BATTERY_VOLTAGE',
      'BATTERY_VOLTAGE',
      'DEVICE_STATUS_CODE'
  )
GROUP BY np.event_time, np.organization_id, np.site_id, np.gateway_id, np.device_id
    ),
    resolved AS
    (
      SELECT fr.*,b.policy_id,b.capture_interval_seconds,
             b.late_arrival_tolerance_seconds,b.bucket_start
      FROM full_resolution fr
      CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
        (fr.site_id,COALESCE(fr.source_timestamp,fr.received_at)) AS b
    ),
    ranked AS
    (
      SELECT resolved.*,
             row_number() OVER
             (
               PARTITION BY resolved.device_id,resolved.policy_id,resolved.bucket_start
               ORDER BY COALESCE(resolved.source_timestamp,resolved.received_at) DESC,
                        resolved.received_at DESC NULLS LAST
             ) AS sample_rank
      FROM resolved
    )
    SELECT ranked.bucket_start,
           COALESCE(we.platform_received_at,ranked.received_at) AS received_at,
           ranked.source_timestamp,ranked.organization_id,ranked.site_id,ranked.gateway_id,
           ranked.device_id,ranked.asset_id,
           -- Migration 226: point-in-time, tenant-guarded Space resolution.
           -- A correlated scalar sub-select over metadata.space_points for
           -- the environmental logical points, effective at this reading's
           -- event time, restricted to the same organization as the row.
           -- (array_agg(DISTINCT space_id))[1] ... HAVING count(DISTINCT ...) = 1:
           --   * exactly one applicable Space  -> that space_id
           --   * no applicable binding         -> no row -> NULL
           --   * two or more distinct Spaces   -> HAVING fails -> NULL (never guesses)
           -- (core PostgreSQL has no max()/min() aggregate for uuid, so the
           -- single value is taken from a DISTINCT array gated by the count.)
           -- Uses metadata.space_points' migration-224 effective_range
           -- (a generated [) tstzrange; effective_to IS NULL => 'infinity').
           -- No row fan-out of the outer query.
           (
               SELECT (array_agg(DISTINCT sp.space_id))[1]
               FROM metadata.space_points sp
               JOIN metadata.spaces sps ON sps.id = sp.space_id
               WHERE sp.logical_point_id IN
               (
                   SELECT lp.id
                   FROM metadata.logical_points lp
                   WHERE lp.name IN
                   (
                       'ENV_TEMPERATURE',
                       'ENV_RELATIVE_HUMIDITY',
                       'ENV_ILLUMINANCE_LUX',
                       'OCCUPANCY_ACTIVITY',
                       'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
                       'PULSE_INPUT_1_RAW',
                       'EXTERNAL_SENSOR_INPUT_1_RAW',
                       'EXTERNAL_SENSOR_INPUT_2_RAW',
                       'EXTERNAL_SENSOR_INPUT_3_RAW',
                       'EXTERNAL_SENSOR_INPUT_4_RAW',
                       'DEVICE_BATTERY_VOLTAGE',
                       'BATTERY_VOLTAGE',
                       'DEVICE_STATUS_CODE'
                   )
               )
                 AND sp.effective_range @> COALESCE(ranked.source_timestamp, ranked.received_at)
                 AND sps.organization_id = ranked.organization_id
                 -- Migration 228: scope Space resolution to the Point instance of
                 -- THIS device -- (device_id, logical_point_id) is the
                 -- config.device_point_configuration PK. metadata.logical_points
                 -- is a global vocabulary, so a fleet of identical devices shares
                 -- one logical_point_id; without this predicate every same-org
                 -- device would resolve to a single Space. asset_devices is
                 -- unrelated / unchanged.
                 AND sp.device_id = ranked.device_id
               HAVING count(DISTINCT sp.space_id) = 1
           ) AS space_id,
           COALESCE(ranked.capture_interval_seconds,ranked.measurement_interval_seconds) AS measurement_interval_seconds,
           ranked.quality_code,ranked.is_estimated,
           ranked.temperature_c,
           ranked.humidity_percent,
           ranked.pressure_hpa,
           ranked.co2_ppm,
           ranked.voc_ppb,
           ranked.battery_voltage_v,
           ranked.signal_strength_dbm,
           ranked.illuminance_lux,
           ranked.occupancy_activity,
           ranked.raw_archive_id,
           ranked.seconds_since_last_pir_event,
           ranked.pulse_input_1_raw,
           ranked.external_input_1_raw,
           ranked.external_input_2_raw,
           ranked.external_input_3_raw,
           ranked.external_input_4_raw,
           ranked.device_status_code,
           ranked.bucket_start + make_interval(secs => ranked.capture_interval_seconds)
             + make_interval(secs => ranked.late_arrival_tolerance_seconds) AS correction_deadline
    FROM ranked
    JOIN window_events we
      ON we.device_id=ranked.device_id AND we.event_time=ranked.source_timestamp
    WHERE ranked.sample_rank=1
      AND ranked.bucket_start + make_interval(secs => COALESCE(ranked.capture_interval_seconds,1)) <= v_now;

    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

    -- Migration 291: only candidates still inside their correction window
    -- (v_now <= correction_deadline) can be updated, so bound the UPDATE to
    -- the earliest such bucket_start. That keeps it out of compressed chunks,
    -- which it otherwise decompressed in full on every run.
    SELECT min(bucket_start) INTO v_update_floor
    FROM tmp_environment_candidates
    WHERE v_now <= correction_deadline;

    IF v_update_floor IS NOT NULL THEN
    UPDATE telemetry.environment_measurements t
    SET received_at=s.received_at,
        source_timestamp=s.source_timestamp,
        organization_id=s.organization_id,
        site_id=s.site_id,
        gateway_id=s.gateway_id,
        asset_id=COALESCE(s.asset_id,t.asset_id),
        space_id=COALESCE(s.space_id,t.space_id),
        measurement_interval_seconds=s.measurement_interval_seconds,
        quality_code=COALESCE(s.quality_code,t.quality_code),
        is_estimated=COALESCE(s.is_estimated,t.is_estimated),
        temperature_c=COALESCE(s.temperature_c,t.temperature_c),
        humidity_percent=COALESCE(s.humidity_percent,t.humidity_percent),
        pressure_hpa=COALESCE(s.pressure_hpa,t.pressure_hpa),
        co2_ppm=COALESCE(s.co2_ppm,t.co2_ppm),
        voc_ppb=COALESCE(s.voc_ppb,t.voc_ppb),
        battery_voltage_v=COALESCE(s.battery_voltage_v,t.battery_voltage_v),
        signal_strength_dbm=COALESCE(s.signal_strength_dbm,t.signal_strength_dbm),
        illuminance_lux=COALESCE(s.illuminance_lux,t.illuminance_lux),
        occupancy_activity=COALESCE(s.occupancy_activity,t.occupancy_activity),
        raw_archive_id=COALESCE(s.raw_archive_id,t.raw_archive_id),
        seconds_since_last_pir_event=COALESCE(s.seconds_since_last_pir_event,t.seconds_since_last_pir_event),
        pulse_input_1_raw=COALESCE(s.pulse_input_1_raw,t.pulse_input_1_raw),
        external_input_1_raw=COALESCE(s.external_input_1_raw,t.external_input_1_raw),
        external_input_2_raw=COALESCE(s.external_input_2_raw,t.external_input_2_raw),
        external_input_3_raw=COALESCE(s.external_input_3_raw,t.external_input_3_raw),
        external_input_4_raw=COALESCE(s.external_input_4_raw,t.external_input_4_raw),
        device_status_code=COALESCE(s.device_status_code,t.device_status_code)
    FROM tmp_environment_candidates s
    WHERE t.bucket_start >= v_update_floor
      AND t.bucket_start=s.bucket_start
      AND t.device_id=s.device_id
      AND COALESCE(s.source_timestamp,s.received_at) >
          COALESCE(t.source_timestamp,t.received_at,'-infinity'::TIMESTAMPTZ)
      AND v_now <= s.correction_deadline;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    END IF;

    INSERT INTO telemetry.environment_measurements
    (
      bucket_start, received_at, source_timestamp,
      organization_id, site_id, gateway_id, device_id, asset_id, space_id,
      measurement_interval_seconds, quality_code, is_estimated,
      temperature_c,
      humidity_percent,
      pressure_hpa,
      co2_ppm,
      voc_ppb,
      battery_voltage_v,
      signal_strength_dbm,
      illuminance_lux,
      occupancy_activity,
      raw_archive_id,
      seconds_since_last_pir_event,
      pulse_input_1_raw,
      external_input_1_raw,
      external_input_2_raw,
      external_input_3_raw,
      external_input_4_raw,
      device_status_code
    )
    SELECT
      s.bucket_start, s.received_at, s.source_timestamp,
      s.organization_id, s.site_id, s.gateway_id, s.device_id, s.asset_id, s.space_id,
      s.measurement_interval_seconds, s.quality_code, s.is_estimated,
      s.temperature_c,
      s.humidity_percent,
      s.pressure_hpa,
      s.co2_ppm,
      s.voc_ppb,
      s.battery_voltage_v,
      s.signal_strength_dbm,
      s.illuminance_lux,
      s.occupancy_activity,
      s.raw_archive_id,
      s.seconds_since_last_pir_event,
      s.pulse_input_1_raw,
      s.external_input_1_raw,
      s.external_input_2_raw,
      s.external_input_3_raw,
      s.external_input_4_raw,
      s.device_status_code
    FROM tmp_environment_candidates s
    ON CONFLICT (bucket_start,device_id) WHERE device_id IS NOT NULL DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    UPDATE telemetry.pipeline_state
    SET last_received_at=v_window_end,
        last_completed_at=clock_timestamp(),
        last_inserted_rows=v_updated+v_inserted,
        last_status='SUCCESS', last_error=NULL, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    RAISE NOTICE 'Environment routing succeeded: window=(%, %], updated=%, inserted=%',
      v_window_start, v_window_end, v_updated, v_inserted;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
        last_status='FAILED', last_error=SQLSTATE || ': ' || SQLERRM, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RAISE;
END;
$procedure$;

COMMENT ON PROCEDURE telemetry.load_environment_measurements_incremental(interval, interval) IS
'Incrementally routes closed-bucket normalized environment telemetry into telemetry.environment_measurements. Checkpoint is telemetry.pipeline_state(''environment_measurements'').last_received_at, keyed on telemetry.normalized_points.platform_received_at; a pg_try_advisory_xact_lock serialises concurrent runs; the single transaction''s EXCEPTION handler re-RAISEs, so a caught failure rolls back the watermark with the data. '
'Migration 207: p_max_window (default NULL) optionally caps the forward processing boundary to previous_checkpoint + p_max_window instead of always advancing to max(telemetry.normalized_points.platform_received_at). NULL preserves the exact prior behaviour. The scheduled wrapper telemetry.run_environment_routing_job passes a bounded value (default 2 hours, config.max_window-overridable) so an unattended multi-hour backlog self-drains. No intermediate COMMIT is introduced. Mirrors migration 205 / telemetry.load_energy_measurements_incremental(). '
'Migration 226: additionally resolves telemetry.environment_measurements.space_id at routing time from metadata.space_points (point-in-time via effective_range, restricted to the row''s organization), writing NULL when there is no effective binding or when applicable bindings are ambiguous. All bounded-catch-up / watermark / overlap / correction-deadline / idempotency / advisory-lock behaviour is unchanged; quality_code is still written NULL. '
'Phase 4 (migration 227): this body is emitted by the offline generator scripts/codegen/generate_routing_procedure.py from config.parameter_routing (declarative spec scripts/codegen/routing/environment_measurements.routing.json), not hand-typed. It is behaviourally identical to the migration-226 body -- the same 12 routed logical points map to the same 12 destination columns with the same casts, the same legacy BATTERY_VOLTAGE compatibility alias feeds battery_voltage_v, and Space resolution, the watermark, bounded catch-up and the EXCEPTION contract are unchanged; only list/line formatting differs. No config.parameter_routing row is read at runtime.';

-- ----------------------------------------------------------------------------
-- 4. Late-data sweep job procedure.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.run_routing_late_sweep_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_overlap    INTERVAL := INTERVAL '15 minutes';
    v_max_window INTERVAL := INTERVAL '1 day';
BEGIN
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(BTRIM(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;

    IF config IS NOT NULL
       AND config ? 'max_window'
       AND NULLIF(BTRIM(config ->> 'max_window'), '') IS NOT NULL
    THEN
        v_max_window := (config ->> 'max_window')::INTERVAL;
    END IF;

    IF v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'Routing late sweep overlap cannot be negative: %', v_overlap;
    END IF;

    IF v_max_window IS NULL OR v_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'Routing late sweep max_window must be a positive interval: %', v_max_window;
    END IF;

    -- One transaction per loader, so each holds its advisory lock only for its
    -- own sweep. The scope setting is transaction-local and ends with COMMIT.
    PERFORM set_config('ems.routing_scope', 'late_sweep', true);
    CALL telemetry.load_energy_measurements_incremental(v_overlap, v_max_window);
    COMMIT;

    PERFORM set_config('ems.routing_scope', 'late_sweep', true);
    CALL telemetry.load_environment_measurements_incremental(v_overlap, v_max_window);
    COMMIT;
END;
$$;

COMMENT ON PROCEDURE telemetry.run_routing_late_sweep_job(INTEGER, JSONB) IS
'Migration 303: hourly late-data sweep for both routing loaders. Sets the transaction-local ems.routing_scope = ''late_sweep'' and CALLs telemetry.load_energy_measurements_incremental and telemetry.load_environment_measurements_incremental, each in its own transaction. In that scope a loader uses checkpoint <pipeline>_late_sweep, reads only normalized_points rows with event_time below the newest compressed chunk''s range_end (rows the bounded forward runs skip), and never passes the forward checkpoint. config: overlap (default 15 minutes, replay capped at 1 minute by the loaders as for forward runs), max_window (default 1 day).';

REVOKE ALL ON PROCEDURE telemetry.run_routing_late_sweep_job(INTEGER, JSONB) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE telemetry.run_routing_late_sweep_job(INTEGER, JSONB) TO ems_admin;


-- ----------------------------------------------------------------------------
-- 5. Sweep checkpoints start at the forward checkpoints: every receipt before
--    them was routed by the pre-303 (unbounded) forward body, i.e. the sweep's
--    work up to that point is complete. Status SUCCESS records exactly that
--    (and keeps scripts/verify/verify_pipeline.sh, which requires every row to
--    be SUCCESS, green until the first hourly sweep); last_completed_at stays
--    NULL until a sweep actually runs.
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name, last_received_at, last_status)
SELECT ps.pipeline_name || '_late_sweep', ps.last_received_at, 'SUCCESS'
FROM telemetry.pipeline_state AS ps
WHERE ps.pipeline_name IN ('energy_measurements', 'environment_measurements')
ON CONFLICT (pipeline_name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 6. Job: hourly, fixed schedule at hh:31:30 UTC. On the migration-300 grid
--    that is +1:30, clear of routing (+4:10 / +4:15) and normalization (+2:40
--    does not take the routing locks). max_runtime 10 minutes.
-- ----------------------------------------------------------------------------
DO $jobs$
DECLARE
    v_job_id INTEGER;
BEGIN
    v_job_id := add_job(
        'telemetry.run_routing_late_sweep_job'::regproc,
        schedule_interval => INTERVAL '1 hour',
        initial_start     => date_trunc('hour', now(), 'UTC') + INTERVAL '1 hour 31 minutes 30 seconds',
        config            => jsonb_build_object('overlap', '15 minutes', 'max_window', '1 day'),
        scheduled         => TRUE,
        fixed_schedule    => TRUE
    );

    PERFORM alter_job(v_job_id,
                      max_runtime  => INTERVAL '10 minutes',
                      max_retries  => 3,
                      retry_period => INTERVAL '5 minutes');

    RAISE NOTICE 'Migration 303: registered telemetry.run_routing_late_sweep_job as job %, first run % UTC',
        v_job_id, (date_trunc('hour', now(), 'UTC') + INTERVAL '1 hour 31 minutes 30 seconds') AT TIME ZONE 'UTC';
END
$jobs$;


-- ----------------------------------------------------------------------------
-- 7. Postconditions: new bodies exact; each fragment exactly once; reverting
--    the fragments gives back the migration-267 / migration-291 bodies byte for
--    byte; one scheduled sweep job; both sweep checkpoints present.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_energy TEXT;
    v_env    TEXT;
BEGIN
    SELECT replace(prosrc, E'\r', '') INTO v_energy FROM pg_proc
    WHERE oid = 'telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure;
    SELECT replace(prosrc, E'\r', '') INTO v_env FROM pg_proc
    WHERE oid = 'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure;

    IF md5(v_energy) IS DISTINCT FROM 'ee8c1867c0426587cda0d40467be57a2' THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: energy loader body md5 % is not the expected migration-303 body.', md5(v_energy);
    END IF;
    IF md5(v_env) IS DISTINCT FROM 'be09c0efb5cc8f5f819f2bb30b8d5370' THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: environment loader body md5 % is not the expected migration-303 body.', md5(v_env);
    END IF;

    IF (length(v_energy) - length(replace(v_energy, '  -- Migration 303: ems.routing_scope (transaction-local; set only by
  -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
  v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting(''ems.routing_scope'', true), ''''), ''forward'');
  v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = ''late_sweep'' THEN ''energy_measurements_late_sweep'' ELSE ''energy_measurements'' END;
  v_event_min TIMESTAMPTZ;
  v_event_max TIMESTAMPTZ;
  v_forward_checkpoint TIMESTAMPTZ;
', ''))) / length('  -- Migration 303: ems.routing_scope (transaction-local; set only by
  -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
  v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting(''ems.routing_scope'', true), ''''), ''forward'');
  v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = ''late_sweep'' THEN ''energy_measurements_late_sweep'' ELSE ''energy_measurements'' END;
  v_event_min TIMESTAMPTZ;
  v_event_max TIMESTAMPTZ;
  v_forward_checkpoint TIMESTAMPTZ;
') <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: energy fragment 1 does not appear exactly once.';
    END IF;
    IF (length(v_energy) - length(replace(v_energy, '  END IF;

  -- Migration 303: reject an unknown scope.
  IF v_scope NOT IN (''forward'', ''late_sweep'') THEN
    RAISE EXCEPTION ''ems.routing_scope must be forward or late_sweep; received %'', v_scope;
  END IF;

  SELECT pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_energy_measurements_incremental'',0))', ''))) / length('  END IF;

  -- Migration 303: reject an unknown scope.
  IF v_scope NOT IN (''forward'', ''late_sweep'') THEN
    RAISE EXCEPTION ''ems.routing_scope must be forward or late_sweep; received %'', v_scope;
  END IF;

  SELECT pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_energy_measurements_incremental'',0))') <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: energy fragment 2 does not appear exactly once.';
    END IF;
    IF (length(v_energy) - length(replace(v_energy, '    v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
  END IF;

  -- Migration 303: forward runs read only normalized_points chunks newer
  -- than the newest compressed chunk (event_time >= its range_end), so
  -- chunk exclusion skips every compressed chunk instead of scanning its
  -- batch metadata on every run. Rows older than that floor (late data in
  -- compressed chunks) are routed by the hourly late-data sweep, which reads
  -- only event_time < floor and never passes the forward checkpoint.
  SELECT max(c.range_end) INTO v_event_min
  FROM timescaledb_information.chunks c
  WHERE c.hypertable_schema=''telemetry''
    AND c.hypertable_name=''normalized_points''
    AND c.is_compressed;
  v_event_min := COALESCE(v_event_min, ''-infinity''::timestamptz);
  v_event_max := ''infinity''::timestamptz;
  IF v_scope = ''late_sweep'' THEN
    v_event_max := v_event_min;
    v_event_min := ''-infinity''::timestamptz;
    SELECT last_received_at INTO v_forward_checkpoint
    FROM telemetry.pipeline_state WHERE pipeline_name=''energy_measurements'';
    v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, ''-infinity''::timestamptz));
    IF v_previous_checkpoint IS NOT NULL THEN
      v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
    END IF;
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
', ''))) / length('    v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
  END IF;

  -- Migration 303: forward runs read only normalized_points chunks newer
  -- than the newest compressed chunk (event_time >= its range_end), so
  -- chunk exclusion skips every compressed chunk instead of scanning its
  -- batch metadata on every run. Rows older than that floor (late data in
  -- compressed chunks) are routed by the hourly late-data sweep, which reads
  -- only event_time < floor and never passes the forward checkpoint.
  SELECT max(c.range_end) INTO v_event_min
  FROM timescaledb_information.chunks c
  WHERE c.hypertable_schema=''telemetry''
    AND c.hypertable_name=''normalized_points''
    AND c.is_compressed;
  v_event_min := COALESCE(v_event_min, ''-infinity''::timestamptz);
  v_event_max := ''infinity''::timestamptz;
  IF v_scope = ''late_sweep'' THEN
    v_event_max := v_event_min;
    v_event_min := ''-infinity''::timestamptz;
    SELECT last_received_at INTO v_forward_checkpoint
    FROM telemetry.pipeline_state WHERE pipeline_name=''energy_measurements'';
    v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, ''-infinity''::timestamptz));
    IF v_previous_checkpoint IS NOT NULL THEN
      v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
    END IF;
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
') <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: energy fragment 3 does not appear exactly once.';
    END IF;
    IF (length(v_energy) - length(replace(v_energy, '      AND np.platform_received_at <= v_window_end
      AND np.event_time >= v_event_min
      AND np.event_time < v_event_max
    GROUP BY np.device_id,np.event_time
', ''))) / length('      AND np.platform_received_at <= v_window_end
      AND np.event_time >= v_event_min
      AND np.event_time < v_event_max
    GROUP BY np.device_id,np.event_time
') <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: energy fragment 4 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, '    -- Migration 303: ems.routing_scope (transaction-local; set only by
    -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
    v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting(''ems.routing_scope'', true), ''''), ''forward'');
    v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = ''late_sweep'' THEN ''environment_measurements_late_sweep'' ELSE ''environment_measurements'' END;
    v_event_min TIMESTAMPTZ;
    v_event_max TIMESTAMPTZ;
    v_forward_checkpoint TIMESTAMPTZ;
', ''))) / length('    -- Migration 303: ems.routing_scope (transaction-local; set only by
    -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
    v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting(''ems.routing_scope'', true), ''''), ''forward'');
    v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = ''late_sweep'' THEN ''environment_measurements_late_sweep'' ELSE ''environment_measurements'' END;
    v_event_min TIMESTAMPTZ;
    v_event_max TIMESTAMPTZ;
    v_forward_checkpoint TIMESTAMPTZ;
') <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: environment fragment 1 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, '    END IF;

    -- Migration 303: reject an unknown scope.
    IF v_scope NOT IN (''forward'', ''late_sweep'') THEN
        RAISE EXCEPTION ''ems.routing_scope must be forward or late_sweep; received %'', v_scope;
    END IF;

    SELECT pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_environment_measurements_incremental'',0))', ''))) / length('    END IF;

    -- Migration 303: reject an unknown scope.
    IF v_scope NOT IN (''forward'', ''late_sweep'') THEN
        RAISE EXCEPTION ''ems.routing_scope must be forward or late_sweep; received %'', v_scope;
    END IF;

    SELECT pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_environment_measurements_incremental'',0))') <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: environment fragment 2 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, '        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Migration 303: forward runs read only normalized_points chunks newer
    -- than the newest compressed chunk (event_time >= its range_end), so
    -- chunk exclusion skips every compressed chunk instead of scanning its
    -- batch metadata on every run. Rows older than that floor (late data in
    -- compressed chunks) are routed by the hourly late-data sweep, which reads
    -- only event_time < floor and never passes the forward checkpoint.
    SELECT max(c.range_end) INTO v_event_min
    FROM timescaledb_information.chunks c
    WHERE c.hypertable_schema=''telemetry''
      AND c.hypertable_name=''normalized_points''
      AND c.is_compressed;
    v_event_min := COALESCE(v_event_min, ''-infinity''::timestamptz);
    v_event_max := ''infinity''::timestamptz;
    IF v_scope = ''late_sweep'' THEN
        v_event_max := v_event_min;
        v_event_min := ''-infinity''::timestamptz;
        SELECT last_received_at INTO v_forward_checkpoint
        FROM telemetry.pipeline_state WHERE pipeline_name=''environment_measurements'';
        v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, ''-infinity''::timestamptz));
        IF v_previous_checkpoint IS NOT NULL THEN
            v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
        END IF;
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
', ''))) / length('        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Migration 303: forward runs read only normalized_points chunks newer
    -- than the newest compressed chunk (event_time >= its range_end), so
    -- chunk exclusion skips every compressed chunk instead of scanning its
    -- batch metadata on every run. Rows older than that floor (late data in
    -- compressed chunks) are routed by the hourly late-data sweep, which reads
    -- only event_time < floor and never passes the forward checkpoint.
    SELECT max(c.range_end) INTO v_event_min
    FROM timescaledb_information.chunks c
    WHERE c.hypertable_schema=''telemetry''
      AND c.hypertable_name=''normalized_points''
      AND c.is_compressed;
    v_event_min := COALESCE(v_event_min, ''-infinity''::timestamptz);
    v_event_max := ''infinity''::timestamptz;
    IF v_scope = ''late_sweep'' THEN
        v_event_max := v_event_min;
        v_event_min := ''-infinity''::timestamptz;
        SELECT last_received_at INTO v_forward_checkpoint
        FROM telemetry.pipeline_state WHERE pipeline_name=''environment_measurements'';
        v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, ''-infinity''::timestamptz));
        IF v_previous_checkpoint IS NOT NULL THEN
            v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
        END IF;
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
') <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: environment fragment 3 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, '        AND np.platform_received_at <= v_window_end
        AND np.event_time >= v_event_min
        AND np.event_time < v_event_max
        AND dp.profile_code=''ENVIRONMENT_SENSOR_AIRSENSE_V1''
', ''))) / length('        AND np.platform_received_at <= v_window_end
        AND np.event_time >= v_event_min
        AND np.event_time < v_event_max
        AND dp.profile_code=''ENVIRONMENT_SENSOR_AIRSENSE_V1''
') <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: environment fragment 4 does not appear exactly once.';
    END IF;

    IF md5(replace(replace(replace(replace(v_energy,
        '      AND np.platform_received_at <= v_window_end
      AND np.event_time >= v_event_min
      AND np.event_time < v_event_max
    GROUP BY np.device_id,np.event_time
',
        '      AND np.platform_received_at <= v_window_end
    GROUP BY np.device_id,np.event_time
'),
        '    v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
  END IF;

  -- Migration 303: forward runs read only normalized_points chunks newer
  -- than the newest compressed chunk (event_time >= its range_end), so
  -- chunk exclusion skips every compressed chunk instead of scanning its
  -- batch metadata on every run. Rows older than that floor (late data in
  -- compressed chunks) are routed by the hourly late-data sweep, which reads
  -- only event_time < floor and never passes the forward checkpoint.
  SELECT max(c.range_end) INTO v_event_min
  FROM timescaledb_information.chunks c
  WHERE c.hypertable_schema=''telemetry''
    AND c.hypertable_name=''normalized_points''
    AND c.is_compressed;
  v_event_min := COALESCE(v_event_min, ''-infinity''::timestamptz);
  v_event_max := ''infinity''::timestamptz;
  IF v_scope = ''late_sweep'' THEN
    v_event_max := v_event_min;
    v_event_min := ''-infinity''::timestamptz;
    SELECT last_received_at INTO v_forward_checkpoint
    FROM telemetry.pipeline_state WHERE pipeline_name=''energy_measurements'';
    v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, ''-infinity''::timestamptz));
    IF v_previous_checkpoint IS NOT NULL THEN
      v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
    END IF;
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
',
        '    v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
'),
        '  END IF;

  -- Migration 303: reject an unknown scope.
  IF v_scope NOT IN (''forward'', ''late_sweep'') THEN
    RAISE EXCEPTION ''ems.routing_scope must be forward or late_sweep; received %'', v_scope;
  END IF;

  SELECT pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_energy_measurements_incremental'',0))',
        '  END IF;

  SELECT pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_energy_measurements_incremental'',0))'),
        '  -- Migration 303: ems.routing_scope (transaction-local; set only by
  -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
  v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting(''ems.routing_scope'', true), ''''), ''forward'');
  v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = ''late_sweep'' THEN ''energy_measurements_late_sweep'' ELSE ''energy_measurements'' END;
  v_event_min TIMESTAMPTZ;
  v_event_max TIMESTAMPTZ;
  v_forward_checkpoint TIMESTAMPTZ;
',
        '  v_pipeline_name CONSTANT TEXT := ''energy_measurements'';
')) IS DISTINCT FROM 'd271e2b8b722729b47d5991ac9504ff7' THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: energy loader changed outside the migration-303 fragments.';
    END IF;

    IF md5(replace(replace(replace(replace(v_env,
        '        AND np.platform_received_at <= v_window_end
        AND np.event_time >= v_event_min
        AND np.event_time < v_event_max
        AND dp.profile_code=''ENVIRONMENT_SENSOR_AIRSENSE_V1''
',
        '        AND np.platform_received_at <= v_window_end
        AND dp.profile_code=''ENVIRONMENT_SENSOR_AIRSENSE_V1''
'),
        '        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Migration 303: forward runs read only normalized_points chunks newer
    -- than the newest compressed chunk (event_time >= its range_end), so
    -- chunk exclusion skips every compressed chunk instead of scanning its
    -- batch metadata on every run. Rows older than that floor (late data in
    -- compressed chunks) are routed by the hourly late-data sweep, which reads
    -- only event_time < floor and never passes the forward checkpoint.
    SELECT max(c.range_end) INTO v_event_min
    FROM timescaledb_information.chunks c
    WHERE c.hypertable_schema=''telemetry''
      AND c.hypertable_name=''normalized_points''
      AND c.is_compressed;
    v_event_min := COALESCE(v_event_min, ''-infinity''::timestamptz);
    v_event_max := ''infinity''::timestamptz;
    IF v_scope = ''late_sweep'' THEN
        v_event_max := v_event_min;
        v_event_min := ''-infinity''::timestamptz;
        SELECT last_received_at INTO v_forward_checkpoint
        FROM telemetry.pipeline_state WHERE pipeline_name=''environment_measurements'';
        v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, ''-infinity''::timestamptz));
        IF v_previous_checkpoint IS NOT NULL THEN
            v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
        END IF;
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
',
        '        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
'),
        '    END IF;

    -- Migration 303: reject an unknown scope.
    IF v_scope NOT IN (''forward'', ''late_sweep'') THEN
        RAISE EXCEPTION ''ems.routing_scope must be forward or late_sweep; received %'', v_scope;
    END IF;

    SELECT pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_environment_measurements_incremental'',0))',
        '    END IF;

    SELECT pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_environment_measurements_incremental'',0))'),
        '    -- Migration 303: ems.routing_scope (transaction-local; set only by
    -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
    v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting(''ems.routing_scope'', true), ''''), ''forward'');
    v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = ''late_sweep'' THEN ''environment_measurements_late_sweep'' ELSE ''environment_measurements'' END;
    v_event_min TIMESTAMPTZ;
    v_event_max TIMESTAMPTZ;
    v_forward_checkpoint TIMESTAMPTZ;
',
        '    v_pipeline_name CONSTANT TEXT := ''environment_measurements'';
')) IS DISTINCT FROM 'd0708b46eb9ab81a6b2cc37ee0d85ef5' THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: environment loader changed outside the migration-303 fragments.';
    END IF;

    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_routing_late_sweep_job'
          AND scheduled AND fixed_schedule AND schedule_interval = INTERVAL '1 hour'
          AND max_runtime = INTERVAL '10 minutes'
          AND extract(epoch FROM initial_start)::bigint % 3600 = 31 * 60 + 30) <> 1 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: expected exactly one scheduled hourly run_routing_late_sweep_job.';
    END IF;

    IF (SELECT count(*) FROM telemetry.pipeline_state
        WHERE pipeline_name IN ('energy_measurements_late_sweep', 'environment_measurements_late_sweep')) <> 2 THEN
        RAISE EXCEPTION 'Migration 303 postcondition failed: the two late-sweep checkpoint rows are missing.';
    END IF;
END
$post$;
