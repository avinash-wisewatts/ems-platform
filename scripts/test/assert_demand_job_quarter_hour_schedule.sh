#!/usr/bin/env bash
# ============================================================================
# Migration 298 -- demand forward job every 15 minutes at UTC quarter-hour +
# 7 minutes (plan T1.3c-1). Rollback-only.
#
# Holds every forward-job advisory key for the whole transaction (re-entrant
# for this session's own CALLs) so the TimescaleDB scheduler cannot race the
# CALLs -- the assert_demand_watermark_refinalization.sh idiom.
#
# Covered:
#   S-SCHED     job 1078 schedule: 15 minutes, fixed schedule, initial_start
#               and next_start on the :07/:22/:37/:52 UTC grid.
#   S-KEEP      every other job setting is the pre-298 value: max_runtime
#               10 min, max_retries 3, retry_period 5 min (shorter than the
#               schedule, so a failed run is retried before the next slot),
#               scheduled, config, check_config; wrapper still watermark-driven.
#   S-PHASE     the +7 min phase is after the job's own grace, so a slot
#               finalizes the interval that ended at the quarter-hour.
#   S-CATCHUP   checkpoint one hour behind (three missed slots): ONE run
#               finalizes every missed interval (VALID) and advances the
#               checkpoint to the newest eligible quarter-hour.
#   S-RERUN     an immediate re-run (duplicate / retried slot) changes nothing:
#               checkpoint, rows and finalized_at identical.
#   S-RETRY     a failed run leaves the checkpoint and demand_intervals
#               unchanged; the retry finalizes every interval and advances.
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== Demand job quarter-hour schedule assertions (migration 298) ==='

docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_1min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_5min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_daily_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_demand_calculation_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('telemetry.run_environment_daily_job', 0));

-- ===========================================================================
-- S-SCHED / S-KEEP / S-PHASE  (catalog)
-- ===========================================================================
DO $sched$
DECLARE
    r RECORD;
    v_grace interval;
    v_src text := pg_get_functiondef('analytics.run_demand_calculation_job(integer,jsonb)'::regprocedure);
BEGIN
    SELECT j.job_id, j.schedule_interval, j.fixed_schedule, j.initial_start, j.scheduled,
           j.max_runtime, j.max_retries, j.retry_period, j.config,
           j.check_schema, j.check_name, s.next_start, s.last_run_status
    INTO STRICT r
    FROM timescaledb_information.jobs AS j
    LEFT JOIN timescaledb_information.job_stats AS s USING (job_id)
    WHERE j.proc_schema = 'analytics' AND j.proc_name = 'run_demand_calculation_job';

    -- S-SCHED
    IF r.schedule_interval <> INTERVAL '15 minutes' THEN
        RAISE EXCEPTION 'S-SCHED: schedule_interval % <> 15 minutes', r.schedule_interval;
    END IF;
    IF NOT r.fixed_schedule THEN
        RAISE EXCEPTION 'S-SCHED: fixed_schedule is not TRUE';
    END IF;
    IF extract(epoch FROM r.initial_start)::bigint % 900 <> 420 THEN
        RAISE EXCEPTION 'S-SCHED: initial_start % is not a UTC quarter-hour + 7 min', r.initial_start;
    END IF;
    -- A failed run is rescheduled by retry_period, off the grid by design;
    -- otherwise next_start is always a grid slot.
    IF r.next_start IS NOT NULL
       AND r.last_run_status IS DISTINCT FROM 'Failed'
       AND extract(epoch FROM r.next_start)::bigint % 900 <> 420 THEN
        RAISE EXCEPTION 'S-SCHED: next_start % is not a UTC quarter-hour + 7 min', r.next_start;
    END IF;

    -- S-KEEP
    IF r.max_runtime <> INTERVAL '10 minutes' OR r.max_retries <> 3 OR r.retry_period <> INTERVAL '5 minutes' THEN
        RAISE EXCEPTION 'S-KEEP: runtime/retry policy changed (max_runtime %, max_retries %, retry_period %)',
            r.max_runtime, r.max_retries, r.retry_period;
    END IF;
    IF r.retry_period >= r.schedule_interval THEN
        RAISE EXCEPTION 'S-KEEP: retry_period % must be shorter than the schedule %', r.retry_period, r.schedule_interval;
    END IF;
    IF NOT r.scheduled THEN
        RAISE EXCEPTION 'S-KEEP: job is not scheduled';
    END IF;
    IF r.config IS DISTINCT FROM jsonb_build_object(
           'lookback', '3 hours', 'max_catchup_window', '6 hours',
           'overlap', '30 minutes', 'reconcile_window', '6 hours') THEN
        RAISE EXCEPTION 'S-KEEP: config changed: %', r.config;
    END IF;
    IF r.check_schema IS DISTINCT FROM 'config' OR r.check_name IS DISTINCT FROM 'assert_analytical_lookback_job_config' THEN
        RAISE EXCEPTION 'S-KEEP: check_config changed (%.%)', r.check_schema, r.check_name;
    END IF;
    IF position('date_bin(INTERVAL ''15 minutes''' IN v_src) = 0
       OR position('pg_try_advisory_xact_lock' IN v_src) = 0 THEN
        RAISE EXCEPTION 'S-KEEP: run_demand_calculation_job is no longer the watermark-driven wrapper';
    END IF;

    -- S-PHASE
    v_grace := make_interval(secs => COALESCE(
        (SELECT max(late_arrival_tolerance_seconds) FROM config.site_demand_policies WHERE is_enabled), 0) + 300);
    IF v_grace > INTERVAL '7 minutes' THEN
        RAISE EXCEPTION 'S-PHASE: grace % is after the 7-minute phase', v_grace;
    END IF;
    IF date_bin(INTERVAL '15 minutes', TIMESTAMPTZ '2026-10-13 05:07:00+00' - v_grace,
                TIMESTAMPTZ '2000-01-01 00:00:00+00') <> TIMESTAMPTZ '2026-10-13 05:00:00+00' THEN
        RAISE EXCEPTION 'S-PHASE: the 05:07 slot would not finalize the interval ending 05:00';
    END IF;
END
$sched$;

\echo 'PASS: S-SCHED  job 1078 every 15 minutes, fixed schedule on the :07/:22/:37/:52 UTC grid'
\echo 'PASS: S-KEEP   runtime, retries, config, check_config and wrapper unchanged; retry_period < schedule'
\echo 'PASS: S-PHASE  the +7 min slot follows the grace, so it finalizes the interval just ended'

-- ===========================================================================
-- FIXTURE: one org / UTC site / automatic ASSET policy / metered asset with a
-- confirmed asset_points binding; constant 1-minute power up to ~now.
-- ===========================================================================
CREATE TEMP TABLE t298 (k text PRIMARY KEY, u uuid, t timestamptz) ON COMMIT DROP;

DO $fx$
DECLARE
    v_protocol UUID;
    v_lp UUID;
    v_cat UUID;
    v_org UUID; v_site UUID; v_gw UUID; v_asset UUID; v_dev UUID; v_model UUID; v_profile UUID;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_t TIMESTAMPTZ;
BEGIN
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    SELECT id INTO v_lp FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL' LIMIT 1;
    SELECT id INTO v_cat FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    IF v_protocol IS NULL OR v_lp IS NULL OR v_cat IS NULL THEN
        RAISE EXCEPTION 'fixture needs MQTT protocol, ACTIVE_POWER_TOTAL logical point, Energy Meter category';
    END IF;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Demand 298 Test Org', 'DEMAND_298_TEST', 'UTC') RETURNING id INTO v_org;
    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, 'Demand 298 Test Site', 'DEMAND_298_SITE', 'UTC', '{}'::jsonb, TRUE) RETURNING id INTO v_site;
    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Demand 298 GW', 'DEMAND-298-GW') RETURNING id INTO v_gw;
    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Demand 298 Meter', 'Energy Meter', v_cat)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model)) DO UPDATE SET device_type = EXCLUDED.device_type
    RETURNING id INTO v_model;
    INSERT INTO config.device_profiles(protocol_id, profile_code, manufacturer, model, firmware_version,
                                       profile_name, description, is_active)
    VALUES (v_protocol, 'TEST_DEMAND_298', 'WiseWatts Test', 'Demand298', '1',
            'Demand 298 Test', 'Rollback-only demand schedule fixture', TRUE)
    RETURNING id INTO v_profile;
    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required, display_order)
    VALUES (v_profile, 'P', v_lp, FALSE, 10);
    INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, device_model_id, name, external_id, protocol)
    VALUES (v_org, v_gw, v_profile, v_model, 'Demand 298 Meter', 'DEMAND-298-METER', 'MQTT') RETURNING id INTO v_dev;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
    VALUES (v_org, v_site, 'Demand 298 Asset', 'active', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset, v_dev, 'PRIMARY_METER');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (v_asset, v_dev, v_lp, v_org, v_now - INTERVAL '2 days', NULL);

    -- Constant 9.6 kW, one row per minute, from 3 h ago to 1 min ago,
    -- received 5 s after each bucket (well inside the 30 s deadline).
    v_t := date_bin(INTERVAL '1 minute', v_now - INTERVAL '3 hours', TIMESTAMPTZ '2000-01-01 00:00:00+00');
    WHILE v_t < v_now - INTERVAL '1 minute' LOOP
        INSERT INTO telemetry.energy_measurements(
            bucket_start, received_at, source_timestamp,
            organization_id, site_id, gateway_id, device_id, asset_id,
            measurement_interval_seconds, quality_code, is_estimated, active_power_total_w)
        VALUES (v_t, v_t + INTERVAL '5 seconds', v_t, v_org, v_site, v_gw, v_dev, v_asset, 60, 0, FALSE, 9600);
        v_t := v_t + INTERVAL '1 minute';
    END LOOP;

    INSERT INTO t298(k, u) VALUES ('site', v_site), ('asset', v_asset);
END
$fx$;

\echo 'PASS: fixture (UTC site, automatic ASSET policy, metered asset, 3 h of 1-minute source)'

-- helper: the newest quarter-hour the wrapper may finalize right now
CREATE FUNCTION pg_temp.t298_eligible() RETURNS timestamptz LANGUAGE sql AS $f$
    SELECT date_bin(INTERVAL '15 minutes',
                    clock_timestamp() - make_interval(secs => COALESCE(
                        (SELECT max(late_arrival_tolerance_seconds) FROM config.site_demand_policies WHERE is_enabled), 0) + 300),
                    TIMESTAMPTZ '2000-01-01 00:00:00+00');
$f$;

-- helper: count VALID fixture-asset intervals starting in [p_from, p_to)
CREATE FUNCTION pg_temp.t298_valid(p_from timestamptz, p_to timestamptz) RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(*) FROM analytics.demand_intervals
    WHERE asset_id = (SELECT u FROM t298 WHERE k = 'asset')
      AND scope_type = 'ASSET'
      AND interval_start >= p_from AND interval_start < p_to
      AND quality_status = 'VALID';
$f$;

-- ===========================================================================
-- S-CATCHUP  checkpoint one hour behind = three missed 15-minute slots.
-- ===========================================================================
DO $catchup$
DECLARE
    v_before TIMESTAMPTZ := pg_temp.t298_eligible();
    v_ckpt   TIMESTAMPTZ := pg_temp.t298_eligible() - INTERVAL '1 hour';
    v_after_bound TIMESTAMPTZ;
    v_cp TIMESTAMPTZ; v_status TEXT;
    v_n bigint;
BEGIN
    UPDATE telemetry.pipeline_state
       SET last_received_at = v_ckpt, last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'demand_intervals';

    CALL analytics.run_demand_calculation_job(0,
        '{"lookback":"3 hours","max_catchup_window":"6 hours","overlap":"30 minutes","reconcile_window":"6 hours"}'::jsonb);

    v_after_bound := pg_temp.t298_eligible();
    SELECT last_received_at, last_status INTO v_cp, v_status
      FROM telemetry.pipeline_state WHERE pipeline_name = 'demand_intervals';

    -- (the clock may cross a quarter-hour during the CALL; accept either)
    IF v_status <> 'SUCCESS' OR v_cp NOT IN (v_before, v_after_bound) THEN
        RAISE EXCEPTION 'S-CATCHUP: checkpoint % / status % (expected % or %, SUCCESS)', v_cp, v_status, v_before, v_after_bound;
    END IF;
    v_n := pg_temp.t298_valid(v_ckpt, v_cp);
    IF v_n <> extract(epoch FROM (v_cp - v_ckpt))::bigint / 900 THEN
        RAISE EXCEPTION 'S-CATCHUP: % VALID intervals in [%, %), expected %', v_n, v_ckpt, v_cp,
            extract(epoch FROM (v_cp - v_ckpt))::bigint / 900;
    END IF;
    IF v_n < 4 THEN
        RAISE EXCEPTION 'S-CATCHUP: only % intervals caught up (expected >= 4)', v_n;
    END IF;
    INSERT INTO t298(k, t) VALUES ('catchup_ckpt', v_ckpt), ('catchup_to', v_cp);
END
$catchup$;

\echo 'PASS: S-CATCHUP  one run after three missed slots finalizes every missed interval (VALID) and advances the checkpoint'

-- ===========================================================================
-- S-RERUN  a duplicate / retried slot right away changes nothing.
-- ===========================================================================
CREATE FUNCTION pg_temp.t298_sig(p_from timestamptz, p_to timestamptz) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(interval_start::text || '|' || quality_status || '|' || COALESCE(demand_kw::text, '-')
                               || '|' || finalized_at::text, ',' ORDER BY interval_start), '')
    FROM analytics.demand_intervals
    WHERE asset_id = (SELECT u FROM t298 WHERE k = 'asset')
      AND interval_start >= p_from AND interval_start < p_to;
$f$;

DO $rerun$
DECLARE
    v_from TIMESTAMPTZ := (SELECT t FROM t298 WHERE k = 'catchup_ckpt') - INTERVAL '30 minutes';
    v_to   TIMESTAMPTZ := (SELECT t FROM t298 WHERE k = 'catchup_to');
    v_sig_before text := pg_temp.t298_sig(v_from, v_to);
    v_cp TIMESTAMPTZ;
BEGIN
    CALL analytics.run_demand_calculation_job(0,
        '{"lookback":"3 hours","max_catchup_window":"6 hours","overlap":"30 minutes","reconcile_window":"6 hours"}'::jsonb);

    IF pg_temp.t298_sig(v_from, v_to) IS DISTINCT FROM v_sig_before THEN
        RAISE EXCEPTION 'S-RERUN: a duplicate run rewrote finalized intervals';
    END IF;
    SELECT last_received_at INTO v_cp FROM telemetry.pipeline_state WHERE pipeline_name = 'demand_intervals';
    IF v_cp < v_to THEN
        RAISE EXCEPTION 'S-RERUN: checkpoint moved backwards (% -> %)', v_to, v_cp;
    END IF;
    IF pg_temp.t298_eligible() = v_to AND v_cp <> v_to THEN
        RAISE EXCEPTION 'S-RERUN: checkpoint moved on a duplicate run (% -> %)', v_to, v_cp;
    END IF;
END
$rerun$;

\echo 'PASS: S-RERUN  an immediate duplicate run leaves checkpoint, rows and finalized_at unchanged'

-- ===========================================================================
-- S-RETRY  a failed run (injected on the checkpoint write) changes nothing;
--          the retry finalizes every missed interval and advances.
-- ===========================================================================
DO $retry$
DECLARE
    v_ckpt TIMESTAMPTZ := pg_temp.t298_eligible() - INTERVAL '1 hour';
    v_raised BOOLEAN := FALSE;
    v_cp TIMESTAMPTZ; v_status TEXT;
    v_n bigint;
    v_before TIMESTAMPTZ; v_after_bound TIMESTAMPTZ;
BEGIN
    -- forget the fixture's finalized intervals so the retry must recreate them
    DELETE FROM analytics.demand_intervals
     WHERE asset_id = (SELECT u FROM t298 WHERE k = 'asset') AND interval_start >= v_ckpt - INTERVAL '30 minutes';
    UPDATE telemetry.pipeline_state
       SET last_received_at = v_ckpt, last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'demand_intervals';

    CREATE FUNCTION pg_temp.t298_boom() RETURNS trigger LANGUAGE plpgsql AS $b$
    BEGIN
        IF NEW.pipeline_name = 'demand_intervals'
           AND NEW.last_received_at IS DISTINCT FROM OLD.last_received_at THEN
            RAISE EXCEPTION 't298 injected failure on checkpoint advance';
        END IF;
        RETURN NEW;
    END;
    $b$;
    CREATE TRIGGER t298_boom_trg BEFORE UPDATE ON telemetry.pipeline_state
        FOR EACH ROW EXECUTE FUNCTION pg_temp.t298_boom();

    BEGIN
        CALL analytics.run_demand_calculation_job(0,
            '{"lookback":"3 hours","max_catchup_window":"6 hours","overlap":"30 minutes","reconcile_window":"6 hours"}'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
    END;
    DROP TRIGGER t298_boom_trg ON telemetry.pipeline_state;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'S-RETRY: expected the injected failure to propagate';
    END IF;
    SELECT last_received_at INTO v_cp FROM telemetry.pipeline_state WHERE pipeline_name = 'demand_intervals';
    IF v_cp IS DISTINCT FROM v_ckpt THEN
        RAISE EXCEPTION 'S-RETRY: checkpoint moved despite the failure (% -> %)', v_ckpt, v_cp;
    END IF;
    IF pg_temp.t298_valid(v_ckpt - INTERVAL '30 minutes', v_ckpt + INTERVAL '2 hours') <> 0 THEN
        RAISE EXCEPTION 'S-RETRY: the failed run left demand_intervals rows behind';
    END IF;

    -- the retry
    v_before := pg_temp.t298_eligible();
    CALL analytics.run_demand_calculation_job(0,
        '{"lookback":"3 hours","max_catchup_window":"6 hours","overlap":"30 minutes","reconcile_window":"6 hours"}'::jsonb);
    v_after_bound := pg_temp.t298_eligible();
    SELECT last_received_at, last_status INTO v_cp, v_status
      FROM telemetry.pipeline_state WHERE pipeline_name = 'demand_intervals';
    IF v_status <> 'SUCCESS' OR v_cp NOT IN (v_before, v_after_bound) THEN
        RAISE EXCEPTION 'S-RETRY: retry left checkpoint % / status % (expected % or %, SUCCESS)', v_cp, v_status, v_before, v_after_bound;
    END IF;
    v_n := pg_temp.t298_valid(v_ckpt, v_cp);
    IF v_n <> extract(epoch FROM (v_cp - v_ckpt))::bigint / 900 THEN
        RAISE EXCEPTION 'S-RETRY: retry finalized % VALID intervals in [%, %)', v_n, v_ckpt, v_cp;
    END IF;
END
$retry$;

\echo 'PASS: S-RETRY  a failed run changes nothing; the retry finalizes every missed interval and advances'

ROLLBACK;
SQL

printf '%s\n' 'PASS: demand job quarter-hour schedule assertions completed.'
