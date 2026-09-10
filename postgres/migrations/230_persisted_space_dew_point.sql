-- ============================================================================
-- Migration 230
-- Phase 6 (Persisted Derived Analytics) -- the first persisted derived tier,
-- proven on the Phase 5 SELF calculation SPACE_DEW_POINT.
--
-- Source of record:
--   docs/DDS/analytics-platform-future-state-architecture.md B.2 / B.7
--     (analytics.derived_parameter_values as a persisted hypertable, "same
--     shape discipline as energy_consumption_*", registered "exactly like
--     analytics.run_energy_consumption_*_job" -- watermark-driven, bounded
--     catch-up, reconciliation-eligible; recency fingerprint = "each input's
--     newest calculated_at / received_at vs the derived row's own
--     calculated_at"; stamped with calculation_id / calculation_version).
--   docs/DDS/analytics-platform-future-state-architecture-implementation-
--     roadmap.md "Phase 6 -- Persisted Derived Analytics" (per-calculation
--     refresh_* procs + run_*_job wrappers, watermark-driven from day one;
--     reconciliation on a recency fingerprint mirroring migration 213; jobs
--     ship scheduled=false; the Phase-5 view stays as a cross-check).
--   The APPROVED Phase 6 Design Checkpoint (this session): the generic
--     analytics.derived_parameter_values table (M1); grain = ONE ROW PER
--     SENSOR PER 1-MINUTE BUCKET (PK (calculation_id, device_id,
--     bucket_start), M2 -- calculation_version stamped, not keyed); quality
--     = NULL pass-through, no lattice, no PARTIAL (E); the migration-211
--     watermark + migration-213 reconciliation patterns reused verbatim
--     (D); the refresh function READS analytics.v_space_dew_point_1min so
--     the formula lives in exactly one place (M4); compress after 7 days +
--     retain 180 days (H); internal grants only, no grafana_reader (I);
--     both jobs scheduled=false (D.4 / section 9); energy-safety
--     postconditions (J.1).
--
-- What this migration does (the entire approved Phase 6 slice):
--   1. Widens config.parameter_calculations.materialization_strategy CHECK to
--      IN ('VIEW','PERSISTED') (re-added as a named constraint) and updates
--      ONLY the one SPACE_DEW_POINT row VIEW -> PERSISTED. No other
--      calculation definition exists or is touched.
--   2. CREATE analytics.derived_parameter_values -- a generic, calculation_id-
--      keyed persisted hypertable for derived Parameter values. First slice
--      writes SPACE_DEW_POINT rows only. PK (calculation_id, device_id,
--      bucket_start) enforces the per-sensor, per-1-minute-bucket grain; two
--      AirSense sensors in one Space stay two rows, never aggregated.
--      Compression after 7 days, retention 180 days (energy_consumption_1min
--      precedent, migration 177). Internal grants only (ems_app / ems_readonly
--      SELECT); NOT granted to grafana_reader -- Phase 7 owns presentation.
--   3. telemetry.pipeline_state += one row 'derived_space_dew_point_1min'
--      (NEVER_RUN). No energy pipeline_state row is read or written.
--   4. Widens analytics.pipeline_reconciliation_log_tier_chk to additionally
--      accept 'derived_space_dew_point_1min' (additive; every existing tier
--      value stays valid; no reconciliation-log row is written here).
--   5. analytics.refresh_derived_space_dew_point_1min(p_from, p_to) RETURNS
--      bigint -- the calculation. A windowed value-aware upsert FROM
--      analytics.v_space_dew_point_1min (the Phase 5 view is the single
--      formula authority; not re-expressed here) + a windowed retract-DELETE
--      for a (device,bucket) whose source no longer qualifies.
--   6. telemetry.run_derived_space_dew_point_1min_job(job_id, config) -- the
--      forward watermark wrapper, migration-211 pattern verbatim (advisory
--      xact lock -> SKIPPED_LOCKED; RUNNING; parent availability =
--      max(telemetry.environment_measurements.bucket_start); grace from
--      config.telemetry_capture_policies; v_to = date_bin('1 minute',
--      LEAST(LEAST(now - grace, parent_available), checkpoint +
--      max_catchup_window)); v_from = checkpoint - overlap; advance
--      last_received_at = v_to as the LAST write of the single transaction;
--      EXCEPTION -> FAILED -> RAISE rolls the whole run back). Config:
--      lookback 7 days (first-run floor), max_catchup_window 6 hours,
--      overlap 1 hour.
--   7. analytics.reconcile_derived_space_dew_point_1min(job_id, config) --
--      the trailing re-drive, migration-213 pattern verbatim. SAME advisory
--      key as the forward job (they can never overlap; loser -> SKIPPED_
--      LOCKED). READS telemetry.pipeline_state.last_received_at, NEVER writes
--      it. Recency fingerprint over [checkpoint - reconcile_window,
--      checkpoint): a (device, minute) is a candidate when the Phase-5 view
--      row is newer than the persisted row (v.received_at >
--      d.source_received_at), or exists with no persisted row, or the
--      persisted row exists with no view row (source retracted). Re-drives at
--      most n_max coarse (1-hour) buckets per run via
--      analytics.refresh_derived_space_dew_point_1min, each in its own
--      BEGIN..EXCEPTION subtransaction; writes exactly one
--      analytics.pipeline_reconciliation_log row via
--      analytics.record_reconciliation_run. Config: reconcile_window 7 days,
--      coarse 1 hour, n_max 6.
--   8. Registers BOTH jobs with scheduled => FALSE. Forward job:
--      schedule_interval 5 minutes, check_config
--      config.assert_analytical_lookback_job_config, max_runtime 5 minutes,
--      max_retries 3, retry_period 5 minutes. Reconcile job:
--      schedule_interval 6 hours, check_config
--      config.assert_reconciliation_job_config, max_runtime 5 minutes,
--      max_retries 3, retry_period 15 minutes. NEITHER job is enabled by this
--      migration.
--
-- Deliberately NOT in this slice (Phase 6 later / Phase 7 / deferred):
--   RELATED / AGGREGATE_CHILDREN traversal and any metadata.asset_relationships
--   work (0 rows -- real topology not supplied); PARTIAL quality semantics; a
--   formula DSL; 15-minute / hourly derived rollups; averaging the two
--   Seasons Restaurant sensors; config.parameters.is_derived; any Grafana-
--   facing v_grafana_* / API / frontend object; any change to
--   analytics.v_pipeline_health (its 7-tier CTE is a Phase-3-era ops surface;
--   the derived tier's health is observed during bake-in directly via
--   telemetry.pipeline_state + analytics.pipeline_reconciliation_log);
--   enabling either job; any CALL of either job; any historical backfill; any
--   write to analytics.derived_parameter_values or
--   telemetry.environment_measurements; any change to
--   analytics.v_space_dew_point_1min, config.parameter_routing,
--   metadata.asset_points / space_points / asset_relationships, or any
--   AirSense binding. THE ENTIRE ENERGY SUBSYSTEM is untouched -- section 9
--   postconditions assert it (energy loader body isolation; energy routing /
--   consumption / demand / normalization jobs still scheduled; the three new
--   procs reference no energy object or refresh_continuous_aggregate;
--   config.parameter_routing still 12 active AirSense rows;
--   config.parameter_calculations still exactly one row).
--
-- Known limitation (documented, not a defect): the refresh function reads
--   analytics.v_space_dew_point_1min, which JOINs metadata.grafana_
--   organization_map and filters is_active. An organization with no active
--   map row is therefore never persisted (nor flagged by the reconcile
--   detector, which reads the same view) -- consistent behaviour, no drift.
--   The four commissioned AirSense devices' organization is Grafana-
--   provisioned. A monitoring assertion for this edge is a bake-in check,
--   not migration scope.
--
-- Rollback: postgres/maintenance/230_persisted_space_dew_point_rollback.sql
--   -- dependency-checked, no CASCADE, safe if this migration was never
--   applied. Drops both jobs, both procs + the function, restores
--   SPACE_DEW_POINT to VIEW + the narrow materialization CHECK, restores the
--   pre-230 pipeline_reconciliation_log_tier_chk, drops the retention /
--   compression policies, drops analytics.derived_parameter_values, deletes
--   the pipeline_state row. No stored derived state to reconcile
--   (truncate/drop is safe -- nothing downstream depends on it yet).
--
-- Transaction: the forward migration runner (scripts/apply_migrations.sh)
--   wraps this file in one BEGIN/COMMIT with its ledger insert; this file has
--   no BEGIN/COMMIT of its own (matches migrations 223-229). The
--   bgw_job_id_seq guard below is the first statement, before any add_job /
--   add_retention_policy / add_compression_policy (migration 213 precedent).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Sequence-resilience guard -- MUST be the first statement, before any
--    operation that can allocate a TimescaleDB background-job id
--    (add_retention_policy / add_compression_policy call add_job internally;
--    section 8 calls add_job directly). Advance _timescaledb_catalog.
--    bgw_job_id_seq to at least max(_timescaledb_config.bgw_job.id) using
--    GREATEST so a legitimately-ahead sequence is never moved backwards.
--    Idempotent; a plain no-op where the sequence is already consistent.
--    Guarded by to_regclass so a future TimescaleDB that renames/removes the
--    sequence simply skips this. (Migration 213 section 0, verbatim rationale.)
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
        RAISE NOTICE 'Migration 230: bgw_job_id_seq aligned to >= max(bgw_job.id) before add_job';
    END IF;
END
$seqfix$;


-- ----------------------------------------------------------------------------
-- 0b. Preconditions -- fail loudly if the Phase 1-5 chain this slice depends
--     on is not in place.
-- ----------------------------------------------------------------------------
DO $precheck$
BEGIN
    IF to_regclass('config.parameter_calculations') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: config.parameter_calculations is missing (Phase 5 / migration 229).';
    END IF;
    IF to_regclass('analytics.v_space_dew_point_1min') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: analytics.v_space_dew_point_1min is missing (Phase 5 / migration 229).';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM config.parameter_calculations pc
        JOIN config.parameters op ON op.id = pc.output_parameter_id
        WHERE op.code = 'DEW_POINT' AND pc.is_active AND pc.calculation_version = 1
    ) THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: the active SPACE_DEW_POINT calculation (v1) is missing.';
    END IF;
    IF to_regclass('telemetry.environment_measurements') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: telemetry.environment_measurements is missing.';
    END IF;
    IF to_regclass('telemetry.pipeline_state') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: telemetry.pipeline_state is missing.';
    END IF;
    IF to_regclass('analytics.pipeline_reconciliation_log') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: analytics.pipeline_reconciliation_log is missing (migration 213).';
    END IF;
    IF to_regprocedure('analytics.record_reconciliation_run(uuid,text,timestamptz,timestamptz,timestamptz,integer,integer,bigint,bigint,integer,text,text,text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: analytics.record_reconciliation_run is missing (migration 213).';
    END IF;
    IF to_regprocedure('config.assert_analytical_lookback_job_config(jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: config.assert_analytical_lookback_job_config is missing (migration 208/209).';
    END IF;
    IF to_regprocedure('config.assert_reconciliation_job_config(jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: config.assert_reconciliation_job_config is missing (migration 213).';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM config.telemetry_capture_policies) THEN
        RAISE EXCEPTION 'Migration 230 precondition failed: config.telemetry_capture_policies has no rows.';
    END IF;
END;
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. Materialization strategy: widen the CHECK and promote SPACE_DEW_POINT.
--    Migration 229 created the constraint inline (auto-named
--    parameter_calculations_materialization_strategy_check). Re-add it
--    explicitly named with the widened value set. Every existing value
--    ('VIEW') stays valid; only the one SPACE_DEW_POINT row is updated.
-- ----------------------------------------------------------------------------
ALTER TABLE config.parameter_calculations
    DROP CONSTRAINT IF EXISTS parameter_calculations_materialization_strategy_check;

ALTER TABLE config.parameter_calculations
    ADD CONSTRAINT parameter_calculations_materialization_strategy_check
    CHECK (materialization_strategy IN ('VIEW', 'PERSISTED'));

UPDATE config.parameter_calculations pc
SET materialization_strategy = 'PERSISTED',
    updated_at               = now()
FROM config.parameters op
WHERE op.id = pc.output_parameter_id
  AND op.code = 'DEW_POINT'
  AND pc.calculation_version = 1;


-- ----------------------------------------------------------------------------
-- 2. analytics.derived_parameter_values -- generic, calculation_id-keyed
--    persisted derived tier. Same shape discipline as
--    analytics.energy_consumption_1min (bucket_start hypertable dimension,
--    tenant columns carried directly, calculated_at value-aware upsert).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.derived_parameter_values (
    -- time / grain
    bucket_start          TIMESTAMPTZ NOT NULL,

    -- calculation identity / provenance
    calculation_id        UUID NOT NULL REFERENCES config.parameter_calculations(id),
    calculation_version   INTEGER NOT NULL,
    output_parameter_id   UUID NOT NULL REFERENCES config.parameters(id),

    -- subject (frozen closed set Asset | Space -- NOT a polymorphic Subject
    -- model) + the device-specific Point source
    subject_type          TEXT NOT NULL CHECK (subject_type IN ('ASSET', 'SPACE')),
    space_id              UUID REFERENCES metadata.spaces(id),
    asset_id              UUID REFERENCES metadata.assets(id),
    device_id             UUID NOT NULL,

    -- tenant / structural context (carried directly, like every analytics.* table)
    organization_id       UUID NOT NULL,
    site_id               UUID NOT NULL,

    -- derived value
    numeric_value         DOUBLE PRECISION,
    state_value           TEXT,

    -- quality -- NULL pass-through of the absent encoding, exactly as
    -- telemetry.environment_measurements and analytics.v_space_dew_point_1min.
    -- NO INVALID>GAP>ESTIMATED>GOOD lattice is created here.
    quality_code          SMALLINT,
    input_quality_summary  JSONB NOT NULL,

    -- recency fingerprint + timestamps
    source_received_at     TIMESTAMPTZ NOT NULL,
    source_timestamp       TIMESTAMPTZ,
    calculated_at          TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT pk_derived_parameter_values
        PRIMARY KEY (calculation_id, device_id, bucket_start),
    CONSTRAINT ck_derived_parameter_values_subject_binding
        CHECK (
            (subject_type = 'SPACE' AND space_id IS NOT NULL AND asset_id IS NULL)
            OR (subject_type = 'ASSET' AND asset_id IS NOT NULL AND space_id IS NULL)
        ),
    CONSTRAINT ck_derived_parameter_values_value_present
        CHECK (numeric_value IS NOT NULL OR state_value IS NOT NULL)
);

COMMENT ON TABLE analytics.derived_parameter_values IS
'Phase 6 (migration 230): persisted derived Parameter values, one row per (calculation_id, device-specific Point, 1-minute bucket). First tier: SPACE_DEW_POINT (SELF, Space subject), computed from analytics.v_space_dew_point_1min. Grain is per-sensor -- two sensors in one Space are two rows, never aggregated. quality_code is NULL pass-through (no lattice). source_received_at is the recency fingerprint (= the source environment_measurements bucket''s received_at at derivation time). Tenant columns carried directly; NOT granted to grafana_reader -- Phase 7 owns the v_grafana_* presentation view.';
COMMENT ON COLUMN analytics.derived_parameter_values.calculation_version IS
'Stamped from config.parameter_calculations at derivation time (NOT part of the natural key -- a version bump overwrites in place and re-stamps).';
COMMENT ON COLUMN analytics.derived_parameter_values.source_received_at IS
'The source environment_measurements bucket''s received_at as of the last derivation. The reconcile detector re-drives a (device,bucket) when the Phase 5 view''s received_at exceeds this (a source correction landed).';
COMMENT ON COLUMN analytics.derived_parameter_values.input_quality_summary IS
'Structural record of the required-input contract. For a persisted SPACE_DEW_POINT row both inputs are present by construction (the view emits no row otherwise); carried to keep the shape forward-compatible with phases that have real input quality.';

SELECT create_hypertable(
    'analytics.derived_parameter_values',
    'bucket_start',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists       => TRUE
);

CREATE INDEX IF NOT EXISTS ix_derived_parameter_values_space_time
    ON analytics.derived_parameter_values (space_id, bucket_start DESC);
CREATE INDEX IF NOT EXISTS ix_derived_parameter_values_org_calc_time
    ON analytics.derived_parameter_values (organization_id, calculation_id, bucket_start DESC);
CREATE INDEX IF NOT EXISTS ix_derived_parameter_values_device_time
    ON analytics.derived_parameter_values (device_id, bucket_start DESC);

ALTER TABLE analytics.derived_parameter_values SET (
    timescaledb.compress           = TRUE,
    timescaledb.compress_segmentby  = 'calculation_id,organization_id,device_id',
    timescaledb.compress_orderby    = 'bucket_start DESC'
);

SELECT add_compression_policy('analytics.derived_parameter_values', INTERVAL '7 days',   if_not_exists => TRUE);
SELECT add_retention_policy  ('analytics.derived_parameter_values', INTERVAL '180 days', if_not_exists => TRUE);

ALTER TABLE analytics.derived_parameter_values OWNER TO ems_admin;
REVOKE ALL ON analytics.derived_parameter_values FROM PUBLIC;
GRANT SELECT ON analytics.derived_parameter_values TO ems_app, ems_readonly;


-- ----------------------------------------------------------------------------
-- 3. pipeline_state row for the new forward tier. Additive; no energy row is
--    read or written. last_received_at stays NULL until the first successful
--    watermark-driven run.
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name)
VALUES ('derived_space_dew_point_1min')
ON CONFLICT (pipeline_name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 4. Widen analytics.pipeline_reconciliation_log_tier_chk to accept the new
--    tier. Additive: every existing tier value stays valid. No
--    reconciliation-log row is written by this migration.
-- ----------------------------------------------------------------------------
ALTER TABLE analytics.pipeline_reconciliation_log
    DROP CONSTRAINT IF EXISTS pipeline_reconciliation_log_tier_chk;

ALTER TABLE analytics.pipeline_reconciliation_log
    ADD CONSTRAINT pipeline_reconciliation_log_tier_chk CHECK (tier IN (
        'energy_consumption_1min', 'energy_consumption_5min', 'energy_consumption_15min',
        'energy_consumption_hourly', 'energy_consumption_daily', 'demand_intervals',
        'environment_daily',
        'derived_space_dew_point_1min'));


-- ----------------------------------------------------------------------------
-- 5. analytics.refresh_derived_space_dew_point_1min(p_from, p_to) -- the
--    calculation. Windowed value-aware upsert FROM the Phase 5 view (the
--    single formula authority -- Magnus/Arden-Buck is not re-expressed here)
--    + windowed retract-DELETE for a (device,bucket) whose source no longer
--    qualifies. RETURNS the count of rows upserted + deleted.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.refresh_derived_space_dew_point_1min(
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'analytics', 'config'
AS $function$
DECLARE
    v_calc_id      UUID;
    v_calc_ver     INTEGER;
    v_out_param_id UUID;
    v_upserted     BIGINT := 0;
    v_deleted      BIGINT := 0;
BEGIN
    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RETURN 0;
    END IF;

    SELECT pc.id, pc.calculation_version, pc.output_parameter_id
      INTO v_calc_id, v_calc_ver, v_out_param_id
    FROM config.parameter_calculations pc
    JOIN config.parameters op ON op.id = pc.output_parameter_id
    WHERE op.code = 'DEW_POINT' AND pc.is_active AND pc.calculation_version = 1;

    IF v_calc_id IS NULL THEN
        RAISE EXCEPTION 'refresh_derived_space_dew_point_1min: no active SPACE_DEW_POINT calculation (v1).';
    END IF;

    -- (a) value-aware upsert from the Phase 5 view over [p_from, p_to).
    INSERT INTO analytics.derived_parameter_values AS d (
        bucket_start, calculation_id, calculation_version, output_parameter_id,
        subject_type, space_id, asset_id, device_id,
        organization_id, site_id,
        numeric_value, state_value,
        quality_code, input_quality_summary,
        source_received_at, source_timestamp, calculated_at
    )
    SELECT
        v.bucket_start, v_calc_id, v_calc_ver, v_out_param_id,
        'SPACE', v.space_id, NULL::UUID, v.device_id,
        v.organization_id, v.site_id,
        v.dew_point_c, NULL::TEXT,
        v.quality_code,
        jsonb_build_object(
            'null_handling', 'NULL_IF_REQUIRED_MISSING',
            'inputs', jsonb_build_object(
                'TEMPERATURE', jsonb_build_object('present', TRUE),
                'HUMIDITY',    jsonb_build_object('present', TRUE)),
            'source', jsonb_build_object(
                'received_at',      v.received_at,
                'source_timestamp', v.source_timestamp)
        ),
        v.received_at, v.source_timestamp, clock_timestamp()
    FROM analytics.v_space_dew_point_1min v
    WHERE v.bucket_start >= p_from
      AND v.bucket_start <  p_to
      AND v.dew_point_c IS NOT NULL          -- degenerate denominator-zero -> no derived value
    ON CONFLICT (calculation_id, device_id, bucket_start) DO UPDATE
    SET calculation_version   = EXCLUDED.calculation_version,
        output_parameter_id   = EXCLUDED.output_parameter_id,
        subject_type          = EXCLUDED.subject_type,
        space_id              = EXCLUDED.space_id,
        asset_id              = EXCLUDED.asset_id,
        organization_id       = EXCLUDED.organization_id,
        site_id               = EXCLUDED.site_id,
        numeric_value         = EXCLUDED.numeric_value,
        state_value           = EXCLUDED.state_value,
        quality_code          = EXCLUDED.quality_code,
        input_quality_summary = EXCLUDED.input_quality_summary,
        source_received_at    = EXCLUDED.source_received_at,
        source_timestamp      = EXCLUDED.source_timestamp,
        calculated_at         = clock_timestamp()
    WHERE d.source_received_at   IS DISTINCT FROM EXCLUDED.source_received_at
       OR d.numeric_value        IS DISTINCT FROM EXCLUDED.numeric_value
       OR d.space_id             IS DISTINCT FROM EXCLUDED.space_id
       OR d.calculation_version  IS DISTINCT FROM EXCLUDED.calculation_version;
    GET DIAGNOSTICS v_upserted = ROW_COUNT;

    -- (b) windowed retract: a previously persisted (device,bucket) whose
    --     source no longer produces a Phase-5 view row (humidity corrected to
    --     NULL / <= 0, temperature cleared, space_id unbound, org map
    --     deactivated). Bounded to [p_from, p_to).
    DELETE FROM analytics.derived_parameter_values d
    WHERE d.calculation_id = v_calc_id
      AND d.bucket_start >= p_from
      AND d.bucket_start <  p_to
      AND NOT EXISTS (
          SELECT 1 FROM analytics.v_space_dew_point_1min v
          WHERE v.calculation_id = d.calculation_id
            AND v.device_id      = d.device_id
            AND v.bucket_start   = d.bucket_start
            AND v.dew_point_c IS NOT NULL
      );
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RETURN v_upserted + v_deleted;
END;
$function$;

ALTER FUNCTION analytics.refresh_derived_space_dew_point_1min(timestamptz, timestamptz) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.refresh_derived_space_dew_point_1min(timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.refresh_derived_space_dew_point_1min(timestamptz, timestamptz) TO ems_admin;

COMMENT ON FUNCTION analytics.refresh_derived_space_dew_point_1min(timestamptz, timestamptz) IS
'Phase 6 (migration 230): recomputes analytics.derived_parameter_values for SPACE_DEW_POINT over [p_from, p_to). Reads analytics.v_space_dew_point_1min (the single formula authority -- Magnus/Arden-Buck is NOT re-expressed here); value-aware upsert (calculated_at only moves when source_received_at / numeric_value / space_id / calculation_version changes) + a windowed retract-DELETE for a (device,bucket) whose source no longer qualifies. Called by telemetry.run_derived_space_dew_point_1min_job and analytics.reconcile_derived_space_dew_point_1min; never writes telemetry.pipeline_state.';


-- ----------------------------------------------------------------------------
-- 6. telemetry.run_derived_space_dew_point_1min_job -- bounded watermark-
--    driven forward wrapper. Migration-211 (run_environment_daily_job)
--    pattern: advisory xact lock -> SKIPPED_LOCKED; RUNNING; grace from
--    config.telemetry_capture_policies; parent availability =
--    max(telemetry.environment_measurements.bucket_start); one transaction,
--    checkpoint advance is the LAST write; EXCEPTION -> FAILED -> RAISE.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.run_derived_space_dew_point_1min_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'telemetry', 'analytics', 'config'
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'derived_space_dew_point_1min';
    v_lookback      INTERVAL := INTERVAL '7 days';    -- FIRST-RUN FLOOR only
    v_max_catchup   INTERVAL := INTERVAL '6 hours';
    v_overlap       INTERVAL := INTERVAL '1 hour';
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
        RAISE EXCEPTION 'derived_space_dew_point_1min config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)',
            v_lookback, v_max_catchup, v_overlap;
    END IF;

    -- Self-overlap guard (migration 208/211 idiom).
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('telemetry.run_derived_space_dew_point_1min_job', 0)
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

    -- Finalizability grace: identical construction to migration 211
    -- (run_environment_daily_job). A 1-minute environment bucket may only be
    -- read once every one of its capture-bucket correction deadlines has
    -- passed. Derived from config.telemetry_capture_policies (NOT
    -- config.site_demand_policies).
    v_grace := make_interval(secs =>
          COALESCE((SELECT max(late_arrival_tolerance_seconds)
                    FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + COALESCE((SELECT max(capture_interval_seconds)
                    FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + 300);

    -- Parent availability = the actual newest closed environment source bucket
    -- (a real persisted timestamp; cannot run ahead of real data). NOT a
    -- ca_environment_* materialization watermark; NOT
    -- telemetry.pipeline_state('environment_measurements') (that routing
    -- checkpoint is keyed on platform_received_at = ingest time).
    SELECT max(bucket_start) INTO v_avail FROM telemetry.environment_measurements;

    v_start := COALESCE(v_ckpt, clock_timestamp() - v_lookback);

    -- Finalizable frontier: past grace AND backed by real source data,
    -- bounded by one catch-up slice, floored to a UTC minute boundary
    -- (date_bin origin at UTC midnight -> deterministic regardless of session
    -- TimeZone) so the checkpoint is always a clean minute mark.
    v_to := date_bin(
              INTERVAL '1 minute',
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

    v_rows := analytics.refresh_derived_space_dew_point_1min(v_from, v_to);

    -- The checkpoint advance is the LAST write of the run's single transaction.
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

ALTER PROCEDURE telemetry.run_derived_space_dew_point_1min_job(integer, jsonb) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE telemetry.run_derived_space_dew_point_1min_job(integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE telemetry.run_derived_space_dew_point_1min_job(integer, jsonb) TO ems_admin;

COMMENT ON PROCEDURE telemetry.run_derived_space_dew_point_1min_job(integer, jsonb) IS
'Phase 6 (migration 230): watermark-driven forward job for analytics.derived_parameter_values (SPACE_DEW_POINT tier). Migration-211 pattern: reads telemetry.pipeline_state(''derived_space_dew_point_1min'').last_received_at FOR UPDATE, parent availability = max(telemetry.environment_measurements.bucket_start), grace = max(late_arrival_tolerance_seconds)+max(capture_interval_seconds)+300 over enabled config.telemetry_capture_policies, CALLs analytics.refresh_derived_space_dew_point_1min(v_from, v_to) with v_to = date_bin(''1 minute'', LEAST(LEAST(now - grace, parent_available), checkpoint + max_catchup_window)) and v_from = checkpoint - overlap. Advances last_received_at = v_to ONLY as the last write of the successful single transaction; any failure / cancel / timeout rolls the whole run back. lookback (7 days) is the first-run floor only. Advisory lock -> SKIPPED_LOCKED. Registered scheduled=false by migration 230; config check_config = config.assert_analytical_lookback_job_config.';


-- ----------------------------------------------------------------------------
-- 7. analytics.reconcile_derived_space_dew_point_1min -- bounded trailing
--    re-drive. Migration-213 (reconcile_environment_daily) pattern: SAME
--    advisory key as the forward job; READS pipeline_state, NEVER writes it;
--    inline recency-fingerprint detector; re-drives <= n_max coarse buckets
--    per run via analytics.refresh_derived_space_dew_point_1min, each in its
--    own BEGIN..EXCEPTION subtransaction; writes exactly one
--    analytics.pipeline_reconciliation_log row.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.reconcile_derived_space_dew_point_1min(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT TEXT := 'derived_space_dew_point_1min';
    v_fwd_lock  CONSTANT TEXT := 'telemetry.run_derived_space_dew_point_1min_job';
    v_rw        INTERVAL := INTERVAL '7 days';
    v_coarse    INTERVAL := INTERVAL '1 hour';
    v_nmax      INTEGER  := 6;
    v_run       UUID := gen_random_uuid();
    v_started   TIMESTAMPTZ := clock_timestamp();
    v_cp        TIMESTAMPTZ;
    v_ws        TIMESTAMPTZ;
    v_examined  INTEGER := 0;
    v_mismatch  INTEGER := 0;
    v_repaired  BIGINT  := 0;
    v_errs      INTEGER := 0;
    v_sqlstate  TEXT;
    v_errmsg    TEXT;
    v_outcome   TEXT;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw     := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'coarse'           THEN v_coarse := (config ->> 'coarse')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax   := (config ->> 'n_max')::INTEGER; END IF;

    -- Same transaction-scoped advisory key as the forward job: a reconcile and
    -- its forward job can never run concurrently; the loser records
    -- SKIPPED_LOCKED and returns.
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

    -- Recency-fingerprint detector over [v_ws, v_cp): the oldest n_max+1
    -- coarse buckets that contain at least one (device, minute) where the
    -- Phase-5 view and the persisted row disagree.
    FOR r IN
        WITH cur AS (
            SELECT v.device_id, v.bucket_start, v.received_at
            FROM analytics.v_space_dew_point_1min v
            WHERE v.bucket_start >= v_ws AND v.bucket_start < v_cp
              AND v.dew_point_c IS NOT NULL
        ),
        persisted AS (
            SELECT d.device_id, d.bucket_start, d.source_received_at
            FROM analytics.derived_parameter_values d
            JOIN config.parameter_calculations pc ON pc.id = d.calculation_id
            JOIN config.parameters op ON op.id = pc.output_parameter_id
            WHERE op.code = 'DEW_POINT'
              AND d.bucket_start >= v_ws AND d.bucket_start < v_cp
        ),
        mism AS (
            SELECT COALESCE(c.bucket_start, p.bucket_start) AS bucket_start
            FROM cur c
            FULL JOIN persisted p
              ON p.device_id = c.device_id AND p.bucket_start = c.bucket_start
            WHERE p.device_id IS NULL                            -- empty-then-filled
               OR c.device_id IS NULL                            -- source retracted
               OR c.received_at > p.source_received_at           -- source corrected
        )
        SELECT date_bin(v_coarse, m.bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS coarse_bucket_start,
               count(*)::bigint AS mism_rows
        FROM mism m
        GROUP BY 1
        ORDER BY 1
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
                + analytics.refresh_derived_space_dew_point_1min(
                    r.coarse_bucket_start, r.coarse_bucket_start + v_coarse);
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

ALTER PROCEDURE analytics.reconcile_derived_space_dew_point_1min(integer, jsonb) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.reconcile_derived_space_dew_point_1min(integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_derived_space_dew_point_1min(integer, jsonb) TO ems_admin;

COMMENT ON PROCEDURE analytics.reconcile_derived_space_dew_point_1min(integer, jsonb) IS
'Phase 6 (migration 230): bounded trailing reconciliation for analytics.derived_parameter_values (SPACE_DEW_POINT tier). Takes hashtextextended(''telemetry.run_derived_space_dew_point_1min_job'',0) as a transaction-scoped advisory lock (SKIPPED_LOCKED on contention). Detector over [checkpoint - reconcile_window, checkpoint): a (device, minute) where the Phase-5 view row is newer than the persisted row (received_at > source_received_at), or exists with no persisted row, or the persisted row exists with no view row. Repair: analytics.refresh_derived_space_dew_point_1min over each mismatching coarse (1-hour) bucket, up to n_max (ships 6), each in its own subtransaction. NEVER writes telemetry.pipeline_state.last_received_at. Writes exactly one analytics.pipeline_reconciliation_log row. reconcile_window default 7 days. Registered scheduled=false by migration 230; check_config = config.assert_reconciliation_job_config.';


-- ----------------------------------------------------------------------------
-- 8. Register BOTH jobs with scheduled => FALSE. Neither is enabled here.
--    Job ids are assigned by add_job at apply time and looked up by
--    (proc_schema, proc_name) everywhere else.
-- ----------------------------------------------------------------------------
DO $jobs$
DECLARE
    v_anchor   TIMESTAMPTZ := date_trunc('hour', now()) + INTERVAL '1 hour';
    v_job_id   INTEGER;
BEGIN
    -- Forward job.
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_derived_space_dew_point_1min_job'
    ) THEN
        PERFORM add_job(
            'telemetry.run_derived_space_dew_point_1min_job'::regproc,
            schedule_interval => INTERVAL '5 minutes',
            initial_start     => v_anchor + INTERVAL '2 minutes',
            config            => jsonb_build_object(
                                     'lookback',           '7 days',
                                     'max_catchup_window', '6 hours',
                                     'overlap',            '1 hour'),
            check_config      => 'config.assert_analytical_lookback_job_config'::regproc,
            scheduled         => FALSE,
            fixed_schedule    => TRUE
        );
        RAISE NOTICE 'Migration 230: registered telemetry.run_derived_space_dew_point_1min_job (scheduled=false)';
    ELSE
        RAISE NOTICE 'Migration 230: telemetry.run_derived_space_dew_point_1min_job already registered, left as-is';
    END IF;

    FOR v_job_id IN
        SELECT job_id FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_derived_space_dew_point_1min_job'
    LOOP
        PERFORM alter_job(
            v_job_id,
            max_runtime  => INTERVAL '5 minutes',
            max_retries  => 3,
            retry_period => INTERVAL '5 minutes'
        );
    END LOOP;

    -- Reconcile job.
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_derived_space_dew_point_1min'
    ) THEN
        PERFORM add_job(
            'analytics.reconcile_derived_space_dew_point_1min'::regproc,
            schedule_interval => INTERVAL '6 hours',
            initial_start     => v_anchor + INTERVAL '38 minutes',
            config            => jsonb_build_object(
                                     'reconcile_window', '7 days',
                                     'coarse',           '1 hour',
                                     'n_max',            6),
            check_config      => 'config.assert_reconciliation_job_config'::regproc,
            scheduled         => FALSE,
            fixed_schedule    => TRUE
        );
        RAISE NOTICE 'Migration 230: registered analytics.reconcile_derived_space_dew_point_1min (scheduled=false)';
    ELSE
        RAISE NOTICE 'Migration 230: analytics.reconcile_derived_space_dew_point_1min already registered, left as-is';
    END IF;

    FOR v_job_id IN
        SELECT job_id FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_derived_space_dew_point_1min'
    LOOP
        PERFORM alter_job(
            v_job_id,
            max_runtime  => INTERVAL '5 minutes',
            max_retries  => 3,
            retry_period => INTERVAL '15 minutes'
        );
    END LOOP;
END
$jobs$;


-- ----------------------------------------------------------------------------
-- 9. Postconditions -- fail the transaction loudly on any drift, per the
--    198/199/223/224/225/226/227/228/229 discipline. Includes the approved
--    Design Checkpoint J.1 energy-safety tripwires.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_n    INTEGER;
    v_txt  TEXT;
    v_prc  TEXT;
    r      RECORD;
BEGIN
    -- ---- (A) target table shape --------------------------------------------
    IF to_regclass('analytics.derived_parameter_values') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: analytics.derived_parameter_values was not created.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'derived_parameter_values'
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: analytics.derived_parameter_values is not a hypertable.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'analytics.derived_parameter_values'::regclass
          AND conname = 'pk_derived_parameter_values' AND contype = 'p'
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: pk_derived_parameter_values missing.';
    END IF;
    -- PK columns are exactly (calculation_id, device_id, bucket_start)
    SELECT string_agg(a.attname, ',' ORDER BY k.ord) INTO v_txt
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.conrelid = 'analytics.derived_parameter_values'::regclass
      AND c.conname = 'pk_derived_parameter_values';
    IF v_txt IS DISTINCT FROM 'calculation_id,device_id,bucket_start' THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: PK columns are "%", expected "calculation_id,device_id,bucket_start".', v_txt;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'analytics.derived_parameter_values'::regclass AND conname = 'ck_derived_parameter_values_subject_binding') THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: ck_derived_parameter_values_subject_binding missing.';
    END IF;
    FOR v_txt IN SELECT unnest(ARRAY[
            'ix_derived_parameter_values_space_time',
            'ix_derived_parameter_values_org_calc_time',
            'ix_derived_parameter_values_device_time'])
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'analytics' AND indexname = v_txt) THEN
            RAISE EXCEPTION 'Migration 230 postcondition failed: index % missing.', v_txt;
        END IF;
    END LOOP;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_retention' AND hypertable_name = 'derived_parameter_values'
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: retention policy on derived_parameter_values missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_compression' AND hypertable_name = 'derived_parameter_values'
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: compression policy on derived_parameter_values missing.';
    END IF;
    -- internal grants only; NOT grafana_reader
    IF NOT has_table_privilege('ems_app', 'analytics.derived_parameter_values', 'SELECT')
       OR NOT has_table_privilege('ems_readonly', 'analytics.derived_parameter_values', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: ems_app / ems_readonly cannot SELECT derived_parameter_values.';
    END IF;
    IF has_table_privilege('grafana_reader', 'analytics.derived_parameter_values', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: grafana_reader can SELECT derived_parameter_values (must be internal until Phase 7).';
    END IF;
    IF has_table_privilege('public', 'analytics.derived_parameter_values', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: PUBLIC can SELECT derived_parameter_values.';
    END IF;
    -- migration writes NO rows
    IF (SELECT count(*) FROM analytics.derived_parameter_values) <> 0 THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: derived_parameter_values is not empty (% rows) -- no backfill is permitted.',
            (SELECT count(*) FROM analytics.derived_parameter_values);
    END IF;

    -- ---- (B) materialization strategy ------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'config.parameter_calculations'::regclass
          AND conname = 'parameter_calculations_materialization_strategy_check'
          AND pg_get_constraintdef(oid) ILIKE '%''VIEW''%' AND pg_get_constraintdef(oid) ILIKE '%''PERSISTED''%'
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: materialization_strategy CHECK not widened to VIEW/PERSISTED.';
    END IF;
    IF (SELECT count(*) FROM config.parameter_calculations) <> 1 THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: config.parameter_calculations must still hold exactly one row, found %.',
            (SELECT count(*) FROM config.parameter_calculations);
    END IF;
    SELECT pc.materialization_strategy, pc.applicable_subject_type INTO v_txt, v_prc
    FROM config.parameter_calculations pc
    JOIN config.parameters op ON op.id = pc.output_parameter_id
    WHERE op.code = 'DEW_POINT' AND pc.calculation_version = 1;
    IF v_txt <> 'PERSISTED' THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: SPACE_DEW_POINT materialization_strategy is "%", expected PERSISTED.', v_txt;
    END IF;
    IF v_prc <> 'SPACE' THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: SPACE_DEW_POINT applicable_subject_type changed to "%".', v_prc;
    END IF;

    -- ---- (C) pipeline_state + reconciliation-log tier -------------------
    IF NOT EXISTS (SELECT 1 FROM telemetry.pipeline_state WHERE pipeline_name = 'derived_space_dew_point_1min') THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: pipeline_state row derived_space_dew_point_1min missing.';
    END IF;
    IF (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'derived_space_dew_point_1min') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: derived_space_dew_point_1min checkpoint is not NULL (no run is permitted).';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'analytics.pipeline_reconciliation_log'::regclass
          AND conname = 'pipeline_reconciliation_log_tier_chk'
          AND pg_get_constraintdef(oid) LIKE '%derived_space_dew_point_1min%'
          AND pg_get_constraintdef(oid) LIKE '%environment_daily%'
          AND pg_get_constraintdef(oid) LIKE '%energy_consumption_1min%'
          AND pg_get_constraintdef(oid) LIKE '%demand_intervals%'
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: pipeline_reconciliation_log_tier_chk not widened correctly (existing tiers must be preserved).';
    END IF;
    IF (SELECT count(*) FROM analytics.pipeline_reconciliation_log WHERE tier = 'derived_space_dew_point_1min') <> 0 THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: a reconciliation-log row for the new tier was written.';
    END IF;

    -- ---- (D) new procedures / function exist with the intended signatures --
    IF to_regprocedure('analytics.refresh_derived_space_dew_point_1min(timestamptz,timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: analytics.refresh_derived_space_dew_point_1min missing.';
    END IF;
    IF to_regprocedure('telemetry.run_derived_space_dew_point_1min_job(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: telemetry.run_derived_space_dew_point_1min_job missing.';
    END IF;
    IF to_regprocedure('analytics.reconcile_derived_space_dew_point_1min(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: analytics.reconcile_derived_space_dew_point_1min missing.';
    END IF;

    -- ---- (E) both jobs registered, BOTH scheduled = false --------------
    SELECT count(*) INTO v_n FROM timescaledb_information.jobs
    WHERE (proc_schema, proc_name) IN
        (('telemetry','run_derived_space_dew_point_1min_job'),
         ('analytics','reconcile_derived_space_dew_point_1min'));
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: expected 2 Phase-6 jobs, found %.', v_n;
    END IF;
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE (proc_schema, proc_name) IN
            (('telemetry','run_derived_space_dew_point_1min_job'),
             ('analytics','reconcile_derived_space_dew_point_1min'))
          AND scheduled
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: a Phase-6 job is scheduled=true (both MUST remain disabled).';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name = 'run_derived_space_dew_point_1min_job'
          AND schedule_interval = INTERVAL '5 minutes'
          AND max_runtime = INTERVAL '5 minutes'
          AND config = jsonb_build_object('lookback','7 days','max_catchup_window','6 hours','overlap','1 hour')
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: forward job schedule/runtime/config not as approved.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name = 'reconcile_derived_space_dew_point_1min'
          AND schedule_interval = INTERVAL '6 hours'
          AND max_runtime = INTERVAL '5 minutes'
          AND config = jsonb_build_object('reconcile_window','7 days','coarse','1 hour','n_max',6)
    ) THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: reconcile job schedule/runtime/config not as approved.';
    END IF;

    -- ---- (F) new-procedure isolation: no energy object, no CAGG refresh ---
    FOR v_prc IN SELECT unnest(ARRAY[
            'analytics.refresh_derived_space_dew_point_1min(timestamptz,timestamptz)',
            'telemetry.run_derived_space_dew_point_1min_job(integer,jsonb)',
            'analytics.reconcile_derived_space_dew_point_1min(integer,jsonb)'])
    LOOP
        v_txt := lower(pg_get_functiondef(v_prc::regprocedure));
        -- 'demand_' is deliberately NOT a token here: the forward wrapper's
        -- comment legitimately names config.site_demand_policies to say it is
        -- NOT used (migration 211 idiom). Match real demand objects instead.
        IF position('energy_measurements' IN v_txt) <> 0
           OR position('ca_energy' IN v_txt) <> 0
           OR position('energy_consumption' IN v_txt) <> 0
           OR position('demand_intervals' IN v_txt) <> 0
           OR position('demand_state' IN v_txt) <> 0
           OR position('refresh_demand' IN v_txt) <> 0
           OR position('run_demand' IN v_txt) <> 0
           OR position('load_energy' IN v_txt) <> 0
           OR position('run_energy' IN v_txt) <> 0
           OR position('refresh_continuous_aggregate' IN v_txt) <> 0
           OR position('parameter_routing' IN v_txt) <> 0 THEN
            RAISE EXCEPTION 'Migration 230 postcondition failed: % references an energy/routing/CAGG object.', v_prc;
        END IF;
        IF position('environment_measurements' IN v_txt) = 0
           AND position('v_space_dew_point_1min' IN v_txt) = 0 THEN
            RAISE EXCEPTION 'Migration 230 postcondition failed: % reads neither environment_measurements nor v_space_dew_point_1min.', v_prc;
        END IF;
    END LOOP;

    -- ---- (G) ENERGY SAFETY: energy loader body untouched -----------------
    v_txt := lower(pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure));
    IF position('derived_parameter_values' IN v_txt) <> 0
       OR position('parameter_calculations' IN v_txt) <> 0
       OR position('v_space_dew_point_1min' IN v_txt) <> 0
       OR position('refresh_derived' IN v_txt) <> 0
       OR position('dew_point' IN v_txt) <> 0
       OR position('space_id' IN v_txt) <> 0
       OR position('space_points' IN v_txt) <> 0
       OR position('device_point_configuration' IN v_txt) <> 0 THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: the energy loader body references a Phase 2/3/5/6 object -- energy was touched.';
    END IF;
    IF position('telemetry.energy_measurements' IN v_txt) = 0 THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: the energy loader no longer targets telemetry.energy_measurements.';
    END IF;

    -- ---- (H) ENERGY SAFETY: energy / demand / normalization jobs intact --
    IF to_regprocedure('telemetry.run_energy_routing_job(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: telemetry.run_energy_routing_job is missing.';
    END IF;
    IF to_regprocedure('telemetry.run_environment_routing_job(integer,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: telemetry.run_environment_routing_job is missing.';
    END IF;
    FOR v_prc IN SELECT unnest(ARRAY[
            'run_energy_routing_job', 'run_environment_routing_job',
            'run_energy_consumption_1min_job', 'run_energy_consumption_5min_job',
            'run_energy_consumption_15min_job', 'run_energy_consumption_hourly_job',
            'run_energy_consumption_daily_job', 'run_environment_daily_job'])
    LOOP
        IF EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = v_prc)
           AND NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = v_prc AND scheduled) THEN
            RAISE EXCEPTION 'Migration 230 postcondition failed: job % is no longer scheduled -- an energy/environment schedule was changed.', v_prc;
        END IF;
    END LOOP;
    -- energy consumption refresh functions still present
    FOR v_prc IN SELECT unnest(ARRAY[
            'analytics.refresh_energy_consumption_1min(timestamptz,timestamptz)',
            'analytics.refresh_energy_consumption_5min(timestamptz,timestamptz)',
            'analytics.refresh_energy_consumption_15min(timestamptz,timestamptz)',
            'analytics.refresh_energy_consumption_hourly(timestamptz,timestamptz)',
            'analytics.refresh_energy_consumption_daily(timestamptz,timestamptz)'])
    LOOP
        IF to_regprocedure(v_prc) IS NULL THEN
            RAISE EXCEPTION 'Migration 230 postcondition failed: % is missing -- energy calculation was touched.', v_prc;
        END IF;
    END LOOP;

    -- ---- (I) ENERGY SAFETY: energy pipeline_state rows still present ----
    FOR v_txt IN SELECT unnest(ARRAY[
            'normalized_points', 'energy_measurements', 'environment_measurements',
            'energy_consumption_1min', 'energy_consumption_5min', 'energy_consumption_15min',
            'energy_consumption_hourly', 'energy_consumption_daily', 'demand_intervals'])
    LOOP
        IF NOT EXISTS (SELECT 1 FROM telemetry.pipeline_state WHERE pipeline_name = v_txt) THEN
            RAISE EXCEPTION 'Migration 230 postcondition failed: pipeline_state row % is missing -- the watermark model was disturbed.', v_txt;
        END IF;
    END LOOP;

    -- ---- (J) ENERGY / ROUTING SAFETY: config.parameter_routing intact ---
    IF (SELECT count(*) FROM config.parameter_routing WHERE is_active AND destination_table = 'telemetry.environment_measurements') <> 12 THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: config.parameter_routing active AirSense rows != 12.';
    END IF;

    -- ---- (K) the Phase 5 view is unchanged and still the cross-check -----
    IF to_regclass('analytics.v_space_dew_point_1min') IS NULL THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: analytics.v_space_dew_point_1min was dropped.';
    END IF;
    v_txt := pg_get_viewdef('analytics.v_space_dew_point_1min'::regclass, true);
    IF position('telemetry.environment_measurements' IN v_txt) = 0
       OR position('space_id IS NOT NULL' IN v_txt) = 0
       OR position('humidity_percent > 0' IN v_txt) = 0
       OR position('derived_parameter_values' IN v_txt) <> 0 THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: analytics.v_space_dew_point_1min was modified.';
    END IF;
    IF NOT has_table_privilege('grafana_reader', 'analytics.v_space_dew_point_1min', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 230 postcondition failed: the Phase 5 view lost its grafana_reader grant.';
    END IF;

    RAISE NOTICE 'Migration 230: all postconditions passed (persisted SPACE_DEW_POINT tier created; both jobs scheduled=false; energy untouched).';
END;
$post$;
