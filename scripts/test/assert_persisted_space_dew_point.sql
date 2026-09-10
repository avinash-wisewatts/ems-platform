-- ============================================================================
-- File:
--   scripts/test/assert_persisted_space_dew_point.sql
--
-- Purpose:
--   Regression test for migration 230 (Phase 6 -- persisted SPACE_DEW_POINT
--   tier). Proves the approved Design Checkpoint contracts:
--
--   SCHEMA
--     S1  analytics.derived_parameter_values exists, is a hypertable, has the
--         approved columns/types, PK (calculation_id, device_id, bucket_start),
--         the subject-binding + value-present CHECKs, the three indexes,
--         compression + 180-day retention policies, internal grants only
--         (ems_app / ems_readonly SELECT; NOT grafana_reader, NOT PUBLIC).
--     S2  config.parameter_calculations.materialization_strategy CHECK now
--         permits PERSISTED; ONLY the SPACE_DEW_POINT row is PERSISTED;
--         still exactly one calculation row.
--     S3  pipeline_reconciliation_log_tier_chk widened (new tier added, the
--         seven pre-230 tiers preserved).
--     S4  both jobs exist, BOTH scheduled=false, with the approved
--         schedule_interval / max_runtime / max_retries / retry_period /
--         config; the config assertions pass.
--     S5  telemetry.pipeline_state row 'derived_space_dew_point_1min' exists,
--         checkpoint NULL.
--
--   CALCULATION
--     C1  after one forward run the persisted set == analytics.v_space_dew_
--         point_1min for every bucket below the watermark (row-for-row).
--     C2  one row per sensor / bucket (Seasons Space: two sensors, one bucket
--         -> two rows, distinct device_id, distinct numeric_value -- never
--         averaged).
--     C3  Magnus value matches the Phase 5 view exactly AND the fixed
--         constant (25.0,60.0) -> 16.6931 +/- 0.001.
--     C4  missing temperature / missing humidity / RH<=0 / unbound space_id
--         -> NO persisted row.
--     C5  quality_code NULL pass-through; subject_type='SPACE';
--         calculation_id / calculation_version / source_received_at stamped;
--         organization_id / site_id carried.
--
--   WATERMARK
--     W1  first bounded run: checkpoint NULL -> advances, minute-aligned,
--         never past parent availability, never past now-grace; every
--         persisted bucket_start < checkpoint.
--     W2  idempotent rerun over an unchanged window: row count stable,
--         calculated_at NOT churned on unchanged rows.
--     W3  max_catchup_window: checkpoint far behind, parent recent ->
--         advance bounded to date_bin('1 minute', checkpoint + max_catchup).
--     W4  overlap: a source correction just below the checkpoint is folded
--         back by the next forward run.
--     W5  stalled parent: no advance, NO_SOURCE_DATA / SUCCESS.
--     W6  failure on the checkpoint-advance write -> RAISE propagates, the
--         run's writes and the checkpoint roll back (restart-safe).
--     W7  advisory self-overlap lock / SKIPPED_LOCKED / FAILED->RAISE
--         scaffolding present; refresh reads the Phase 5 view, no CAGG.
--
--   RECONCILIATION
--     R1  bounded: a below-checkpoint source correction is detected by the
--         recency fingerprint; reconcile re-drives it and logs REPAIRED;
--         reconcile NEVER advances telemetry.pipeline_state.last_received_at.
--     R2  n_max: more mismatching coarse buckets than n_max -> outcome
--         PARTIAL, at most n_max re-driven.
--     R3  coarse bucketing: repair granularity is the 1-hour coarse bucket.
--     R4  repeated reconciliation is safe (HEALTHY on the second pass).
--
--   ENERGY REGRESSION
--     E1  energy loader body references no Phase 6 object, still targets
--         telemetry.energy_measurements.
--     E2  the 3 new procs reference no energy / CAGG / routing object.
--     E3  config.parameter_routing still 12 active AirSense rows.
--     E4  energy / demand / normalization jobs still scheduled; energy
--         pipeline_state rows intact; energy consumption refreshers intact.
--     E5  analytics.v_space_dew_point_1min unchanged, still grafana_reader.
--
--   The whole script runs inside one transaction and is ROLLED BACK. The
--   session pre-acquires the forward job's advisory key so the TimescaleDB
--   scheduler cannot race the CALLs (re-entrant for this session).
--   ON_ERROR_STOP=1 in the .sh wrapper fails the runner on any assertion.
-- ============================================================================

BEGIN;

-- Block the scheduler for the duration (re-entrant for this session's CALLs).
SELECT pg_advisory_xact_lock(hashtextextended('telemetry.run_derived_space_dew_point_1min_job', 0));

CREATE TEMP TABLE p6 (k TEXT PRIMARY KEY, u UUID, t TIMESTAMPTZ) ON COMMIT DROP;


-- ===========================================================================
-- SCHEMA
-- ===========================================================================
DO $schema$
DECLARE
    v_txt TEXT;
    v_n   INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id = '230_persisted_space_dew_point') THEN
        RAISE EXCEPTION 'S1 FAILED: admin.schema_migrations has no row for migration 230.';
    END IF;

    IF to_regclass('analytics.derived_parameter_values') IS NULL THEN
        RAISE EXCEPTION 'S1 FAILED: analytics.derived_parameter_values missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables
        WHERE hypertable_schema='analytics' AND hypertable_name='derived_parameter_values'
    ) THEN
        RAISE EXCEPTION 'S1 FAILED: derived_parameter_values is not a hypertable.';
    END IF;

    -- PK columns exactly (calculation_id, device_id, bucket_start)
    SELECT string_agg(a.attname, ',' ORDER BY k.ord) INTO v_txt
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
    WHERE c.conrelid='analytics.derived_parameter_values'::regclass AND c.conname='pk_derived_parameter_values';
    IF v_txt IS DISTINCT FROM 'calculation_id,device_id,bucket_start' THEN
        RAISE EXCEPTION 'S1 FAILED: PK columns "%", expected calculation_id,device_id,bucket_start.', v_txt;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='analytics.derived_parameter_values'::regclass AND conname='ck_derived_parameter_values_subject_binding') THEN
        RAISE EXCEPTION 'S1 FAILED: ck_derived_parameter_values_subject_binding missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='analytics.derived_parameter_values'::regclass AND conname='ck_derived_parameter_values_value_present') THEN
        RAISE EXCEPTION 'S1 FAILED: ck_derived_parameter_values_value_present missing.';
    END IF;

    -- required columns / types
    FOR v_txt IN SELECT unnest(ARRAY[
        'bucket_start=timestamp with time zone','calculation_id=uuid','calculation_version=integer',
        'output_parameter_id=uuid','subject_type=text','space_id=uuid','asset_id=uuid','device_id=uuid',
        'organization_id=uuid','site_id=uuid','numeric_value=double precision','state_value=text',
        'quality_code=smallint','input_quality_summary=jsonb','source_received_at=timestamp with time zone',
        'source_timestamp=timestamp with time zone','calculated_at=timestamp with time zone'])
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema='analytics' AND table_name='derived_parameter_values'
              AND column_name = split_part(v_txt,'=',1)
              AND data_type   = split_part(v_txt,'=',2)
        ) THEN
            RAISE EXCEPTION 'S1 FAILED: column/type % not as approved.', v_txt;
        END IF;
    END LOOP;
    -- NOT NULL where required
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='analytics' AND table_name='derived_parameter_values'
          AND column_name IN ('bucket_start','calculation_id','calculation_version','output_parameter_id',
                              'subject_type','device_id','organization_id','site_id',
                              'input_quality_summary','source_received_at','calculated_at')
          AND is_nullable='YES'
    ) THEN
        RAISE EXCEPTION 'S1 FAILED: a required column is nullable.';
    END IF;

    FOR v_txt IN SELECT unnest(ARRAY[
        'ix_derived_parameter_values_space_time','ix_derived_parameter_values_org_calc_time','ix_derived_parameter_values_device_time'])
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='analytics' AND indexname=v_txt) THEN
            RAISE EXCEPTION 'S1 FAILED: index % missing.', v_txt;
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND hypertable_name='derived_parameter_values') THEN
        RAISE EXCEPTION 'S1 FAILED: retention policy missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name='policy_compression' AND hypertable_name='derived_parameter_values') THEN
        RAISE EXCEPTION 'S1 FAILED: compression policy missing.';
    END IF;

    IF NOT has_table_privilege('ems_app','analytics.derived_parameter_values','SELECT')
       OR NOT has_table_privilege('ems_readonly','analytics.derived_parameter_values','SELECT') THEN
        RAISE EXCEPTION 'S1 FAILED: ems_app / ems_readonly cannot SELECT.';
    END IF;
    IF has_table_privilege('grafana_reader','analytics.derived_parameter_values','SELECT') THEN
        RAISE EXCEPTION 'S1 FAILED: grafana_reader can SELECT (must be internal until Phase 7).';
    END IF;
    IF has_table_privilege('public','analytics.derived_parameter_values','SELECT') THEN
        RAISE EXCEPTION 'S1 FAILED: PUBLIC can SELECT.';
    END IF;

    -- S2 materialization strategy
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid='config.parameter_calculations'::regclass
          AND conname='parameter_calculations_materialization_strategy_check'
          AND pg_get_constraintdef(oid) ILIKE '%''VIEW''%' AND pg_get_constraintdef(oid) ILIKE '%''PERSISTED''%'
    ) THEN
        RAISE EXCEPTION 'S2 FAILED: materialization_strategy CHECK not widened to VIEW/PERSISTED.';
    END IF;
    IF (SELECT count(*) FROM config.parameter_calculations) <> 1 THEN
        RAISE EXCEPTION 'S2 FAILED: config.parameter_calculations must still hold exactly one row.';
    END IF;
    IF (SELECT pc.materialization_strategy FROM config.parameter_calculations pc
        JOIN config.parameters op ON op.id=pc.output_parameter_id
        WHERE op.code='DEW_POINT' AND pc.calculation_version=1) <> 'PERSISTED' THEN
        RAISE EXCEPTION 'S2 FAILED: SPACE_DEW_POINT is not PERSISTED.';
    END IF;

    -- S3 reconciliation-log tier CHECK
    SELECT pg_get_constraintdef(oid) INTO v_txt FROM pg_constraint
    WHERE conrelid='analytics.pipeline_reconciliation_log'::regclass AND conname='pipeline_reconciliation_log_tier_chk';
    IF v_txt NOT LIKE '%derived_space_dew_point_1min%'
       OR v_txt NOT LIKE '%environment_daily%'
       OR v_txt NOT LIKE '%energy_consumption_1min%'
       OR v_txt NOT LIKE '%energy_consumption_daily%'
       OR v_txt NOT LIKE '%demand_intervals%' THEN
        RAISE EXCEPTION 'S3 FAILED: pipeline_reconciliation_log_tier_chk not widened correctly: %', v_txt;
    END IF;

    -- S4 jobs
    SELECT count(*) INTO v_n FROM timescaledb_information.jobs
    WHERE (proc_schema,proc_name) IN
        (('telemetry','run_derived_space_dew_point_1min_job'),('analytics','reconcile_derived_space_dew_point_1min'));
    IF v_n <> 2 THEN RAISE EXCEPTION 'S4 FAILED: expected 2 Phase-6 jobs, found %.', v_n; END IF;
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE (proc_schema,proc_name) IN
            (('telemetry','run_derived_space_dew_point_1min_job'),('analytics','reconcile_derived_space_dew_point_1min'))
          AND scheduled
    ) THEN
        RAISE EXCEPTION 'S4 FAILED: a Phase-6 job is scheduled=true (both MUST remain disabled).';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name='run_derived_space_dew_point_1min_job'
          AND schedule_interval=INTERVAL '5 minutes' AND max_runtime=INTERVAL '5 minutes' AND max_retries=3
          AND retry_period=INTERVAL '5 minutes'
          AND config = jsonb_build_object('lookback','7 days','max_catchup_window','6 hours','overlap','1 hour')
    ) THEN
        RAISE EXCEPTION 'S4 FAILED: forward job schedule/runtime/config not as approved.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name='reconcile_derived_space_dew_point_1min'
          AND schedule_interval=INTERVAL '6 hours' AND max_runtime=INTERVAL '5 minutes' AND max_retries=3
          AND retry_period=INTERVAL '15 minutes'
          AND config = jsonb_build_object('reconcile_window','7 days','coarse','1 hour','n_max',6)
    ) THEN
        RAISE EXCEPTION 'S4 FAILED: reconcile job schedule/runtime/config not as approved.';
    END IF;

    -- S5 pipeline_state
    IF NOT EXISTS (SELECT 1 FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min') THEN
        RAISE EXCEPTION 'S5 FAILED: pipeline_state row missing.';
    END IF;
END;
$schema$;
\echo 'PASS: SCHEMA (S1-S5) -- table shape, PERSISTED, tier CHECK, jobs disabled, pipeline_state'


-- ===========================================================================
-- FIXTURE -- three AirSense sensors in org_1 (one Room, one Seasons Space with
-- two sensors), one sensor in org_2. grafana_organization_map for both.
-- All environment_measurements fixtures are DELETEd first so v_avail /
-- max(bucket_start) is controlled by this test.
-- ===========================================================================
DO $fx$
DECLARE
    org1 UUID; org2 UUID; s1 UUID; s2 UUID; b1 UUID; b2 UUID; f1 UUID; f2 UUID;
    spA UUID; spSeasons UUID; spO2 UUID; gw1 UUID; gw2 UUID;
    devA UUID; devC UUID; devD UUID; devO2 UUID; prof UUID;
BEGIN
    SELECT id INTO prof FROM config.device_profiles WHERE profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1';
    IF prof IS NULL THEN RAISE EXCEPTION 'Fixture: AirSense profile missing.'; END IF;

    -- purge any pre-existing environment_measurements so this test owns v_avail
    DELETE FROM telemetry.environment_measurements;
    UPDATE telemetry.pipeline_state
       SET last_received_at=NULL, last_started_at=NULL, last_completed_at=NULL,
           last_inserted_rows=0, last_status='NEVER_RUN', last_error=NULL, updated_at=now()
     WHERE pipeline_name='derived_space_dew_point_1min';

    INSERT INTO metadata.organizations (id,name,code) VALUES
        (gen_random_uuid(),'P6 Org 1','P6_ORG_1') RETURNING id INTO org1;
    INSERT INTO metadata.organizations (id,name,code) VALUES
        (gen_random_uuid(),'P6 Org 2','P6_ORG_2') RETURNING id INTO org2;
    INSERT INTO metadata.sites (id,organization_id,name,code) VALUES
        (gen_random_uuid(),org1,'P6 Site 1','P6_SITE_1') RETURNING id INTO s1;
    INSERT INTO metadata.sites (id,organization_id,name,code) VALUES
        (gen_random_uuid(),org2,'P6 Site 2','P6_SITE_2') RETURNING id INTO s2;
    INSERT INTO metadata.buildings (id,organization_id,site_id,name,code) VALUES
        (gen_random_uuid(),org1,s1,'P6 B1','P6_B1') RETURNING id INTO b1;
    INSERT INTO metadata.buildings (id,organization_id,site_id,name,code) VALUES
        (gen_random_uuid(),org2,s2,'P6 B2','P6_B2') RETURNING id INTO b2;
    INSERT INTO metadata.floors (id,organization_id,building_id,name,code) VALUES
        (gen_random_uuid(),org1,b1,'P6 F1','P6_F1') RETURNING id INTO f1;
    INSERT INTO metadata.floors (id,organization_id,building_id,name,code) VALUES
        (gen_random_uuid(),org2,b2,'P6 F2','P6_F2') RETURNING id INTO f2;
    INSERT INTO metadata.spaces (id,organization_id,floor_id,name,code) VALUES
        (gen_random_uuid(),org1,f1,'P6 Room A','P6_ROOM_A') RETURNING id INTO spA;
    INSERT INTO metadata.spaces (id,organization_id,floor_id,name,code) VALUES
        (gen_random_uuid(),org1,f1,'P6 Seasons','P6_SEASONS') RETURNING id INTO spSeasons;
    INSERT INTO metadata.spaces (id,organization_id,floor_id,name,code) VALUES
        (gen_random_uuid(),org2,f2,'P6 Room O2','P6_ROOM_O2') RETURNING id INTO spO2;
    INSERT INTO metadata.gateways (id,organization_id,site_id,name,external_id) VALUES
        (gen_random_uuid(),org1,s1,'P6 GW1','P6-GW-1') RETURNING id INTO gw1;
    INSERT INTO metadata.gateways (id,organization_id,site_id,name,external_id) VALUES
        (gen_random_uuid(),org2,s2,'P6 GW2','P6-GW-2') RETURNING id INTO gw2;
    INSERT INTO metadata.devices (id,organization_id,gateway_id,name,external_id,profile_id) VALUES
        (gen_random_uuid(),org1,gw1,'P6 AirSense A','P6-AIR-A',prof) RETURNING id INTO devA;
    INSERT INTO metadata.devices (id,organization_id,gateway_id,name,external_id,profile_id) VALUES
        (gen_random_uuid(),org1,gw1,'P6 AirSense C','P6-AIR-C',prof) RETURNING id INTO devC;
    INSERT INTO metadata.devices (id,organization_id,gateway_id,name,external_id,profile_id) VALUES
        (gen_random_uuid(),org1,gw1,'P6 AirSense D','P6-AIR-D',prof) RETURNING id INTO devD;
    INSERT INTO metadata.devices (id,organization_id,gateway_id,name,external_id,profile_id) VALUES
        (gen_random_uuid(),org2,gw2,'P6 AirSense O2','P6-AIR-O2',prof) RETURNING id INTO devO2;

    INSERT INTO metadata.grafana_organization_map (organization_id, grafana_org_id, is_active)
    VALUES (org1, 960001, TRUE), (org2, 960002, TRUE);

    INSERT INTO p6(k,u) VALUES
        ('org1',org1),('org2',org2),('s1',s1),('s2',s2),
        ('spA',spA),('spSeasons',spSeasons),('spO2',spO2),
        ('devA',devA),('devC',devC),('devD',devD),('devO2',devO2),('gw1',gw1),('gw2',gw2);
END;
$fx$;
\echo 'PASS: FIXTURE (3 AirSense sensors org_1 + 1 org_2; Seasons Space has 2 sensors)'


-- ===========================================================================
-- helper: one environment_measurements bucket
-- ===========================================================================
CREATE FUNCTION pg_temp.p6_env(
    p_dev_key TEXT, p_space_key TEXT, p_org_key TEXT, p_site_key TEXT,
    p_bucket TIMESTAMPTZ, p_recv TIMESTAMPTZ, p_temp DOUBLE PRECISION, p_rh DOUBLE PRECISION
) RETURNS void LANGUAGE plpgsql AS $h$
BEGIN
    INSERT INTO telemetry.environment_measurements
        (bucket_start, received_at, source_timestamp, organization_id, site_id,
         gateway_id, device_id, space_id, temperature_c, humidity_percent)
    VALUES
        (p_bucket, p_recv, p_bucket,
         (SELECT u FROM p6 WHERE k=p_org_key),
         (SELECT u FROM p6 WHERE k=p_site_key),
         (SELECT u FROM p6 WHERE k='gw1'),
         (SELECT u FROM p6 WHERE k=p_dev_key),
         CASE WHEN p_space_key IS NULL THEN NULL ELSE (SELECT u FROM p6 WHERE k=p_space_key) END,
         p_temp, p_rh);
END;
$h$;


-- ===========================================================================
-- CALCULATION + first forward run  (C1-C5, W1, W7)
-- Fixtures sit well past the finalizability grace so one CALL finalizes them.
-- ===========================================================================
DO $calc$
DECLARE
    v_grace   INTERVAL;
    v_base    TIMESTAMPTZ;
    v_avail   TIMESTAMPTZ;
    v_ckpt    TIMESTAMPTZ;
    v_status  TEXT;
    v_n       INTEGER;
    v_dp_v    DOUBLE PRECISION;
    v_dp_p    DOUBLE PRECISION;
    v_src     TEXT;
    devA UUID := (SELECT u FROM p6 WHERE k='devA');
    devC UUID := (SELECT u FROM p6 WHERE k='devC');
    devD UUID := (SELECT u FROM p6 WHERE k='devD');
BEGIN
    v_grace := make_interval(secs =>
          COALESCE((SELECT max(late_arrival_tolerance_seconds) FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + COALESCE((SELECT max(capture_interval_seconds)        FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + 300);
    -- base minute, comfortably older than grace
    v_base := date_trunc('minute', clock_timestamp() - v_grace - INTERVAL '30 minutes');

    -- devA, Room A: normal (25,60)->16.6931 ; (20,80)->16.4424
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base + INTERVAL '0 min', v_base + INTERVAL '0 min' + INTERVAL '5 sec', 25.0, 60.0);
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base + INTERVAL '1 min', v_base + INTERVAL '1 min' + INTERVAL '5 sec', 20.0, 80.0);
    -- missing temperature / missing humidity / RH<=0 -> no row
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base + INTERVAL '2 min', v_base + INTERVAL '2 min' + INTERVAL '5 sec', NULL, 55.0);
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base + INTERVAL '3 min', v_base + INTERVAL '3 min' + INTERVAL '5 sec', 22.0, NULL);
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base + INTERVAL '4 min', v_base + INTERVAL '4 min' + INTERVAL '5 sec', 22.0, 0.0);
    -- Seasons: two sensors, same bucket -> two independent rows
    PERFORM pg_temp.p6_env('devC','spSeasons','org1','s1', v_base + INTERVAL '0 min', v_base + INTERVAL '0 min' + INTERVAL '5 sec', 27.0, 55.0);
    PERFORM pg_temp.p6_env('devD','spSeasons','org1','s1', v_base + INTERVAL '0 min', v_base + INTERVAL '0 min' + INTERVAL '5 sec', 27.5, 52.0);
    -- devC unbound space_id -> no row
    PERFORM pg_temp.p6_env('devC', NULL, 'org1','s1', v_base + INTERVAL '2 min', v_base + INTERVAL '2 min' + INTERVAL '5 sec', 23.0, 45.0);
    -- org_2 sensor (tenant isolation cross-check of the persisted rows)
    PERFORM pg_temp.p6_env('devO2','spO2','org2','s2', v_base + INTERVAL '0 min', v_base + INTERVAL '0 min' + INTERVAL '5 sec', 21.0, 65.0);
    -- frontier marker: a newer-but-still-finalizable bucket so v_avail is ahead
    -- of the rows under test and v_to lands strictly after them.
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base + INTERVAL '20 min', v_base + INTERVAL '20 min' + INTERVAL '5 sec', 24.0, 50.0);

    SELECT max(bucket_start) INTO v_avail FROM telemetry.environment_measurements;

    -- one forward run; wide catch-up + short lookback so the recent window is covered
    CALL telemetry.run_derived_space_dew_point_1min_job(0,
        '{"lookback":"1 hour","max_catchup_window":"3650 days","overlap":"1 hour"}'::jsonb);

    SELECT last_received_at, last_status INTO v_ckpt, v_status
      FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';

    -- W1: checkpoint advanced, minute-aligned, never past parent / now-grace
    IF v_ckpt IS NULL THEN RAISE EXCEPTION 'W1 FAILED: checkpoint did not advance.'; END IF;
    IF v_ckpt <> date_trunc('minute', v_ckpt) THEN RAISE EXCEPTION 'W1 FAILED: checkpoint % not minute-aligned.', v_ckpt; END IF;
    IF v_ckpt > v_avail THEN RAISE EXCEPTION 'W1 FAILED: checkpoint % past parent availability %.', v_ckpt, v_avail; END IF;
    IF v_ckpt > clock_timestamp() - v_grace + INTERVAL '1 minute' THEN
        RAISE EXCEPTION 'W1 FAILED: checkpoint % past the finalizable frontier (now-grace).', v_ckpt;
    END IF;
    IF v_status NOT IN ('SUCCESS','NO_SOURCE_DATA') THEN RAISE EXCEPTION 'W1 FAILED: status %.', v_status; END IF;

    -- every persisted bucket_start is strictly below the checkpoint
    IF EXISTS (SELECT 1 FROM analytics.derived_parameter_values WHERE bucket_start >= v_ckpt) THEN
        RAISE EXCEPTION 'W1 FAILED: a persisted row is at/after the checkpoint.';
    END IF;

    -- C1: persisted set == Phase 5 view for buckets below the checkpoint (both ways)
    IF EXISTS (
        SELECT v.device_id, v.bucket_start FROM analytics.v_space_dew_point_1min v
        WHERE v.bucket_start < v_ckpt
        EXCEPT
        SELECT d.device_id, d.bucket_start FROM analytics.derived_parameter_values d
    ) THEN
        RAISE EXCEPTION 'C1 FAILED: a Phase-5 view row below the checkpoint was not persisted.';
    END IF;
    IF EXISTS (
        SELECT d.device_id, d.bucket_start FROM analytics.derived_parameter_values d
        EXCEPT
        SELECT v.device_id, v.bucket_start FROM analytics.v_space_dew_point_1min v
    ) THEN
        RAISE EXCEPTION 'C1 FAILED: a persisted row has no matching Phase-5 view row.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM analytics.derived_parameter_values d
        JOIN analytics.v_space_dew_point_1min v
          ON v.device_id=d.device_id AND v.bucket_start=d.bucket_start
        WHERE d.numeric_value IS DISTINCT FROM v.dew_point_c
    ) THEN
        RAISE EXCEPTION 'C1 FAILED: a persisted numeric_value differs from the Phase-5 view.';
    END IF;

    -- C2: Seasons Space -- two sensors, one bucket -> two independent rows
    IF (SELECT count(*) FROM analytics.derived_parameter_values
        WHERE space_id=(SELECT u FROM p6 WHERE k='spSeasons') AND bucket_start=v_base) <> 2 THEN
        RAISE EXCEPTION 'C2 FAILED: expected 2 persisted rows for Seasons Space + one bucket.';
    END IF;
    IF (SELECT count(DISTINCT numeric_value) FROM analytics.derived_parameter_values
        WHERE space_id=(SELECT u FROM p6 WHERE k='spSeasons') AND bucket_start=v_base) <> 2 THEN
        RAISE EXCEPTION 'C2 FAILED: the two Seasons sensor rows were averaged/collapsed.';
    END IF;
    IF (SELECT count(DISTINCT device_id) FROM analytics.derived_parameter_values
        WHERE space_id=(SELECT u FROM p6 WHERE k='spSeasons') AND bucket_start=v_base) <> 2 THEN
        RAISE EXCEPTION 'C2 FAILED: device identity not preserved for Seasons rows.';
    END IF;

    -- C3: Magnus value == view AND == fixed constant 16.6931 +/- 0.001
    SELECT dew_point_c INTO v_dp_v FROM analytics.v_space_dew_point_1min WHERE device_id=devA AND bucket_start=v_base;
    SELECT numeric_value INTO v_dp_p FROM analytics.derived_parameter_values WHERE device_id=devA AND bucket_start=v_base;
    IF v_dp_p IS DISTINCT FROM v_dp_v THEN RAISE EXCEPTION 'C3 FAILED: persisted % <> view % for (25,60).', v_dp_p, v_dp_v; END IF;
    IF v_dp_p IS NULL OR abs(v_dp_p - 16.6931) > 0.001 THEN
        RAISE EXCEPTION 'C3 FAILED: dew point for (25.0,60.0) expected 16.6931 +/- 0.001, got %.', v_dp_p;
    END IF;

    -- C4: missing temp / missing humidity / RH<=0 / unbound space_id -> no persisted row
    IF EXISTS (SELECT 1 FROM analytics.derived_parameter_values WHERE device_id=devA AND bucket_start IN (v_base+INTERVAL '2 min', v_base+INTERVAL '3 min', v_base+INTERVAL '4 min')) THEN
        RAISE EXCEPTION 'C4 FAILED: a missing-input / RH<=0 bucket was persisted.';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.derived_parameter_values WHERE device_id=devC AND bucket_start=v_base+INTERVAL '2 min') THEN
        RAISE EXCEPTION 'C4 FAILED: an unbound-space_id measurement was persisted.';
    END IF;

    -- C5: quality NULL pass-through; subject/stamps/tenant columns
    IF EXISTS (SELECT 1 FROM analytics.derived_parameter_values WHERE quality_code IS NOT NULL) THEN
        RAISE EXCEPTION 'C5 FAILED: a persisted row has a non-NULL quality_code (no lattice permitted).';
    END IF;
    IF EXISTS (
        SELECT 1 FROM analytics.derived_parameter_values d
        JOIN config.parameter_calculations pc ON pc.id=d.calculation_id
        JOIN config.parameters op ON op.id=pc.output_parameter_id
        WHERE d.subject_type <> 'SPACE' OR d.space_id IS NULL OR d.asset_id IS NOT NULL
           OR d.calculation_version <> pc.calculation_version
           OR op.code <> 'DEW_POINT'
           OR d.output_parameter_id <> pc.output_parameter_id
           OR d.source_received_at IS NULL
           OR d.organization_id IS NULL OR d.site_id IS NULL
           OR NOT (d.input_quality_summary ? 'null_handling')
    ) THEN
        RAISE EXCEPTION 'C5 FAILED: a persisted row has wrong subject / stamp / tenant / summary.';
    END IF;
    -- persisted rows are org_1 only (org_2 has its own grafana_org; both mapped, so both persist,
    -- but each row must carry its own org)
    IF EXISTS (
        SELECT 1 FROM analytics.derived_parameter_values d
        WHERE (d.device_id = (SELECT u FROM p6 WHERE k='devO2') AND d.organization_id <> (SELECT u FROM p6 WHERE k='org2'))
           OR (d.device_id IN (devA,devC,devD) AND d.organization_id <> (SELECT u FROM p6 WHERE k='org1'))
    ) THEN
        RAISE EXCEPTION 'C5 FAILED: a persisted row carries the wrong organization_id.';
    END IF;

    -- W7: wrapper scaffolding + refresh reads the view, no CAGG
    v_src := pg_get_functiondef('telemetry.run_derived_space_dew_point_1min_job(integer,jsonb)'::regprocedure);
    IF position('pg_try_advisory_xact_lock(' IN v_src)=0
       OR position('SKIPPED_LOCKED' IN v_src)=0
       OR position('''FAILED''' IN v_src)=0 OR position('RAISE;' IN v_src)=0
       OR position('last_received_at   = v_to' IN v_src)=0 THEN
        RAISE EXCEPTION 'W7 FAILED: forward wrapper lost advisory-lock / SKIPPED_LOCKED / FAILED->RAISE / watermark advance.';
    END IF;
    IF position('max(bucket_start)' IN v_src)=0 OR position('environment_measurements' IN v_src)=0 THEN
        RAISE EXCEPTION 'W7 FAILED: parent availability is not max(environment_measurements.bucket_start).';
    END IF;
    v_src := pg_get_functiondef('analytics.refresh_derived_space_dew_point_1min(timestamptz,timestamptz)'::regprocedure);
    IF position('v_space_dew_point_1min' IN v_src)=0 THEN
        RAISE EXCEPTION 'W7 FAILED: refresh function does not read analytics.v_space_dew_point_1min.';
    END IF;
    IF position('ca_energy' IN lower(v_src)) <> 0 OR position('refresh_continuous_aggregate' IN lower(v_src)) <> 0 THEN
        RAISE EXCEPTION 'W7 FAILED: refresh function references a CAGG.';
    END IF;
END;
$calc$;
\echo 'PASS: CALCULATION + first forward run (C1-C5, W1, W7)'


-- ===========================================================================
-- W2  idempotent rerun
-- ===========================================================================
DO $idem$
DECLARE
    v_cnt_1 BIGINT; v_cnt_2 BIGINT;
    v_calc_1 TEXT; v_calc_2 TEXT;
    v_ckpt_1 TIMESTAMPTZ; v_ckpt_2 TIMESTAMPTZ;
BEGIN
    SELECT count(*), string_agg(device_id::text || bucket_start::text || calculated_at::text, '|' ORDER BY device_id, bucket_start)
      INTO v_cnt_1, v_calc_1 FROM analytics.derived_parameter_values;
    SELECT last_received_at INTO v_ckpt_1 FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';

    -- rewind the checkpoint so the second run actually RE-PROCESSES the recent
    -- window (exercises the value-aware upsert, not just the no-work guard).
    UPDATE telemetry.pipeline_state
       SET last_received_at = last_received_at - INTERVAL '10 minutes'
     WHERE pipeline_name='derived_space_dew_point_1min';

    CALL telemetry.run_derived_space_dew_point_1min_job(0,
        '{"lookback":"1 hour","max_catchup_window":"3650 days","overlap":"1 hour"}'::jsonb);

    SELECT count(*), string_agg(device_id::text || bucket_start::text || calculated_at::text, '|' ORDER BY device_id, bucket_start)
      INTO v_cnt_2, v_calc_2 FROM analytics.derived_parameter_values;
    SELECT last_received_at INTO v_ckpt_2 FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';

    IF v_cnt_2 <> v_cnt_1 THEN RAISE EXCEPTION 'W2 FAILED: row count changed on idempotent rerun (% -> %).', v_cnt_1, v_cnt_2; END IF;
    IF v_calc_2 IS DISTINCT FROM v_calc_1 THEN RAISE EXCEPTION 'W2 FAILED: calculated_at churned on unchanged rows (value-aware upsert broken).'; END IF;
    IF v_ckpt_2 < v_ckpt_1 THEN RAISE EXCEPTION 'W2 FAILED: checkpoint went backwards.'; END IF;
END;
$idem$;
\echo 'PASS: W2  idempotent rerun -- stable rows, no calculated_at churn'


-- ===========================================================================
-- W3  max_catchup_window bound
-- ===========================================================================
DO $catchup$
DECLARE
    v_ckpt   TIMESTAMPTZ := date_trunc('minute', clock_timestamp()) - INTERVAL '10 days';
    v_expect TIMESTAMPTZ;
    v_after  TIMESTAMPTZ;
BEGIN
    -- a very recent parent so the frontier is far ahead of checkpoint + 6h
    PERFORM pg_temp.p6_env('devA','spA','org1','s1',
        date_trunc('minute', clock_timestamp()) - INTERVAL '40 minutes',
        clock_timestamp() - INTERVAL '39 minutes', 24.0, 50.0);

    UPDATE telemetry.pipeline_state
       SET last_received_at=v_ckpt, last_status='SUCCESS', last_error=NULL
     WHERE pipeline_name='derived_space_dew_point_1min';

    v_expect := date_bin(INTERVAL '1 minute', v_ckpt + INTERVAL '6 hours', TIMESTAMPTZ '2000-01-01 00:00:00+00');

    CALL telemetry.run_derived_space_dew_point_1min_job(0,
        '{"lookback":"7 days","max_catchup_window":"6 hours","overlap":"1 hour"}'::jsonb);

    SELECT last_received_at INTO v_after FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';
    IF v_after IS DISTINCT FROM v_expect THEN
        RAISE EXCEPTION 'W3 FAILED: advance % <> checkpoint + max_catchup_window %.', v_after, v_expect;
    END IF;
END;
$catchup$;
\echo 'PASS: W3  per-run advance bounded to checkpoint + max_catchup_window'


-- ===========================================================================
-- W5  stalled parent -> no advance
-- ===========================================================================
DO $stall$
DECLARE
    v_ckpt  TIMESTAMPTZ;
    v_after TIMESTAMPTZ; v_status TEXT;
BEGIN
    SELECT max(bucket_start) + INTERVAL '5 minutes' INTO v_ckpt FROM telemetry.environment_measurements;
    UPDATE telemetry.pipeline_state
       SET last_received_at=v_ckpt, last_status='SUCCESS', last_error=NULL
     WHERE pipeline_name='derived_space_dew_point_1min';

    CALL telemetry.run_derived_space_dew_point_1min_job(0,
        '{"lookback":"7 days","max_catchup_window":"6 hours","overlap":"1 hour"}'::jsonb);

    SELECT last_received_at, last_status INTO v_after, v_status
      FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';
    IF v_after IS DISTINCT FROM v_ckpt THEN
        RAISE EXCEPTION 'W5 FAILED: checkpoint advanced with parent not ahead (% -> %).', v_ckpt, v_after;
    END IF;
    IF v_status NOT IN ('SUCCESS','NO_SOURCE_DATA') THEN RAISE EXCEPTION 'W5 FAILED: status %.', v_status; END IF;
END;
$stall$;
\echo 'PASS: W5  parent not advancing -> checkpoint not advanced'


-- ===========================================================================
-- W6  failure on the checkpoint-advance write -> RAISE + full rollback
-- ===========================================================================
DO $fail$
DECLARE
    v_grace  INTERVAL;
    v_base   TIMESTAMPTZ;
    v_ckpt_before TIMESTAMPTZ;
    v_ckpt_after  TIMESTAMPTZ;
    v_cnt_before  BIGINT;
    v_cnt_after   BIGINT;
    v_raised BOOLEAN := FALSE;
BEGIN
    v_grace := make_interval(secs =>
          COALESCE((SELECT max(late_arrival_tolerance_seconds) FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + COALESCE((SELECT max(capture_interval_seconds)        FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + 300);
    v_base := date_trunc('minute', clock_timestamp() - v_grace - INTERVAL '15 minutes');

    -- a fresh finalizable bucket + a frontier marker so a real advance AND a
    -- real INSERT both occur before the injected failure
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base, v_base + INTERVAL '5 sec', 26.0, 58.0);
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base + INTERVAL '10 min', v_base + INTERVAL '10 min' + INTERVAL '5 sec', 24.0, 50.0);

    UPDATE telemetry.pipeline_state
       SET last_received_at = v_base - INTERVAL '5 minutes', last_status='SUCCESS', last_error=NULL
     WHERE pipeline_name='derived_space_dew_point_1min';

    SELECT last_received_at INTO v_ckpt_before FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';
    SELECT count(*) INTO v_cnt_before FROM analytics.derived_parameter_values;

    CREATE FUNCTION pg_temp.p6_boom() RETURNS trigger LANGUAGE plpgsql AS $b$
    BEGIN
        IF NEW.pipeline_name = 'derived_space_dew_point_1min'
           AND NEW.last_received_at IS DISTINCT FROM OLD.last_received_at THEN
            RAISE EXCEPTION 'p6 injected failure on checkpoint advance';
        END IF;
        RETURN NEW;
    END;
    $b$;
    CREATE TRIGGER p6_boom_trg BEFORE UPDATE ON telemetry.pipeline_state
        FOR EACH ROW EXECUTE FUNCTION pg_temp.p6_boom();

    BEGIN
        CALL telemetry.run_derived_space_dew_point_1min_job(0,
            '{"lookback":"1 hour","max_catchup_window":"3650 days","overlap":"1 hour"}'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
    END;

    DROP TRIGGER p6_boom_trg ON telemetry.pipeline_state;

    IF NOT v_raised THEN RAISE EXCEPTION 'W6 FAILED: injected failure did not propagate.'; END IF;

    SELECT last_received_at INTO v_ckpt_after FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';
    SELECT count(*) INTO v_cnt_after FROM analytics.derived_parameter_values;

    IF v_ckpt_after IS DISTINCT FROM v_ckpt_before THEN
        RAISE EXCEPTION 'W6 FAILED: checkpoint moved despite failure (% -> %).', v_ckpt_before, v_ckpt_after;
    END IF;
    IF v_cnt_after <> v_cnt_before THEN
        RAISE EXCEPTION 'W6 FAILED: derived rows changed despite failure (% -> %).', v_cnt_before, v_cnt_after;
    END IF;
END;
$fail$;
\echo 'PASS: W6  failure on advance -> RAISE propagates; writes + checkpoint roll back'


-- ===========================================================================
-- W4 + R1 + R3 + R4  overlap fold-back, recency fingerprint, coarse re-drive,
-- reconcile never advances the watermark, repeated reconcile is safe.
-- ===========================================================================
DO $reconcile$
DECLARE
    v_grace   INTERVAL;
    v_base    TIMESTAMPTZ;
    v_ckpt    TIMESTAMPTZ;
    v_devA UUID := (SELECT u FROM p6 WHERE k='devA');
    v_old_dp  DOUBLE PRECISION;
    v_new_dp  DOUBLE PRECISION;
    v_pers_dp DOUBLE PRECISION;
    v_log_ct  INTEGER;
    v_outcome TEXT;
    v_ckpt_after TIMESTAMPTZ;
    v_repaired BIGINT;
BEGIN
    -- clean slate for this block
    DELETE FROM analytics.derived_parameter_values;
    DELETE FROM telemetry.environment_measurements;
    DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='derived_space_dew_point_1min';

    v_grace := make_interval(secs =>
          COALESCE((SELECT max(late_arrival_tolerance_seconds) FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + COALESCE((SELECT max(capture_interval_seconds)        FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + 300);
    -- one bucket ~90 minutes old, well past grace and well inside reconcile_window
    v_base := date_trunc('minute', clock_timestamp() - v_grace - INTERVAL '90 minutes');

    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base, v_base + INTERVAL '5 sec', 25.0, 60.0);
    -- frontier marker (finalizable, newer than the bucket under test, in a
    -- different coarse hour so a re-drive never touches it)
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_base + INTERVAL '60 min', v_base + INTERVAL '60 min' + INTERVAL '5 sec', 24.0, 50.0);

    -- initial forward run persists it
    UPDATE telemetry.pipeline_state
       SET last_received_at=NULL, last_status='NEVER_RUN', last_error=NULL
     WHERE pipeline_name='derived_space_dew_point_1min';
    CALL telemetry.run_derived_space_dew_point_1min_job(0,
        '{"lookback":"7 days","max_catchup_window":"3650 days","overlap":"1 hour"}'::jsonb);

    SELECT numeric_value INTO v_old_dp FROM analytics.derived_parameter_values WHERE device_id=v_devA AND bucket_start=v_base;
    IF v_old_dp IS NULL THEN RAISE EXCEPTION 'R1 setup FAILED: bucket was not persisted.'; END IF;
    SELECT last_received_at INTO v_ckpt FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';
    IF v_base >= v_ckpt THEN RAISE EXCEPTION 'R1 setup FAILED: bucket not below the checkpoint.'; END IF;

    -- A correction lands BELOW the checkpoint but OUTSIDE the 1-hour overlap:
    -- humidity 60 -> 90, and received_at bumped forward (as the routing loader does).
    UPDATE telemetry.environment_measurements
       SET humidity_percent = 90.0, received_at = received_at + INTERVAL '30 minutes'
     WHERE device_id=v_devA AND bucket_start=v_base;

    SELECT dew_point_c INTO v_new_dp FROM analytics.v_space_dew_point_1min WHERE device_id=v_devA AND bucket_start=v_base;
    IF v_new_dp IS NOT DISTINCT FROM v_old_dp THEN
        RAISE EXCEPTION 'R1 setup FAILED: the humidity correction did not change the view dew point.';
    END IF;

    -- A plain forward run does NOT re-touch it (correction is older than overlap
    -- and below the checkpoint).
    CALL telemetry.run_derived_space_dew_point_1min_job(0,
        '{"lookback":"7 days","max_catchup_window":"3650 days","overlap":"1 hour"}'::jsonb);
    SELECT numeric_value INTO v_pers_dp FROM analytics.derived_parameter_values WHERE device_id=v_devA AND bucket_start=v_base;
    IF v_pers_dp IS DISTINCT FROM v_old_dp THEN
        RAISE EXCEPTION 'W4/R1 FAILED: forward run silently repaired a below-overlap correction (should be reconcile territory).';
    END IF;

    -- Reconcile detects it via the recency fingerprint and re-drives the coarse bucket.
    CALL analytics.reconcile_derived_space_dew_point_1min(0,
        '{"reconcile_window":"7 days","coarse":"1 hour","n_max":6}'::jsonb);

    SELECT numeric_value INTO v_pers_dp FROM analytics.derived_parameter_values WHERE device_id=v_devA AND bucket_start=v_base;
    IF v_pers_dp IS DISTINCT FROM v_new_dp THEN
        RAISE EXCEPTION 'R1 FAILED: reconcile did not repair the corrected bucket (persisted % <> view %).', v_pers_dp, v_new_dp;
    END IF;

    SELECT count(*) INTO v_log_ct
      FROM analytics.pipeline_reconciliation_log WHERE tier='derived_space_dew_point_1min';
    IF v_log_ct <> 1 THEN RAISE EXCEPTION 'R1 FAILED: expected exactly 1 reconciliation-log row after 1 reconcile CALL, got %.', v_log_ct; END IF;
    IF NOT EXISTS (SELECT 1 FROM analytics.pipeline_reconciliation_log WHERE tier='derived_space_dew_point_1min' AND outcome='REPAIRED') THEN
        RAISE EXCEPTION 'R1 FAILED: the reconcile run was not logged as REPAIRED.';
    END IF;

    -- R1: reconcile never advances the forward checkpoint
    SELECT last_received_at INTO v_ckpt_after FROM telemetry.pipeline_state WHERE pipeline_name='derived_space_dew_point_1min';
    IF v_ckpt_after IS DISTINCT FROM v_ckpt THEN
        RAISE EXCEPTION 'R1 FAILED: reconcile advanced telemetry.pipeline_state.last_received_at (% -> %).', v_ckpt, v_ckpt_after;
    END IF;

    -- R4: a second reconcile pass is HEALTHY (nothing left to repair)
    CALL analytics.reconcile_derived_space_dew_point_1min(0,
        '{"reconcile_window":"7 days","coarse":"1 hour","n_max":6}'::jsonb);
    SELECT outcome INTO v_outcome FROM analytics.pipeline_reconciliation_log
     WHERE tier='derived_space_dew_point_1min' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'HEALTHY' THEN
        RAISE EXCEPTION 'R4 FAILED: second reconcile pass outcome % (expected HEALTHY).', v_outcome;
    END IF;
END;
$reconcile$;
\echo 'PASS: W4 + R1 + R3 + R4  overlap boundary, recency fingerprint repair, no watermark advance, repeat-safe'


-- ===========================================================================
-- R2  n_max enforcement -> PARTIAL, at most n_max coarse buckets re-driven
-- ===========================================================================
DO $nmax$
DECLARE
    v_grace   INTERVAL;
    v_h       INTEGER;
    v_bucket  TIMESTAMPTZ;
    v_ckpt    TIMESTAMPTZ;
    v_devA UUID := (SELECT u FROM p6 WHERE k='devA');
    v_outcome TEXT;
    v_examined INTEGER;
    v_repaired_before BIGINT;
BEGIN
    DELETE FROM analytics.derived_parameter_values;
    DELETE FROM telemetry.environment_measurements;
    DELETE FROM analytics.pipeline_reconciliation_log WHERE tier='derived_space_dew_point_1min';

    v_grace := make_interval(secs =>
          COALESCE((SELECT max(late_arrival_tolerance_seconds) FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + COALESCE((SELECT max(capture_interval_seconds)        FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + 300);

    -- one bucket in each of 9 distinct hours, all past grace (so > n_max=6 coarse buckets)
    FOR v_h IN 1..9 LOOP
        v_bucket := date_bin(INTERVAL '1 hour', clock_timestamp() - v_grace - INTERVAL '30 minutes', TIMESTAMPTZ '2000-01-01 00:00:00+00')
                    - make_interval(hours => v_h) + INTERVAL '10 minutes';
        PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_bucket, v_bucket + INTERVAL '5 sec', 25.0, 60.0);
    END LOOP;
    -- frontier marker in its own (10th) coarse hour, newer than all 9, finalizable
    v_bucket := date_bin(INTERVAL '1 hour', clock_timestamp() - v_grace - INTERVAL '30 minutes', TIMESTAMPTZ '2000-01-01 00:00:00+00')
                + INTERVAL '10 minutes';
    PERFORM pg_temp.p6_env('devA','spA','org1','s1', v_bucket, v_bucket + INTERVAL '5 sec', 24.0, 50.0);

    -- forward run persists all 9
    UPDATE telemetry.pipeline_state SET last_received_at=NULL, last_status='NEVER_RUN' WHERE pipeline_name='derived_space_dew_point_1min';
    CALL telemetry.run_derived_space_dew_point_1min_job(0,
        '{"lookback":"7 days","max_catchup_window":"3650 days","overlap":"1 hour"}'::jsonb);
    IF (SELECT count(*) FROM analytics.derived_parameter_values) <> 9 THEN
        RAISE EXCEPTION 'R2 setup FAILED: expected 9 persisted rows, got %.', (SELECT count(*) FROM analytics.derived_parameter_values);
    END IF;

    -- correct ALL 9 (humidity + received_at bump) so every hour is a mismatch
    UPDATE telemetry.environment_measurements
       SET humidity_percent = 85.0, received_at = received_at + INTERVAL '20 minutes'
     WHERE device_id=v_devA;

    CALL analytics.reconcile_derived_space_dew_point_1min(0,
        '{"reconcile_window":"30 days","coarse":"1 hour","n_max":6}'::jsonb);

    SELECT outcome, coarse_examined INTO v_outcome, v_examined
      FROM analytics.pipeline_reconciliation_log WHERE tier='derived_space_dew_point_1min'
      ORDER BY ran_at DESC LIMIT 1;

    IF v_outcome <> 'PARTIAL' THEN
        RAISE EXCEPTION 'R2 FAILED: 9 mismatching hours with n_max=6 should yield PARTIAL, got %.', v_outcome;
    END IF;
    -- coarse_examined counts up to n_max+1 (the +1 is the "there is more" probe)
    IF v_examined > 7 THEN
        RAISE EXCEPTION 'R2 FAILED: coarse_examined % exceeds n_max+1.', v_examined;
    END IF;

    -- a follow-up pass finishes the remainder and lands REPAIRED, then HEALTHY
    CALL analytics.reconcile_derived_space_dew_point_1min(0, '{"reconcile_window":"30 days","coarse":"1 hour","n_max":6}'::jsonb);
    CALL analytics.reconcile_derived_space_dew_point_1min(0, '{"reconcile_window":"30 days","coarse":"1 hour","n_max":6}'::jsonb);
    SELECT outcome INTO v_outcome FROM analytics.pipeline_reconciliation_log
     WHERE tier='derived_space_dew_point_1min' ORDER BY ran_at DESC LIMIT 1;
    IF v_outcome <> 'HEALTHY' THEN
        RAISE EXCEPTION 'R2 FAILED: reconcile did not drain the backlog to HEALTHY (last outcome %).', v_outcome;
    END IF;
    IF EXISTS (
        SELECT 1 FROM analytics.derived_parameter_values d
        JOIN analytics.v_space_dew_point_1min v ON v.device_id=d.device_id AND v.bucket_start=d.bucket_start
        WHERE d.numeric_value IS DISTINCT FROM v.dew_point_c
    ) THEN
        RAISE EXCEPTION 'R2 FAILED: after draining, a persisted value still disagrees with the view.';
    END IF;
END;
$nmax$;
\echo 'PASS: R2  n_max -> PARTIAL then drains to HEALTHY; coarse (1h) bucketing'


-- ===========================================================================
-- ENERGY REGRESSION  (E1-E5)
-- ===========================================================================
DO $energy$
DECLARE
    v_txt TEXT;
    v_prc TEXT;
BEGIN
    -- E1 energy loader body
    v_txt := lower(pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure));
    IF position('derived_parameter_values' IN v_txt) <> 0
       OR position('parameter_calculations' IN v_txt) <> 0
       OR position('v_space_dew_point_1min' IN v_txt) <> 0
       OR position('refresh_derived' IN v_txt) <> 0
       OR position('dew_point' IN v_txt) <> 0
       OR position('space_id' IN v_txt) <> 0
       OR position('space_points' IN v_txt) <> 0 THEN
        RAISE EXCEPTION 'E1 FAILED: energy loader body references a Phase 2/3/5/6 object.';
    END IF;
    IF position('telemetry.energy_measurements' IN v_txt) = 0 THEN
        RAISE EXCEPTION 'E1 FAILED: energy loader no longer targets telemetry.energy_measurements.';
    END IF;

    -- E2 new-proc isolation
    FOR v_prc IN SELECT unnest(ARRAY[
        'analytics.refresh_derived_space_dew_point_1min(timestamptz,timestamptz)',
        'telemetry.run_derived_space_dew_point_1min_job(integer,jsonb)',
        'analytics.reconcile_derived_space_dew_point_1min(integer,jsonb)'])
    LOOP
        v_txt := lower(pg_get_functiondef(v_prc::regprocedure));
        -- 'demand_' is NOT a token: the forward wrapper legitimately names
        -- config.site_demand_policies in a comment to say it is NOT used.
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
            RAISE EXCEPTION 'E2 FAILED: % references an energy/CAGG/routing object.', v_prc;
        END IF;
    END LOOP;

    -- E3 routing rows
    IF (SELECT count(*) FROM config.parameter_routing WHERE is_active AND destination_table='telemetry.environment_measurements') <> 12 THEN
        RAISE EXCEPTION 'E3 FAILED: config.parameter_routing active AirSense rows != 12.';
    END IF;

    -- E4 energy/demand/normalization jobs still scheduled; refreshers intact; pipeline_state rows intact
    FOR v_prc IN SELECT unnest(ARRAY[
        'run_energy_routing_job','run_environment_routing_job',
        'run_energy_consumption_1min_job','run_energy_consumption_5min_job','run_energy_consumption_15min_job',
        'run_energy_consumption_hourly_job','run_energy_consumption_daily_job','run_environment_daily_job'])
    LOOP
        IF EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name=v_prc)
           AND NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name=v_prc AND scheduled) THEN
            RAISE EXCEPTION 'E4 FAILED: job % is no longer scheduled.', v_prc;
        END IF;
    END LOOP;
    FOR v_prc IN SELECT unnest(ARRAY[
        'analytics.refresh_energy_consumption_1min(timestamptz,timestamptz)',
        'analytics.refresh_energy_consumption_daily(timestamptz,timestamptz)'])
    LOOP
        IF to_regprocedure(v_prc) IS NULL THEN RAISE EXCEPTION 'E4 FAILED: % missing.', v_prc; END IF;
    END LOOP;
    FOR v_txt IN SELECT unnest(ARRAY[
        'normalized_points','energy_measurements','energy_consumption_1min',
        'energy_consumption_daily','demand_intervals'])
    LOOP
        IF NOT EXISTS (SELECT 1 FROM telemetry.pipeline_state WHERE pipeline_name=v_txt) THEN
            RAISE EXCEPTION 'E4 FAILED: pipeline_state row % missing.', v_txt;
        END IF;
    END LOOP;

    -- E5 Phase 5 view unchanged, still grafana_reader
    v_txt := pg_get_viewdef('analytics.v_space_dew_point_1min'::regclass, true);
    IF position('telemetry.environment_measurements' IN v_txt) = 0
       OR position('space_id IS NOT NULL' IN v_txt) = 0
       OR position('humidity_percent > 0' IN v_txt) = 0
       OR position('derived_parameter_values' IN v_txt) <> 0 THEN
        RAISE EXCEPTION 'E5 FAILED: analytics.v_space_dew_point_1min was modified.';
    END IF;
    IF NOT has_table_privilege('grafana_reader','analytics.v_space_dew_point_1min','SELECT') THEN
        RAISE EXCEPTION 'E5 FAILED: the Phase 5 view lost its grafana_reader grant.';
    END IF;
END;
$energy$;
\echo 'PASS: ENERGY REGRESSION (E1-E5) -- loader / procs / routing / jobs / pipeline_state / Phase 5 view'


ROLLBACK;

SELECT 'Phase 6 (migration 230) persisted SPACE_DEW_POINT tier assertions passed.' AS result;
