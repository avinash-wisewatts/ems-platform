-- ============================================================================
-- MVP-7 Basic Alerts -- live-execution lifecycle test for migration 242
-- (ADR-016 section 4/7 amendment, 2026-09-15): data-unavailable-while-
-- Active flagging and the recovery-while-still-material -> Ended -> fresh
-- qualification -> new Active transition (Option B).
--
-- Exercises the REAL analytics.run_alert_evaluation_job(1, '{}'::jsonb) ->
-- analytics.evaluate_alerts() path against a real TimescaleDB instance --
-- the static contract test (test_mvp7_alert_data_unavailable_lifecycle_
-- contract.py) can only prove the source text has the right shape, not
-- that the new branches actually fire correctly in order.
--
-- IMPORTANT: analytics.evaluate_alerts() COMMITs internally (per-site and
-- retention). It cannot be called inside an explicit client transaction
-- block. Every fixture statement below is a plain, top-level (autocommitting)
-- statement -- never BEGIN/ROLLBACK -- matching
-- assert_mvp7_alert_evaluation_job_executes.sql's established pattern.
-- Cleanup is explicit DELETEs at the end, verified, not a rollback.
--
-- Scenario 1 (main path): current-day + 5 identical eligible historical
-- days seeded material (130 vs typical 100, +30% -- comfortably past the
-- threshold, no float-boundary ambiguity) -> qualifies (backdated timer)
-- -> Active -> historical day deleted (data unavailable) -> flagged, stays
-- Active -> historical day restored, still material -> old alert ENDED
-- (DATA_UNAVAILABLE) -> fresh candidate -> backdated timer -> NEW, distinct
-- alert becomes Active.
--
-- Scenario 2 (negative/guard): same setup, but on "recovery" the current
-- value is changed to NOT material (105 vs 100, +5%) -- must NOT force an
-- Ended; must proceed to the normal WATCHING_CLEAR resolution path instead.
-- ============================================================================

\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Fixtures -- deterministic IDs, two isolated sites (scenario 1 and 2).
-- ----------------------------------------------------------------------------
INSERT INTO metadata.organizations (id, name, code) VALUES
  ('00000000-0000-0000-0000-0000000242a1', 'MVP7 Data-Unavailable Lifecycle Org', 'MVP7_DATAUNAVAIL_ORG');
INSERT INTO metadata.sites (id, organization_id, name, code, timezone) VALUES
  ('00000000-0000-0000-0000-0000000242a2', '00000000-0000-0000-0000-0000000242a1', 'MVP7 Data-Unavailable Site 1', 'MVP7_DATAUNAVAIL_SITE_1', 'UTC'),
  ('00000000-0000-0000-0000-0000000242a3', '00000000-0000-0000-0000-0000000242a1', 'MVP7 Data-Unavailable Site 2', 'MVP7_DATAUNAVAIL_SITE_2', 'UTC');

-- Seeds 5 identical eligible historical comparable-day rows (median of 5
-- identical values = that value exactly, sidesteps windowing ambiguity --
-- same technique as assert_energy_attention_materiality_parity.sql) plus a
-- current-day row, for the given site, relative to REAL current time (the
-- procedure uses clock_timestamp() internally -- no as_of override exists).
CREATE OR REPLACE FUNCTION pg_temp.seed_lifecycle_case(p_site_id UUID, p_current_kwh NUMERIC, p_typical_kwh NUMERIC)
RETURNS VOID
LANGUAGE plpgsql
AS $body$
DECLARE
    v_org_id UUID;
    v_eval_date DATE := (now() AT TIME ZONE 'UTC')::DATE - 1;
    v_k INT;
BEGIN
    SELECT organization_id INTO v_org_id FROM metadata.sites WHERE id = p_site_id;

    INSERT INTO analytics.energy_consumption_daily
    (bucket_start, consumption_date, site_timezone, organization_id, site_id, device_id,
     source_interval_count, import_consumption_kwh, export_consumption_kwh,
     valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
     gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count)
    VALUES
    (v_eval_date::TIMESTAMP AT TIME ZONE 'UTC', v_eval_date, 'UTC', v_org_id, p_site_id, gen_random_uuid(),
     100, p_current_kwh, 0, 100, 0, 100, 0, 0, 0, 0, 0);

    FOR v_k IN 1..5 LOOP
        INSERT INTO analytics.energy_consumption_daily
        (bucket_start, consumption_date, site_timezone, organization_id, site_id, device_id,
         source_interval_count, import_consumption_kwh, export_consumption_kwh,
         valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
         gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count)
        VALUES
        ((v_eval_date - (v_k * 7))::TIMESTAMP AT TIME ZONE 'UTC', v_eval_date - (v_k * 7), 'UTC', v_org_id, p_site_id, gen_random_uuid(),
         100, p_typical_kwh, 0, 100, 0, 100, 0, 0, 0, 0, 0);
    END LOOP;
END;
$body$;

-- ============================================================================
-- SCENARIO 1: qualify -> Active -> data unavailable -> recover (still
-- material) -> old alert ENDED (DATA_UNAVAILABLE) -> fresh qualify -> new
-- Active.
-- ============================================================================

\echo '[mvp7-data-unavail] Scenario 1 step 1: seed material data (130 vs typical 100) and run the job to create a WATCHING_TRIGGER candidate'
SELECT pg_temp.seed_lifecycle_case('00000000-0000-0000-0000-0000000242a2'::UUID, 130, 100);
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);

DO $verify1$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM analytics.alert_evaluation_candidates
        WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND watch_state = 'WATCHING_TRIGGER'
    ) THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 1): expected a WATCHING_TRIGGER candidate, found none';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.alerts WHERE site_id = '00000000-0000-0000-0000-0000000242a2') THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 1): an alert already exists before qualification';
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Scenario 1 step 1 PASSED';
END;
$verify1$;

\echo '[mvp7-data-unavail] Scenario 1 step 2: backdate the candidate past the 5-minute qualification window and run the job again'
UPDATE analytics.alert_evaluation_candidates
SET since = now() - INTERVAL '6 minutes', last_evaluated_at = now()
WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND watch_state = 'WATCHING_TRIGGER';
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);

DO $verify2$
DECLARE
    v_alert_id UUID;
BEGIN
    SELECT alert_id INTO v_alert_id FROM analytics.alerts
    WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND state = 'ACTIVE';
    IF v_alert_id IS NULL THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 2): expected exactly one Active alert after qualification, found none';
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Scenario 1 step 2 PASSED -- Active alert % created', v_alert_id;
END;
$verify2$;

\echo '[mvp7-data-unavail] Scenario 1 step 3: remove the current-day data (data becomes unavailable) and run the job'
DELETE FROM analytics.energy_consumption_daily
WHERE site_id = '00000000-0000-0000-0000-0000000242a2'
  AND consumption_date = ((now() AT TIME ZONE 'UTC')::DATE - 1);
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);

DO $verify3$
DECLARE
    v_state TEXT;
    v_data_unavailable BOOLEAN;
BEGIN
    SELECT state, data_unavailable INTO v_state, v_data_unavailable
    FROM analytics.alerts
    WHERE site_id = '00000000-0000-0000-0000-0000000242a2'
    ORDER BY triggered_at DESC LIMIT 1;
    IF v_state IS DISTINCT FROM 'ACTIVE' THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 3): expected state=ACTIVE (unchanged during the gap), got %', v_state;
    END IF;
    IF v_data_unavailable IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 3): expected data_unavailable=TRUE, got %', v_data_unavailable;
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Scenario 1 step 3 PASSED -- Active alert flagged data_unavailable=TRUE, state unchanged';
END;
$verify3$;

\echo '[mvp7-data-unavail] Scenario 1 step 4: restore current-day data, still material -- run the job -- old alert must End, not continue'
INSERT INTO analytics.energy_consumption_daily
(bucket_start, consumption_date, site_timezone, organization_id, site_id, device_id,
 source_interval_count, import_consumption_kwh, export_consumption_kwh,
 valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
 gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count)
SELECT
    ((now() AT TIME ZONE 'UTC')::DATE - 1)::TIMESTAMP AT TIME ZONE 'UTC', (now() AT TIME ZONE 'UTC')::DATE - 1, 'UTC',
    organization_id, '00000000-0000-0000-0000-0000000242a2'::UUID, gen_random_uuid(),
    100, 130, 0, 100, 0, 100, 0, 0, 0, 0, 0
FROM metadata.sites WHERE id = '00000000-0000-0000-0000-0000000242a2';

CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);

DO $verify4$
DECLARE
    v_old_alert_id UUID;
    v_old_state TEXT;
    v_old_reason_code TEXT;
    v_old_data_unavailable BOOLEAN;
BEGIN
    SELECT alert_id, state, ended_reason_code, data_unavailable
    INTO v_old_alert_id, v_old_state, v_old_reason_code, v_old_data_unavailable
    FROM analytics.alerts
    WHERE site_id = '00000000-0000-0000-0000-0000000242a2'
    ORDER BY triggered_at ASC LIMIT 1;

    IF v_old_state IS DISTINCT FROM 'ENDED' THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 4): expected the original alert to be ENDED, got %', v_old_state;
    END IF;
    IF v_old_reason_code IS DISTINCT FROM 'DATA_UNAVAILABLE' THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 4): expected ended_reason_code=DATA_UNAVAILABLE, got %', v_old_reason_code;
    END IF;
    IF v_old_data_unavailable IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 4): expected data_unavailable=FALSE on the now-terminal row, got %', v_old_data_unavailable;
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.alerts WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND state = 'ACTIVE') THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 4): the old alert must not simply continue -- no Active alert should exist yet (fresh qualification required)';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM analytics.alert_evaluation_candidates
        WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND watch_state = 'WATCHING_TRIGGER'
    ) THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 4): expected a fresh WATCHING_TRIGGER candidate, found none';
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Scenario 1 step 4 PASSED -- old alert % Ended (DATA_UNAVAILABLE), fresh qualification started', v_old_alert_id;
END;
$verify4$;

\echo '[mvp7-data-unavail] Scenario 1 step 5: backdate the fresh candidate past 5 minutes and run the job -- a NEW, distinct alert must become Active'
UPDATE analytics.alert_evaluation_candidates
SET since = now() - INTERVAL '6 minutes', last_evaluated_at = now()
WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND watch_state = 'WATCHING_TRIGGER';
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);

DO $verify5$
DECLARE
    v_new_alert_id UUID;
    v_old_alert_id UUID;
    v_active_count INT;
BEGIN
    SELECT alert_id INTO v_old_alert_id FROM analytics.alerts
    WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND state = 'ENDED';
    SELECT alert_id INTO v_new_alert_id FROM analytics.alerts
    WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND state = 'ACTIVE';
    SELECT count(*) INTO v_active_count FROM analytics.alerts
    WHERE site_id = '00000000-0000-0000-0000-0000000242a2' AND state = 'ACTIVE';

    IF v_new_alert_id IS NULL THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 5): expected a new Active alert, found none';
    END IF;
    IF v_active_count <> 1 THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 5): expected exactly 1 Active alert, found %', v_active_count;
    END IF;
    IF v_new_alert_id = v_old_alert_id THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 1, step 5): the new alert must be a DISTINCT occurrence, not the same alert_id as the Ended one';
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Scenario 1 step 5 PASSED -- new, distinct alert % is Active (old % remains Ended)', v_new_alert_id, v_old_alert_id;
END;
$verify5$;

-- ============================================================================
-- SCENARIO 2 (negative/guard): recovery while NOT material must NOT force
-- an Ended -- must proceed to normal resolution instead.
-- ============================================================================

\echo '[mvp7-data-unavail] Scenario 2 step 1: seed material data on site 2, qualify to Active'
SELECT pg_temp.seed_lifecycle_case('00000000-0000-0000-0000-0000000242a3'::UUID, 130, 100);
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);
UPDATE analytics.alert_evaluation_candidates
SET since = now() - INTERVAL '6 minutes', last_evaluated_at = now()
WHERE site_id = '00000000-0000-0000-0000-0000000242a3' AND watch_state = 'WATCHING_TRIGGER';
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);

DO $verify6$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM analytics.alerts WHERE site_id = '00000000-0000-0000-0000-0000000242a3' AND state = 'ACTIVE') THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 2, step 1): expected an Active alert on site 2';
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Scenario 2 step 1 PASSED';
END;
$verify6$;

\echo '[mvp7-data-unavail] Scenario 2 step 2: data becomes unavailable, then recovers as NOT material (105 vs 100, +5%) -- must not force Ended'
DELETE FROM analytics.energy_consumption_daily
WHERE site_id = '00000000-0000-0000-0000-0000000242a3'
  AND consumption_date = ((now() AT TIME ZONE 'UTC')::DATE - 1);
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);

INSERT INTO analytics.energy_consumption_daily
(bucket_start, consumption_date, site_timezone, organization_id, site_id, device_id,
 source_interval_count, import_consumption_kwh, export_consumption_kwh,
 valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
 gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count)
SELECT
    ((now() AT TIME ZONE 'UTC')::DATE - 1)::TIMESTAMP AT TIME ZONE 'UTC', (now() AT TIME ZONE 'UTC')::DATE - 1, 'UTC',
    organization_id, '00000000-0000-0000-0000-0000000242a3'::UUID, gen_random_uuid(),
    100, 105, 0, 100, 0, 100, 0, 0, 0, 0, 0
FROM metadata.sites WHERE id = '00000000-0000-0000-0000-0000000242a3';

CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);

DO $verify7$
DECLARE
    v_state TEXT;
    v_ended_reason_code TEXT;
BEGIN
    SELECT state, ended_reason_code INTO v_state, v_ended_reason_code
    FROM analytics.alerts
    WHERE site_id = '00000000-0000-0000-0000-0000000242a3'
    ORDER BY triggered_at DESC LIMIT 1;

    IF v_state = 'ENDED' AND v_ended_reason_code = 'DATA_UNAVAILABLE' THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 2, step 2): recovery while NOT material must NOT force a DATA_UNAVAILABLE Ended -- the new logic incorrectly fired';
    END IF;
    IF v_state NOT IN ('ACTIVE') THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 2, step 2): expected the alert to still be ACTIVE, now on the normal resolution path (WATCHING_CLEAR), got %', v_state;
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Scenario 2 step 2 PASSED -- alert remains ACTIVE (normal resolution path), not forced Ended';
END;
$verify7$;

DO $verify8$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM analytics.alert_evaluation_candidates
        WHERE site_id = '00000000-0000-0000-0000-0000000242a3' AND watch_state = 'WATCHING_CLEAR'
    ) THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL (scenario 2, step 2): expected a WATCHING_CLEAR resolution candidate, found none -- normal resolution path was not taken';
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Scenario 2 confirmed on the normal WATCHING_CLEAR resolution path, unaffected by the new Ended logic';
END;
$verify8$;

-- ----------------------------------------------------------------------------
-- Cleanup -- plain top-level DELETEs (see header note: no BEGIN/ROLLBACK is
-- possible here). Does not affect any assertion running later in the same
-- integration-test sequence.
-- ----------------------------------------------------------------------------
DELETE FROM analytics.alert_evaluation_candidates WHERE site_id IN ('00000000-0000-0000-0000-0000000242a2', '00000000-0000-0000-0000-0000000242a3');
DELETE FROM analytics.alerts WHERE site_id IN ('00000000-0000-0000-0000-0000000242a2', '00000000-0000-0000-0000-0000000242a3');
DELETE FROM analytics.energy_consumption_daily WHERE site_id IN ('00000000-0000-0000-0000-0000000242a2', '00000000-0000-0000-0000-0000000242a3');
DELETE FROM metadata.sites WHERE id IN ('00000000-0000-0000-0000-0000000242a2', '00000000-0000-0000-0000-0000000242a3');
DELETE FROM metadata.organizations WHERE id = '00000000-0000-0000-0000-0000000242a1';

DO $verify_cleanup$
BEGIN
    IF EXISTS (SELECT 1 FROM metadata.sites WHERE id IN ('00000000-0000-0000-0000-0000000242a2', '00000000-0000-0000-0000-0000000242a3')) THEN
        RAISE EXCEPTION 'MVP7 LIFECYCLE FAIL: fixture sites were not cleaned up.';
    END IF;
    RAISE NOTICE '[mvp7-data-unavail] Cleanup verified -- fixture sites/org/data removed.';
END;
$verify_cleanup$;

\echo '========================================================================================='
\echo 'assert_mvp7_alert_data_unavailable_lifecycle_executes.sql: ALL SCENARIOS PASSED'
\echo '========================================================================================='
