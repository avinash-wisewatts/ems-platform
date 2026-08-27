#!/usr/bin/env bash
# ============================================================================
# Migration 211 -- environment_daily child watermark + bounded catch-up.
#
# Rollback-only. Holds the telemetry.run_environment_daily_job advisory lock for
# the whole transaction (re-entrant in this session) so the TimescaleDB
# scheduler cannot race the CALLs, exactly as the 209/210 suites do.
#
# telemetry.refresh_environment_daily is NOT modified by 211; several checks call
# it directly with explicit historical [p_from, p_to) windows to prove the
# unchanged calculation (DST-correct site-local days, partial-day exclusion,
# late-arrival re-finalization, idempotency). The wrapper checks
# (CALL run_environment_daily_job) prove the watermark contract.
#
# Covered:
#   FIXTURE        two sites, distinct IANA timezones (Asia/Kolkata +05:30,
#                  America/New_York with DST); one device each.
#   T-DST-fall     25-hour local day 2025-11-02 America/New_York finalizes to
#                  exactly one row, correct observation_date / bucket_start /
#                  sample_count.
#   T-DST-spring   23-hour local day 2025-03-09 America/New_York, same.
#   T-partial      a local day whose local_day_end > p_to is NOT emitted.
#   T-late         late-arriving environment bucket for an already-finalized
#                  local day is folded in on a re-run over a covering window.
#   T-idem         identical re-run over an unchanged window -> identical
#                  aggregates (calculated_at may churn -- documented).
#   T-WM-first     wrapper first run (checkpoint NULL): advances to
#                  date_bin('1 day', LEAST(LEAST(now-grace, parent), floor+max_catchup)).
#   T-WM-catchup   checkpoint far behind, parent recent -> advance bounded to
#                  date_bin('1 day', checkpoint + max_catchup_window), NOT now-grace.
#   T-WM-stalled   parent not ahead of checkpoint -> no advance, NO_SOURCE_DATA/SUCCESS.
#   T-WM-frontier  finalized local-day starts are all strictly below the watermark.
#   T-WM-fail      failure injected on the checkpoint-advance write -> RAISE
#                  propagates, checkpoint left exactly at its prior value.
#   T-lock         wrapper retains the migration-208 advisory-lock / SKIPPED_LOCKED
#                  / FAILED->RAISE scaffolding + the watermark advance
#                  (live cross-session: assert_analytics_job_self_overlap.sh).
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== environment_daily watermark assertions (migration 211) ==='

docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

-- Block the scheduler for the duration (re-entrant for this session's own CALLs).
SELECT pg_advisory_xact_lock(hashtextextended('telemetry.run_environment_daily_job', 0));

CREATE TEMP TABLE e211 (k text PRIMARY KEY, u uuid, t timestamptz) ON COMMIT DROP;

-- ===========================================================================
-- FIXTURE
-- ===========================================================================
DO $fx$
DECLARE
    v_h TIMESTAMPTZ := date_bin(INTERVAL '1 day', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
BEGIN
    INSERT INTO e211(k,t) VALUES
        ('utc_today', v_h);

    FOR i IN 1..2 LOOP
        DECLARE
            v_tag TEXT := CASE i WHEN 1 THEN 'K' ELSE 'N' END;          -- Kolkata / New_York
            v_tz  TEXT := CASE i WHEN 1 THEN 'Asia/Kolkata' ELSE 'America/New_York' END;
            v_org UUID; v_site UUID; v_gw UUID; v_dev UUID;
        BEGIN
            INSERT INTO metadata.organizations(name, code, timezone)
            VALUES ('Env WM Test Org '||v_tag, 'ENV_WM_TEST_'||v_tag, 'UTC')
            RETURNING id INTO v_org;

            INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
            VALUES (v_org, 'Env WM Test Site '||v_tag, 'ENV_WM_SITE_'||v_tag, v_tz, '{}'::jsonb, TRUE)
            RETURNING id INTO v_site;

            INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
            VALUES (v_org, v_site, 'Env WM GW '||v_tag, 'ENV-WM-GW-'||v_tag)
            RETURNING id INTO v_gw;

            INSERT INTO metadata.devices(organization_id, gateway_id, name, external_id, protocol)
            VALUES (v_org, v_gw, 'Env WM Sensor '||v_tag, 'ENV-WM-DEV-'||v_tag, 'MQTT')
            RETURNING id INTO v_dev;

            INSERT INTO e211(k,u) VALUES
                ('org_'||v_tag, v_org), ('site_'||v_tag, v_site),
                ('gw_'||v_tag, v_gw), ('dev_'||v_tag, v_dev);
        END;
    END LOOP;
END;
$fx$;

\echo 'PASS: fixture (2 sites, Asia/Kolkata + America/New_York, 1 device each)'

-- helper: insert one environment_measurements bucket for a fixture tag
CREATE FUNCTION pg_temp.e211_env(p_tag text, p_bucket timestamptz, p_temp numeric)
RETURNS void LANGUAGE plpgsql AS $h$
BEGIN
    INSERT INTO telemetry.environment_measurements(
        bucket_start, source_timestamp, received_at,
        organization_id, site_id, gateway_id, device_id,
        measurement_interval_seconds, quality_code, is_estimated, temperature_c
    ) VALUES (
        p_bucket, p_bucket, p_bucket + INTERVAL '5 seconds',
        (SELECT u FROM e211 WHERE k='org_'||p_tag),
        (SELECT u FROM e211 WHERE k='site_'||p_tag),
        (SELECT u FROM e211 WHERE k='gw_'||p_tag),
        (SELECT u FROM e211 WHERE k='dev_'||p_tag),
        60, 0, FALSE, p_temp
    );
END;
$h$;

-- ===========================================================================
-- T-DST-fall  25-hour local day 2025-11-02 America/New_York
--   local_day_start(UTC) = 2025-11-02 04:00+00 ; local_day_end(UTC) = 2025-11-03 05:00+00
-- ===========================================================================
DO $tdf$
DECLARE
    v_dev UUID := (SELECT u FROM e211 WHERE k='dev_N');
    v_cnt INT; v_obsdate DATE; v_bs TIMESTAMPTZ; v_samples BIGINT;
BEGIN
    PERFORM pg_temp.e211_env('N', TIMESTAMPTZ '2025-11-02 06:00:00+00', 10);
    PERFORM pg_temp.e211_env('N', TIMESTAMPTZ '2025-11-02 12:00:00+00', 12);
    PERFORM pg_temp.e211_env('N', TIMESTAMPTZ '2025-11-02 18:00:00+00', 14);
    PERFORM pg_temp.e211_env('N', TIMESTAMPTZ '2025-11-03 00:00:00+00', 11);
    PERFORM pg_temp.e211_env('N', TIMESTAMPTZ '2025-11-03 04:00:00+00', 9);   -- < 05:00 -> still Nov 2 local

    PERFORM telemetry.refresh_environment_daily(
        TIMESTAMPTZ '2025-11-01 00:00:00+00', TIMESTAMPTZ '2025-11-04 00:00:00+00');

    SELECT count(*), max(observation_date), max(bucket_start), max(sample_count)
      INTO v_cnt, v_obsdate, v_bs, v_samples
      FROM telemetry.environment_daily WHERE device_id = v_dev;

    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'T-DST-fall: expected exactly 1 daily row, got %', v_cnt;
    END IF;
    IF v_obsdate <> DATE '2025-11-02' THEN
        RAISE EXCEPTION 'T-DST-fall: observation_date % (expected 2025-11-02)', v_obsdate;
    END IF;
    IF v_bs <> TIMESTAMPTZ '2025-11-02 04:00:00+00' THEN
        RAISE EXCEPTION 'T-DST-fall: bucket_start % (expected 2025-11-02 04:00:00+00 = NY local midnight)', v_bs;
    END IF;
    IF v_samples <> 5 THEN
        RAISE EXCEPTION 'T-DST-fall: sample_count % (expected 5 -- all 5 buckets in the 25h local day)', v_samples;
    END IF;
END;
$tdf$;

\echo 'PASS: T-DST-fall  25h DST local day -> one row, correct date/bucket_start/sample_count'

-- ===========================================================================
-- T-DST-spring  23-hour local day 2025-03-09 America/New_York
--   local_day_start(UTC) = 2025-03-09 05:00+00 ; local_day_end(UTC) = 2025-03-10 04:00+00
-- ===========================================================================
DO $tds$
DECLARE
    v_dev UUID := (SELECT u FROM e211 WHERE k='dev_N');
    v_row RECORD;
BEGIN
    PERFORM pg_temp.e211_env('N', TIMESTAMPTZ '2025-03-09 06:00:00+00', 5);
    PERFORM pg_temp.e211_env('N', TIMESTAMPTZ '2025-03-09 15:00:00+00', 7);
    PERFORM pg_temp.e211_env('N', TIMESTAMPTZ '2025-03-10 03:00:00+00', 6);   -- < 04:00 -> still Mar 9 local

    PERFORM telemetry.refresh_environment_daily(
        TIMESTAMPTZ '2025-03-08 00:00:00+00', TIMESTAMPTZ '2025-03-11 00:00:00+00');

    SELECT observation_date, bucket_start, sample_count INTO v_row
      FROM telemetry.environment_daily
     WHERE device_id = v_dev AND observation_date = DATE '2025-03-09';

    IF v_row IS NULL THEN
        RAISE EXCEPTION 'T-DST-spring: no row for 2025-03-09';
    END IF;
    IF v_row.bucket_start <> TIMESTAMPTZ '2025-03-09 05:00:00+00' THEN
        RAISE EXCEPTION 'T-DST-spring: bucket_start % (expected 2025-03-09 05:00:00+00)', v_row.bucket_start;
    END IF;
    IF v_row.sample_count <> 3 THEN
        RAISE EXCEPTION 'T-DST-spring: sample_count % (expected 3)', v_row.sample_count;
    END IF;
END;
$tds$;

\echo 'PASS: T-DST-spring  23h DST local day -> correct date/bucket_start/sample_count'

-- ===========================================================================
-- T-partial  a local day whose local_day_end > p_to is NOT emitted.
-- Kolkata (+05:30): local day 2025-06-10 ends 2025-06-10 18:30+00.
-- Call with p_to = 2025-06-10 12:00+00  (< local_day_end) -> no row.
-- ===========================================================================
DO $tp$
DECLARE
    v_dev UUID := (SELECT u FROM e211 WHERE k='dev_K');
    v_cnt INT;
BEGIN
    PERFORM pg_temp.e211_env('K', TIMESTAMPTZ '2025-06-10 02:00:00+00', 25);
    PERFORM pg_temp.e211_env('K', TIMESTAMPTZ '2025-06-10 08:00:00+00', 27);

    PERFORM telemetry.refresh_environment_daily(
        TIMESTAMPTZ '2025-06-09 00:00:00+00', TIMESTAMPTZ '2025-06-10 12:00:00+00');

    SELECT count(*) INTO v_cnt
      FROM telemetry.environment_daily
     WHERE device_id = v_dev AND observation_date = DATE '2025-06-10';
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION 'T-partial: incomplete local day 2025-06-10 was emitted (% rows)', v_cnt;
    END IF;

    -- now extend the window past local_day_end -> it appears
    PERFORM telemetry.refresh_environment_daily(
        TIMESTAMPTZ '2025-06-09 00:00:00+00', TIMESTAMPTZ '2025-06-11 00:00:00+00');
    SELECT count(*) INTO v_cnt
      FROM telemetry.environment_daily
     WHERE device_id = v_dev AND observation_date = DATE '2025-06-10';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'T-partial: complete local day 2025-06-10 not emitted after window covers its end (% rows)', v_cnt;
    END IF;
END;
$tp$;

\echo 'PASS: T-partial  incomplete local day excluded; emitted once window covers local_day_end'

-- ===========================================================================
-- T-late  late-arriving bucket for an already-finalized local day is folded in
-- on a re-run over a covering window.
-- ===========================================================================
DO $tl$
DECLARE
    v_dev UUID := (SELECT u FROM e211 WHERE k='dev_K');
    v_samples_1 BIGINT; v_samples_2 BIGINT; v_avg_1 DOUBLE PRECISION; v_avg_2 DOUBLE PRECISION;
BEGIN
    SELECT sample_count, temperature_c_avg INTO v_samples_1, v_avg_1
      FROM telemetry.environment_daily
     WHERE device_id = v_dev AND observation_date = DATE '2025-06-10';

    -- a late bucket lands for that same local day
    PERFORM pg_temp.e211_env('K', TIMESTAMPTZ '2025-06-10 15:00:00+00', 40);

    PERFORM telemetry.refresh_environment_daily(
        TIMESTAMPTZ '2025-06-09 00:00:00+00', TIMESTAMPTZ '2025-06-11 00:00:00+00');

    SELECT sample_count, temperature_c_avg INTO v_samples_2, v_avg_2
      FROM telemetry.environment_daily
     WHERE device_id = v_dev AND observation_date = DATE '2025-06-10';

    IF v_samples_2 <> v_samples_1 + 1 THEN
        RAISE EXCEPTION 'T-late: sample_count did not pick up the late bucket (% -> %)', v_samples_1, v_samples_2;
    END IF;
    IF v_avg_2 IS NOT DISTINCT FROM v_avg_1 THEN
        RAISE EXCEPTION 'T-late: temperature_c_avg unchanged after a late 40C bucket (% -> %)', v_avg_1, v_avg_2;
    END IF;
END;
$tl$;

\echo 'PASS: T-late  late-arriving bucket re-folded into an already-finalized local day'

-- ===========================================================================
-- T-idem  identical re-run over an unchanged window -> identical aggregates.
-- ===========================================================================
DO $ti$
DECLARE
    v_dev UUID := (SELECT u FROM e211 WHERE k='dev_K');
    v_before TEXT; v_after TEXT;
BEGIN
    SELECT sample_count||'|'||temperature_c_avg||'|'||temperature_c_min||'|'||temperature_c_max
      INTO v_before
      FROM telemetry.environment_daily
     WHERE device_id = v_dev AND observation_date = DATE '2025-06-10';

    PERFORM telemetry.refresh_environment_daily(
        TIMESTAMPTZ '2025-06-09 00:00:00+00', TIMESTAMPTZ '2025-06-11 00:00:00+00');

    SELECT sample_count||'|'||temperature_c_avg||'|'||temperature_c_min||'|'||temperature_c_max
      INTO v_after
      FROM telemetry.environment_daily
     WHERE device_id = v_dev AND observation_date = DATE '2025-06-10';

    IF v_after IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'T-idem: aggregates changed on an unchanged re-run (% -> %)', v_before, v_after;
    END IF;
END;
$ti$;

\echo 'PASS: T-idem  unchanged re-run -> identical aggregates (calculated_at churn is expected/unguarded)'

-- ===========================================================================
-- Wrapper watermark-contract tests. Use now()-relative fixtures; expected v_to
-- is computed with the SAME formula the wrapper uses.
-- ===========================================================================

-- ---- T-WM-first : checkpoint NULL -> advance to date_bin('1 day', LEAST(LEAST(now-grace, parent), floor+max_catchup))
DO $twf$
DECLARE
    v_h    TIMESTAMPTZ := (SELECT t FROM e211 WHERE k='utc_today');
    v_grace INTERVAL;
    v_avail TIMESTAMPTZ;
    v_start TIMESTAMPTZ;
    v_expect TIMESTAMPTZ;
    v_after TIMESTAMPTZ; v_status TEXT;
BEGIN
    DELETE FROM telemetry.environment_measurements
     WHERE site_id IN (SELECT u FROM e211 WHERE k IN ('site_K','site_N'));
    -- single recent parent marker at h - 2 days
    PERFORM pg_temp.e211_env('K', v_h - INTERVAL '2 days' + INTERVAL '6 hours', 20);

    UPDATE telemetry.pipeline_state
       SET last_received_at = NULL, last_status = 'NEVER_RUN', last_error = NULL
     WHERE pipeline_name = 'environment_daily';

    v_grace := make_interval(secs =>
          COALESCE((SELECT max(late_arrival_tolerance_seconds) FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + COALESCE((SELECT max(capture_interval_seconds)        FROM config.telemetry_capture_policies WHERE is_enabled), 900)
        + 300);
    SELECT max(bucket_start) INTO v_avail FROM telemetry.environment_measurements;
    v_start  := clock_timestamp() - INTERVAL '8 days';
    v_expect := date_bin(INTERVAL '1 day',
                  LEAST(LEAST(clock_timestamp() - v_grace, v_avail), v_start + INTERVAL '2 days'),
                  TIMESTAMPTZ '2000-01-01 00:00:00+00');

    CALL telemetry.run_environment_daily_job(0,
        '{"lookback":"8 days","max_catchup_window":"2 days","overlap":"1 day","reconcile_window":"35 days"}'::jsonb);

    SELECT last_received_at, last_status INTO v_after, v_status
      FROM telemetry.pipeline_state WHERE pipeline_name='environment_daily';

    IF v_after IS DISTINCT FROM v_expect THEN
        RAISE EXCEPTION 'T-WM-first: checkpoint % <> expected %', v_after, v_expect;
    END IF;
    IF v_status NOT IN ('SUCCESS','NO_SOURCE_DATA') THEN
        RAISE EXCEPTION 'T-WM-first: unexpected status %', v_status;
    END IF;
END;
$twf$;

\echo 'PASS: T-WM-first  first run advances to date_bin(1 day, LEAST(LEAST(now-grace, parent), floor+max_catchup))'

-- ---- T-WM-catchup : checkpoint 10d behind, parent recent -> bounded to checkpoint + 2 days
DO $twc$
DECLARE
    v_h TIMESTAMPTZ := (SELECT t FROM e211 WHERE k='utc_today');
    v_ckpt TIMESTAMPTZ := (SELECT t FROM e211 WHERE k='utc_today') - INTERVAL '10 days';
    v_expect TIMESTAMPTZ; v_after TIMESTAMPTZ;
BEGIN
    DELETE FROM telemetry.environment_measurements
     WHERE site_id IN (SELECT u FROM e211 WHERE k IN ('site_K','site_N'));
    PERFORM pg_temp.e211_env('K', v_h - INTERVAL '2 hours', 21);   -- parent very recent

    UPDATE telemetry.pipeline_state
       SET last_received_at = v_ckpt, last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'environment_daily';

    v_expect := date_bin(INTERVAL '1 day', v_ckpt + INTERVAL '2 days', TIMESTAMPTZ '2000-01-01 00:00:00+00');

    CALL telemetry.run_environment_daily_job(0,
        '{"lookback":"8 days","max_catchup_window":"2 days","overlap":"1 day","reconcile_window":"35 days"}'::jsonb);

    SELECT last_received_at INTO v_after
      FROM telemetry.pipeline_state WHERE pipeline_name='environment_daily';

    IF v_after IS DISTINCT FROM v_expect THEN
        RAISE EXCEPTION 'T-WM-catchup: checkpoint % <> ckpt+max_catchup %', v_after, v_expect;
    END IF;
    IF v_after >= date_bin(INTERVAL '1 day', v_h - INTERVAL '1 day', TIMESTAMPTZ '2000-01-01 00:00:00+00') THEN
        RAISE EXCEPTION 'T-WM-catchup: advance not bounded -- reached % (parent was ~now)', v_after;
    END IF;
END;
$twc$;

\echo 'PASS: T-WM-catchup  per-run advance bounded to checkpoint + max_catchup_window'

-- ---- T-WM-stalled : parent not ahead of checkpoint -> no advance
DO $tws$
DECLARE
    v_h TIMESTAMPTZ := (SELECT t FROM e211 WHERE k='utc_today');
    v_ckpt TIMESTAMPTZ := (SELECT t FROM e211 WHERE k='utc_today') - INTERVAL '3 days';
    v_after TIMESTAMPTZ; v_status TEXT;
BEGIN
    DELETE FROM telemetry.environment_measurements
     WHERE site_id IN (SELECT u FROM e211 WHERE k IN ('site_K','site_N'));
    -- newest parent bucket is INSIDE the already-processed region (day before ckpt)
    PERFORM pg_temp.e211_env('K', v_ckpt - INTERVAL '6 hours', 19);

    UPDATE telemetry.pipeline_state
       SET last_received_at = v_ckpt, last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'environment_daily';

    CALL telemetry.run_environment_daily_job(0,
        '{"lookback":"8 days","max_catchup_window":"2 days","overlap":"1 day","reconcile_window":"35 days"}'::jsonb);

    SELECT last_received_at, last_status INTO v_after, v_status
      FROM telemetry.pipeline_state WHERE pipeline_name='environment_daily';

    IF v_after IS DISTINCT FROM v_ckpt THEN
        RAISE EXCEPTION 'T-WM-stalled: checkpoint advanced with no new parent data (% -> %)', v_ckpt, v_after;
    END IF;
    IF v_status NOT IN ('SUCCESS','NO_SOURCE_DATA') THEN
        RAISE EXCEPTION 'T-WM-stalled: unexpected status %', v_status;
    END IF;
END;
$tws$;

\echo 'PASS: T-WM-stalled  parent not advancing -> checkpoint not advanced'

-- ---- T-WM-frontier : every finalized local-day start is strictly below the watermark
DO $twn$
DECLARE
    v_h TIMESTAMPTZ := (SELECT t FROM e211 WHERE k='utc_today');
    v_wm TIMESTAMPTZ; v_maxbs TIMESTAMPTZ;
BEGIN
    DELETE FROM telemetry.environment_measurements
     WHERE site_id IN (SELECT u FROM e211 WHERE k IN ('site_K','site_N'));
    DELETE FROM telemetry.environment_daily
     WHERE site_id IN (SELECT u FROM e211 WHERE k IN ('site_K','site_N'));
    -- continuous daily data for both sites over the last ~6 days
    FOR d IN 1..6 LOOP
        PERFORM pg_temp.e211_env('K', v_h - make_interval(days => d) + INTERVAL '3 hours', 20 + d);
        PERFORM pg_temp.e211_env('K', v_h - make_interval(days => d) + INTERVAL '15 hours', 22 + d);
        PERFORM pg_temp.e211_env('N', v_h - make_interval(days => d) + INTERVAL '9 hours', 10 + d);
    END LOOP;

    UPDATE telemetry.pipeline_state
       SET last_received_at = v_h - INTERVAL '6 days', last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'environment_daily';

    -- two runs to drain the bounded catch-up
    CALL telemetry.run_environment_daily_job(0, '{"max_catchup_window":"2 days","overlap":"1 day"}'::jsonb);
    CALL telemetry.run_environment_daily_job(0, '{"max_catchup_window":"2 days","overlap":"1 day"}'::jsonb);
    CALL telemetry.run_environment_daily_job(0, '{"max_catchup_window":"2 days","overlap":"1 day"}'::jsonb);

    SELECT last_received_at INTO v_wm FROM telemetry.pipeline_state WHERE pipeline_name='environment_daily';
    SELECT max(bucket_start) INTO v_maxbs FROM telemetry.environment_daily
      WHERE site_id IN (SELECT u FROM e211 WHERE k IN ('site_K','site_N'));

    IF v_maxbs IS NOT NULL AND v_maxbs >= v_wm THEN
        RAISE EXCEPTION 'T-WM-frontier: a finalized local-day start (%) is at/after the watermark (%)', v_maxbs, v_wm;
    END IF;
END;
$twn$;

\echo 'PASS: T-WM-frontier  every finalized local-day start is strictly below the watermark'

-- ---- T-WM-fail : failure on the checkpoint-advance write -> RAISE propagates, checkpoint intact
DO $twx$
DECLARE
    v_h TIMESTAMPTZ := (SELECT t FROM e211 WHERE k='utc_today');
    v_ckpt TIMESTAMPTZ := (SELECT t FROM e211 WHERE k='utc_today') - INTERVAL '3 days';
    v_after TIMESTAMPTZ; v_raised BOOLEAN := FALSE;
BEGIN
    DELETE FROM telemetry.environment_measurements
     WHERE site_id IN (SELECT u FROM e211 WHERE k IN ('site_K','site_N'));
    PERFORM pg_temp.e211_env('K', v_h - INTERVAL '12 hours', 20);   -- recent -> a real advance would occur

    UPDATE telemetry.pipeline_state
       SET last_received_at = v_ckpt, last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'environment_daily';

    CREATE FUNCTION pg_temp.e211_boom() RETURNS trigger LANGUAGE plpgsql AS $b$
    BEGIN
        IF NEW.pipeline_name = 'environment_daily'
           AND NEW.last_received_at IS DISTINCT FROM OLD.last_received_at THEN
            RAISE EXCEPTION 'e211 injected failure on checkpoint advance';
        END IF;
        RETURN NEW;
    END;
    $b$;
    CREATE TRIGGER e211_boom_trg BEFORE UPDATE ON telemetry.pipeline_state
        FOR EACH ROW EXECUTE FUNCTION pg_temp.e211_boom();

    BEGIN
        CALL telemetry.run_environment_daily_job(0, '{"max_catchup_window":"2 days","overlap":"1 day"}'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
    END;

    DROP TRIGGER e211_boom_trg ON telemetry.pipeline_state;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'T-WM-fail: expected the injected failure to propagate';
    END IF;
    SELECT last_received_at INTO v_after FROM telemetry.pipeline_state WHERE pipeline_name='environment_daily';
    IF v_after IS DISTINCT FROM v_ckpt THEN
        RAISE EXCEPTION 'T-WM-fail: checkpoint moved despite failure (% -> %)', v_ckpt, v_after;
    END IF;
END;
$twx$;

\echo 'PASS: T-WM-fail  failure on advance -> RAISE propagates, checkpoint intact'

-- ---- T-lock : wrapper retains the migration-208 concurrency scaffolding + watermark advance
DO $tk$
DECLARE
    v_src TEXT := pg_get_functiondef('telemetry.run_environment_daily_job(integer,jsonb)'::regprocedure);
BEGIN
    IF position('pg_try_advisory_xact_lock(' IN v_src) = 0
       OR position('hashtextextended(''telemetry.run_environment_daily_job''' IN v_src) = 0 THEN
        RAISE EXCEPTION 'T-lock: advisory self-overlap lock missing';
    END IF;
    IF position('SKIPPED_LOCKED' IN v_src) = 0 THEN
        RAISE EXCEPTION 'T-lock: SKIPPED_LOCKED path missing';
    END IF;
    IF position('''FAILED''' IN v_src) = 0 OR position('RAISE;' IN v_src) = 0 THEN
        RAISE EXCEPTION 'T-lock: EXCEPTION -> FAILED -> RAISE path missing';
    END IF;
    IF position('last_received_at   = v_to' IN v_src) = 0 THEN
        RAISE EXCEPTION 'T-lock: watermark advance (last_received_at = v_to) missing';
    END IF;
    IF position('ca_environment' IN v_src) <> 0 THEN
        RAISE EXCEPTION 'T-lock: wrapper must NOT reference a ca_environment_* CAGG';
    END IF;
    IF position('max(bucket_start)' IN v_src) = 0
       OR position('environment_measurements' IN v_src) = 0 THEN
        RAISE EXCEPTION 'T-lock: parent availability must be max(environment_measurements.bucket_start)';
    END IF;
END;
$tk$;

\echo 'PASS: T-lock  wrapper retains advisory-lock / SKIPPED_LOCKED / FAILED->RAISE + real-source parent + watermark advance'

ROLLBACK;
SQL

printf '%s\n' 'PASS: environment_daily watermark assertions completed.'
