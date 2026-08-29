#!/usr/bin/env bash
# ============================================================================
# Migration 217 -- hourly forward-window UTC-hour alignment.
#
# Rollback-only. One BEGIN/ROLLBACK transaction. The hourly + 15-minute FORWARD
# advisory keys are held for the whole transaction (re-entrant for this
# session's CALLs) so the TimescaleDB scheduler cannot race the fixtures (same
# guard as assert_energy_consumption_calculated_at_value_aware.sh).
#
# Contract proven (behavioural, not just text):
#   PART 1  STRUCTURAL guardrail: analytics.run_energy_consumption_hourly_job
#           derives v_now_binned / v_parent / v_from / v_to via
#           date_bin(INTERVAL '1 hour', ..., TIMESTAMPTZ '2000-01-01 00:00:00+00')
#           and no longer via date_trunc('hour', clock_timestamp()).
#   PART 2  A legacy OFF-GRID checkpoint (:30 past the UTC hour) fed to ONE call
#           of the procedure yields: (A) a UTC-hour-aligned stored checkpoint;
#           (B) a checkpoint that never skipped an interval and never advanced
#           past the current UTC-hour start; (C) NO energy_consumption_hourly
#           row for the in-progress UTC hour; (D) every produced hourly row =
#           the FULL SUM of its four 15-minute children (no half values);
#           (E) only COMPLETED UTC hours materialised.
#   PART 3  v_parent flooring: while the 15-minute tier has only partially
#           passed a UTC hour, that hour is NOT built; once 15-minute passes the
#           hour end it is built complete.
#   PART 4  Idempotency: a second call with unchanged source does not move the
#           checkpoint, does not re-stamp calculated_at (migration 216), and
#           does not halve an already-complete hourly row.
#   PART 5  First run / NULL checkpoint still lands UTC-hour aligned with
#           complete hours.
#
# => No partial-hour [v_from, v_to) range can be generated: if it could, a
#    produced hour would be short (D), or the in-progress hour would appear (C),
#    or the checkpoint would be off-grid (A).
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"

printf '%s\n' '=== hourly forward-window UTC-hour alignment assertions (migration 217) ==='

psql_f() {
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
        psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test -f -
}

psql_f <<'SQL'
BEGIN;

-- Block the scheduler for the duration (re-entrant for this session's CALLs).
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));

-- ======================================================================
-- PART 1 -- STRUCTURAL guardrail.
-- ======================================================================
DO $t$
DECLARE
    -- whitespace-normalised body so multiline vs single-line assignments match uniformly
    v_def  text := regexp_replace(
                     pg_get_functiondef('analytics.run_energy_consumption_hourly_job(integer,jsonb)'::regprocedure),
                     '\s+', ' ', 'g');
    v_fail text[] := ARRAY[]::text[];
BEGIN
    -- the OLD executable assignment must be gone (match the assignment, not any
    -- prose mention of it -- an explanatory comment may still name it)
    IF position('v_now_binned := date_trunc(' IN v_def) <> 0 THEN
        v_fail := v_fail || 'still has executable  v_now_binned := date_trunc(...)';
    END IF;
    -- the four window-derivation assignments must all be on the UTC hourly grid
    IF position('v_now_binned := date_bin(INTERVAL ''1 hour'', clock_timestamp(), TIMESTAMPTZ ''2000-01-01 00:00:00+00'')' IN v_def) = 0 THEN
        v_fail := v_fail || 'v_now_binned is not date_bin(INTERVAL ''1 hour'', clock_timestamp(), <utc origin>)';
    END IF;
    IF position('v_parent := date_bin( INTERVAL ''1 hour'', (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = ''energy_consumption_15min''), TIMESTAMPTZ ''2000-01-01 00:00:00+00'' )' IN v_def) = 0 THEN
        v_fail := v_fail || 'v_parent is not the 15-minute checkpoint floored to the UTC hour';
    END IF;
    IF position('v_to := date_bin(INTERVAL ''1 hour'', v_to, TIMESTAMPTZ ''2000-01-01 00:00:00+00'')' IN v_def) = 0 THEN
        v_fail := v_fail || 'v_to is not defensively floored to the UTC hour after LEAST()';
    END IF;
    IF position('v_from := date_bin(INTERVAL ''1 hour'', v_start - v_overlap, TIMESTAMPTZ ''2000-01-01 00:00:00+00'')' IN v_def) = 0 THEN
        v_fail := v_fail || 'v_from is not date_bin(INTERVAL ''1 hour'', v_start - v_overlap, <utc origin>)';
    END IF;
    -- unchanged surface
    IF position('pg_try_advisory_xact_lock(hashtextextended(''analytics.run_energy_consumption_hourly_job'', 0))' IN v_def) = 0 THEN
        v_fail := v_fail || 'shared forward advisory key changed/removed';
    END IF;
    IF position('analytics.refresh_energy_consumption_hourly(v_from, v_to)' IN v_def) = 0 THEN
        v_fail := v_fail || 'no longer calls analytics.refresh_energy_consumption_hourly(v_from, v_to)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'analytics' AND p.proname = 'run_energy_consumption_hourly_job'
                     AND p.prosecdef AND p.proconfig IS NOT NULL
                     AND pg_get_userbyid(p.proowner) = 'ems_admin') THEN
        v_fail := v_fail || 'not DEFINER / pinned search_path / owned by ems_admin any more';
    END IF;

    IF array_length(v_fail, 1) > 0 THEN
        RAISE EXCEPTION '1 FAILED: %', array_to_string(v_fail, ' | ');
    END IF;
END;
$t$;
\echo 'PASS: 1  procedure derives the forward window on the UTC hourly grid; old date_trunc gone; advisory key + refresh call + DEFINER surface intact'

-- ======================================================================
-- fixtures
-- ======================================================================
CREATE TEMP TABLE r217 (k text PRIMARY KEY, u uuid) ON COMMIT DROP;
DO $t$
DECLARE v_org uuid := gen_random_uuid(); v_site uuid := gen_random_uuid();
BEGIN
    INSERT INTO metadata.organizations (id, name, code, description, is_active)
    VALUES (v_org, 'M217 tenant', 'M217_TENANT', 'disposable', TRUE);
    INSERT INTO metadata.sites (id, organization_id, name, code, timezone, address, is_active)
    VALUES (v_site, v_org, 'M217 site', 'M217_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE);
    INSERT INTO r217(k,u) VALUES
      ('org', v_org), ('site', v_site),
      ('da', gen_random_uuid()), ('db', gen_random_uuid()), ('dc', gen_random_uuid());
END;
$t$;

-- seed one analytics.energy_consumption_15min row (the CAgg cannot be refreshed
-- in a txn; seed the tier directly -- identical approach to the repo's
-- semantic-contract / calculated_at tests).
CREATE FUNCTION pg_temp.seed15h(p_dev uuid, p_bucket timestamptz, p_sic bigint, p_kwh numeric)
RETURNS void LANGUAGE sql AS $f$
    INSERT INTO analytics.energy_consumption_15min
      (bucket_start, organization_id, site_id, device_id, source_interval_count,
       import_consumption_kwh, export_consumption_kwh, valid_import_intervals, invalid_import_intervals,
       valid_export_intervals, invalid_export_intervals, gap_interval_count, reset_interval_count,
       rollover_interval_count, invalid_interval_count, import_gap_intervals, export_gap_intervals,
       import_reset_intervals, export_reset_intervals, import_rollover_intervals, export_rollover_intervals,
       first_source_bucket, last_source_bucket, calculated_at)
    VALUES
      (p_bucket, (SELECT u FROM r217 WHERE k='org'), (SELECT u FROM r217 WHERE k='site'), p_dev,
       p_sic, p_kwh, 0, p_sic, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
       p_bucket + INTERVAL '1 min', p_bucket + INTERVAL '14 min', p_bucket + INTERVAL '20 min')
    ON CONFLICT (device_id, bucket_start) DO UPDATE SET
       source_interval_count = EXCLUDED.source_interval_count,
       import_consumption_kwh = EXCLUDED.import_consumption_kwh,
       calculated_at = EXCLUDED.calculated_at;
$f$;

-- Seed N whole UTC hours of 15-minute data (four :00/:15/:30/:45 buckets each,
-- sic 15, kwh 0.25 -> whole-hour truth: sic 60, kwh 1.00) ending at the start
-- of the current UTC hour, plus a PARTIAL current UTC hour (two buckets only).
CREATE FUNCTION pg_temp.seed_span(p_dev uuid, p_whole_hours int)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
    v_utc_hour timestamptz := date_bin(INTERVAL '1 hour', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    h int; q int;
BEGIN
    FOR h IN 1 .. p_whole_hours LOOP
        FOR q IN 0 .. 3 LOOP
            PERFORM pg_temp.seed15h(p_dev,
                v_utc_hour - make_interval(hours => h) + make_interval(mins => q * 15),
                15, 0.25);
        END LOOP;
    END LOOP;
    -- current (incomplete) UTC hour: only :00 and :15 present
    PERFORM pg_temp.seed15h(p_dev, v_utc_hour,                       15, 0.25);
    PERFORM pg_temp.seed15h(p_dev, v_utc_hour + INTERVAL '15 min',   15, 0.25);
END;
$f$;

-- ======================================================================
-- PART 2 -- legacy OFF-GRID checkpoint, one call.
-- ======================================================================
DO $t$
DECLARE
    v_dev      uuid := (SELECT u FROM r217 WHERE k='da');
    v_utc_hour timestamptz := date_bin(INTERVAL '1 hour', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_offgrid  timestamptz := v_utc_hour - INTERVAL '4 hours' + INTERVAL '30 minutes';  -- the migration-209 bug shape
    v_ckpt     timestamptz;
    v_bad      bigint;
    v_newest   timestamptz;
BEGIN
    PERFORM pg_temp.seed_span(v_dev, 3);

    -- 15-minute tier has fully passed the current UTC hour start.
    UPDATE telemetry.pipeline_state SET last_received_at = v_utc_hour, last_status = 'SUCCESS'
      WHERE pipeline_name = 'energy_consumption_15min';
    -- hourly checkpoint deliberately OFF the UTC grid (:30 past the hour).
    UPDATE telemetry.pipeline_state SET last_received_at = v_offgrid, last_status = 'SUCCESS'
      WHERE pipeline_name = 'energy_consumption_hourly';

    CALL analytics.run_energy_consumption_hourly_job(0, '{}'::jsonb);

    SELECT last_received_at INTO v_ckpt
      FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_hourly';

    -- A. checkpoint is UTC-hour aligned
    IF v_ckpt IS NULL OR v_ckpt <> date_bin(INTERVAL '1 hour', v_ckpt, TIMESTAMPTZ '2000-01-01 00:00:00+00') THEN
        RAISE EXCEPTION '2/A FAILED: hourly checkpoint % is not UTC-hour aligned', v_ckpt;
    END IF;
    -- B. nothing skipped: checkpoint >= floor(pre-call ckpt), and never past the current UTC-hour start
    IF v_ckpt < date_bin(INTERVAL '1 hour', v_offgrid, TIMESTAMPTZ '2000-01-01 00:00:00+00') THEN
        RAISE EXCEPTION '2/B FAILED: checkpoint % moved BACKWARD past floor(pre-call %) -- interval skipped', v_ckpt, v_offgrid;
    END IF;
    IF v_ckpt > v_utc_hour THEN
        RAISE EXCEPTION '2/B FAILED: checkpoint % advanced past the current UTC-hour start %', v_ckpt, v_utc_hour;
    END IF;
    -- C. the in-progress UTC hour was NOT materialised
    IF EXISTS (SELECT 1 FROM analytics.energy_consumption_hourly
               WHERE device_id = v_dev AND bucket_start >= v_utc_hour) THEN
        RAISE EXCEPTION '2/C FAILED: energy_consumption_hourly row exists for the in-progress UTC hour %', v_utc_hour;
    END IF;
    -- D. every produced hourly row = the FULL SUM of its four 15-minute children
    SELECT count(*) INTO v_bad
    FROM analytics.energy_consumption_hourly h
    JOIN (
        SELECT date_bin(INTERVAL '1 hour', bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS hr,
               sum(source_interval_count) AS s_sic, sum(import_consumption_kwh) AS s_kwh, count(*) AS n
        FROM analytics.energy_consumption_15min
        WHERE device_id = v_dev
        GROUP BY 1
    ) s ON s.hr = h.bucket_start
    WHERE h.device_id = v_dev
      AND (h.source_interval_count IS DISTINCT FROM s.s_sic
           OR h.import_consumption_kwh IS DISTINCT FROM s.s_kwh
           OR s.n <> 4);
    IF v_bad > 0 THEN
        RAISE EXCEPTION '2/D FAILED: % produced hourly row(s) are not the full SUM of 4 fifteen-minute children (partial-hour write)', v_bad;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM analytics.energy_consumption_hourly WHERE device_id = v_dev) THEN
        RAISE EXCEPTION '2/D FAILED: no hourly rows produced at all';
    END IF;
    -- E. only COMPLETED UTC hours materialised
    SELECT max(bucket_start) INTO v_newest FROM analytics.energy_consumption_hourly WHERE device_id = v_dev;
    IF v_newest + INTERVAL '1 hour' > v_ckpt OR v_newest + INTERVAL '1 hour' > v_utc_hour THEN
        RAISE EXCEPTION '2/E FAILED: newest hourly bucket % is not a completed UTC hour (ckpt %, utc_hour %)', v_newest, v_ckpt, v_utc_hour;
    END IF;
END;
$t$;
\echo 'PASS: 2  off-grid legacy checkpoint -> aligned checkpoint, nothing skipped, in-progress hour excluded, every produced hour is the full 4-child SUM'

-- ======================================================================
-- PART 4 -- idempotency (run before PART 3 re-points the 15min checkpoint).
-- ======================================================================
DO $t$
DECLARE
    v_dev   uuid := (SELECT u FROM r217 WHERE k='da');
    v_c1 timestamptz; v_c2 timestamptz;
    v_calc_before timestamptz; v_calc_after timestamptz;
    v_sic bigint;
BEGIN
    SELECT last_received_at INTO v_c1 FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_hourly';
    SELECT max(calculated_at) INTO v_calc_before FROM analytics.energy_consumption_hourly WHERE device_id = v_dev;

    PERFORM pg_sleep(0.02);
    CALL analytics.run_energy_consumption_hourly_job(0, '{}'::jsonb);

    SELECT last_received_at INTO v_c2 FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_hourly';
    SELECT max(calculated_at) INTO v_calc_after FROM analytics.energy_consumption_hourly WHERE device_id = v_dev;
    SELECT min(source_interval_count) INTO v_sic FROM analytics.energy_consumption_hourly WHERE device_id = v_dev;

    IF v_c2 IS DISTINCT FROM v_c1 THEN
        RAISE EXCEPTION '4 FAILED: idempotent re-run moved the checkpoint (% -> %)', v_c1, v_c2;
    END IF;
    IF v_calc_after IS DISTINCT FROM v_calc_before THEN
        RAISE EXCEPTION '4 FAILED: idempotent re-run re-stamped calculated_at (% -> %) -- migration 216 value-aware guard not honoured', v_calc_before, v_calc_after;
    END IF;
    IF v_sic <> 60 THEN
        RAISE EXCEPTION '4 FAILED: an already-complete hourly row was halved by the re-run (source_interval_count = %, expected 60)', v_sic;
    END IF;
END;
$t$;
\echo 'PASS: 4  idempotent re-run: checkpoint unchanged, calculated_at not re-stamped, complete hourly row not halved'

-- ======================================================================
-- PART 3 -- v_parent flooring: a partially-passed UTC hour is not built.
-- ======================================================================
DO $t$
DECLARE
    v_dev      uuid := (SELECT u FROM r217 WHERE k='db');
    v_utc_hour timestamptz := date_bin(INTERVAL '1 hour', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_H        timestamptz := v_utc_hour - INTERVAL '2 hours';   -- a fully-seeded, historical whole UTC hour
    v_ckpt     timestamptz;
BEGIN
    -- full data for hours [v_utc_hour-3h .. v_utc_hour) for this device
    PERFORM pg_temp.seed_span(v_dev, 3);

    -- 15-minute tier has only PARTIALLY passed hour v_H (checkpoint mid-hour).
    UPDATE telemetry.pipeline_state SET last_received_at = v_H + INTERVAL '15 minutes', last_status = 'SUCCESS'
      WHERE pipeline_name = 'energy_consumption_15min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_H - INTERVAL '2 hours', last_status = 'SUCCESS'
      WHERE pipeline_name = 'energy_consumption_hourly';

    CALL analytics.run_energy_consumption_hourly_job(0, '{}'::jsonb);

    SELECT last_received_at INTO v_ckpt FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_hourly';
    IF v_ckpt > v_H THEN
        RAISE EXCEPTION '3 FAILED: checkpoint % advanced into hour % whose 15-minute source had not fully arrived', v_ckpt, v_H;
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.energy_consumption_hourly WHERE device_id = v_dev AND bucket_start = v_H) THEN
        RAISE EXCEPTION '3 FAILED: hour % was built while its 15-minute source was only partially available (partial-child aggregation)', v_H;
    END IF;

    -- now 15-minute passes the end of hour v_H
    UPDATE telemetry.pipeline_state SET last_received_at = v_H + INTERVAL '1 hour 5 minutes', last_status = 'SUCCESS'
      WHERE pipeline_name = 'energy_consumption_15min';
    CALL analytics.run_energy_consumption_hourly_job(0, '{}'::jsonb);

    IF NOT EXISTS (
        SELECT 1 FROM analytics.energy_consumption_hourly
        WHERE device_id = v_dev AND bucket_start = v_H AND source_interval_count = 60
    ) THEN
        RAISE EXCEPTION '3 FAILED: hour % not built complete (sic=60) after 15-minute passed its end', v_H;
    END IF;
    SELECT last_received_at INTO v_ckpt FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_hourly';
    IF v_ckpt < v_H + INTERVAL '1 hour' THEN
        RAISE EXCEPTION '3 FAILED: checkpoint % did not advance past hour end % once source arrived', v_ckpt, v_H + INTERVAL '1 hour';
    END IF;
    IF v_ckpt <> date_bin(INTERVAL '1 hour', v_ckpt, TIMESTAMPTZ '2000-01-01 00:00:00+00') THEN
        RAISE EXCEPTION '3 FAILED: checkpoint % not UTC-hour aligned', v_ckpt;
    END IF;
END;
$t$;
\echo 'PASS: 3  partially-passed UTC hour is deferred, not built from partial children; built complete once 15-minute passes its end'

-- ======================================================================
-- PART 5 -- first run / NULL checkpoint.
-- ======================================================================
DO $t$
DECLARE
    v_dev      uuid := (SELECT u FROM r217 WHERE k='dc');
    v_utc_hour timestamptz := date_bin(INTERVAL '1 hour', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_ckpt     timestamptz;
    v_bad      bigint;
BEGIN
    PERFORM pg_temp.seed_span(v_dev, 3);
    UPDATE telemetry.pipeline_state SET last_received_at = v_utc_hour, last_status = 'SUCCESS'
      WHERE pipeline_name = 'energy_consumption_15min';
    UPDATE telemetry.pipeline_state SET last_received_at = NULL, last_status = 'NEVER_RUN'
      WHERE pipeline_name = 'energy_consumption_hourly';

    CALL analytics.run_energy_consumption_hourly_job(0, '{}'::jsonb);

    SELECT last_received_at INTO v_ckpt FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_hourly';
    IF v_ckpt IS NULL OR v_ckpt <> date_bin(INTERVAL '1 hour', v_ckpt, TIMESTAMPTZ '2000-01-01 00:00:00+00') THEN
        RAISE EXCEPTION '5 FAILED: first-run checkpoint % is null or not UTC-hour aligned', v_ckpt;
    END IF;
    IF v_ckpt > v_utc_hour THEN
        RAISE EXCEPTION '5 FAILED: first-run checkpoint % advanced past the current UTC-hour start %', v_ckpt, v_utc_hour;
    END IF;
    SELECT count(*) INTO v_bad
    FROM analytics.energy_consumption_hourly h
    JOIN (
        SELECT date_bin(INTERVAL '1 hour', bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS hr,
               sum(source_interval_count) AS s_sic, count(*) AS n
        FROM analytics.energy_consumption_15min WHERE device_id = v_dev GROUP BY 1
    ) s ON s.hr = h.bucket_start
    WHERE h.device_id = v_dev AND (h.source_interval_count IS DISTINCT FROM s.s_sic OR s.n <> 4);
    IF v_bad > 0 THEN
        RAISE EXCEPTION '5 FAILED: % first-run hourly row(s) are partial-hour aggregates', v_bad;
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.energy_consumption_hourly WHERE device_id = v_dev AND bucket_start >= v_utc_hour) THEN
        RAISE EXCEPTION '5 FAILED: first run materialised the in-progress UTC hour';
    END IF;
END;
$t$;
\echo 'PASS: 5  first run / NULL checkpoint -> UTC-hour-aligned checkpoint, complete hours only, in-progress hour excluded'

ROLLBACK;
SQL

printf '%s\n' 'OK: migration 217 hourly forward-window UTC-hour alignment assertions passed.'
