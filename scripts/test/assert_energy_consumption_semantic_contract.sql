\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS — Phase 1B energy-consumption semantic contract
--
-- Canonical lineage under test:
--   analytics.energy_consumption_{1min,5min} -> 15min -> hourly / daily
--
-- This proves the PERSISTED REFRESH/AGGREGATION PATH end-to-end using the
-- real repository functions (analytics.refresh_energy_consumption_15min,
-- _hourly, _daily), not a reimplementation of their logic. It does not
-- merely unit-test analytics.classify_energy_register_delta() in isolation:
-- that function's real output is used as INPUT to the real rollup chain,
-- and the rollup chain's real output is what is asserted.
--
-- Scope note (native 1min/5min tier): analytics.refresh_energy_consumption_
-- {1min,5min} read from telemetry.ca_energy_{1min,5min}, TimescaleDB
-- continuous aggregates. Continuous aggregates cannot be refreshed inside an
-- explicit transaction block, so this test cannot populate them via raw
-- telemetry.energy_measurements while remaining inside one BEGIN/ROLLBACK
-- transaction (a hard requirement of this contract). Native-tier rows are
-- therefore seeded directly into analytics.energy_consumption_1min via a
-- real, direct call to analytics.classify_energy_register_delta() for each
-- scenario (GOOD/GAP/RESET/ROLLOVER) -- the same canonical function the
-- native refresh procedures call -- so the classifier's real output is what
-- feeds the real, unmodified 15-minute/hourly/daily rollup functions.
--
-- All test records are created inside one transaction and rolled back.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Organization / site (Asia/Kolkata, UTC+05:30 -- a non-whole-hour offset,
-- required to discriminate daily-from-15min vs. daily-from-hourly below).
-- ---------------------------------------------------------------------------

INSERT INTO metadata.organizations (id, name, code, description, is_active)
VALUES ('95000000-0000-0000-0000-000000000001', 'Energy Consumption Contract Tenant', 'ENERGY_CONSUMPTION_CONTRACT', 'Disposable energy-consumption semantic contract tenant', TRUE);

INSERT INTO metadata.sites (id, organization_id, name, code, timezone, address, is_active)
VALUES ('95100000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-000000000001', 'Energy Consumption Contract Site', 'ENERGY_CONSUMPTION_CONTRACT_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE);

-- Device ids are not FK-constrained by analytics.energy_consumption_* (no
-- REFERENCES clause on device_id in any of the 1min/5min/15min/hourly/daily
-- tables), so no metadata.devices/gateways/assets rows are required for
-- this contract -- only organization_id/site_id, which the daily refresh
-- function's join to metadata.sites requires to exist for real.

-- =============================================================================
-- SCENARIO 1 — GOOD / GAP / RESET / ROLLOVER, and 15-MINUTE ADDITIVE ROLLUP
--
-- Device A, one 15-minute bucket [09:00,09:15) UTC on 2026-01-01, four native
-- one-minute intervals, one per classification. Import register semantics are
-- varied per-row via direct classifier arguments (this test calls the
-- classifier directly rather than through config.energy_register_semantics,
-- so each row may exercise different rollover/reset behavior independently).
-- Export is held GOOD throughout as a control.
-- =============================================================================

INSERT INTO analytics.energy_consumption_1min
(
    bucket_start, organization_id, site_id, device_id,
    previous_bucket_start, elapsed_minutes, source_sample_count,
    import_register_wh, previous_import_register_wh, import_consumption_wh, import_consumption_kwh,
    import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
    export_register_wh, previous_export_register_wh, export_consumption_wh, export_consumption_kwh,
    export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
    gap_detected, quality_rule_id, gap_threshold_minutes, quality_rule_scope, quality_rule_scope_key
)
SELECT
    fixture.bucket_start, '95000000-0000-0000-0000-000000000001', '95100000-0000-0000-0000-000000000001', '95300000-0000-0000-0000-000000000001',
    fixture.bucket_start - INTERVAL '1 minute', 1, 1,
    fixture.import_current, fixture.import_previous, import_result.delta_wh, import_result.delta_wh / 1000.0,
    import_result.quality_code, import_result.is_valid, import_result.reset_detected, import_result.rollover_detected,
    fixture.export_current, fixture.export_previous, export_result.delta_wh, export_result.delta_wh / 1000.0,
    export_result.quality_code, export_result.is_valid, export_result.reset_detected, export_result.rollover_detected,
    (import_result.quality_code = 'GAP' OR export_result.quality_code = 'GAP'),
    NULL, 5, 'TEST', 'TEST'
FROM
(
    VALUES
        -- label,        bucket_start,                          elapsed, import_current, import_previous, import_rollover_behavior, import_rollover_value, export_current, export_previous
        ('GOOD',     TIMESTAMPTZ '2026-01-01 09:01:00+00', 1::numeric,  1010::numeric, 1000::numeric, 'NONE',         NULL::numeric, 2005::numeric, 2000::numeric),
        ('GAP',      TIMESTAMPTZ '2026-01-01 09:02:00+00', 10::numeric, 1030::numeric, 1010::numeric, 'NONE',         NULL::numeric, 2005::numeric, 2000::numeric),
        ('RESET',    TIMESTAMPTZ '2026-01-01 09:05:00+00', 1::numeric,  500::numeric,  1030::numeric, 'NONE',         NULL::numeric, 2005::numeric, 2000::numeric),
        ('ROLLOVER', TIMESTAMPTZ '2026-01-01 09:08:00+00', 1::numeric,  50::numeric,   990::numeric,  'FIXED_MODULUS', 1000::numeric, 2005::numeric, 2000::numeric)
) AS fixture(label, bucket_start, elapsed_minutes, import_current, import_previous, import_rollover_behavior, import_rollover_value, export_current, export_previous)

CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    fixture.import_current, fixture.import_previous, fixture.elapsed_minutes,
    'INCREASING', fixture.import_rollover_behavior, fixture.import_rollover_value,
    'REJECT_DELTA', 500, 5
) import_result

CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    fixture.export_current, fixture.export_previous, fixture.elapsed_minutes,
    'INCREASING', 'NONE', NULL,
    'REJECT_DELTA', 500, 5
) export_result;

-- Sanity-check the classifier actually produced the four distinct
-- classifications this scenario depends on, before trusting the rollup.
DO $$
DECLARE
    v_codes TEXT[];
BEGIN
    SELECT array_agg(import_quality_code ORDER BY bucket_start)
    INTO v_codes
    FROM analytics.energy_consumption_1min
    WHERE device_id = '95300000-0000-0000-0000-000000000001';

    IF v_codes IS DISTINCT FROM ARRAY['GOOD','GAP','RESET','ROLLOVER'] THEN
        RAISE EXCEPTION 'Fixture setup error: expected classifier codes [GOOD,GAP,RESET,ROLLOVER], got %', v_codes;
    END IF;
END
$$;

-- Exercise the REAL persisted 15-minute refresh function.
SELECT analytics.refresh_energy_consumption_15min(TIMESTAMPTZ '2026-01-01 09:00:00+00', TIMESTAMPTZ '2026-01-01 09:15:00+00');

DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r
    FROM analytics.energy_consumption_15min
    WHERE device_id = '95300000-0000-0000-0000-000000000001'
      AND bucket_start = TIMESTAMPTZ '2026-01-01 09:00:00+00';

    IF r IS NULL THEN
        RAISE EXCEPTION '15-minute rollup produced no row for the GOOD/GAP/RESET/ROLLOVER bucket';
    END IF;

    -- Additive sum: GOOD(10)+GAP(20)+ROLLOVER(60) Wh = 90 Wh = 0.090 kWh.
    -- RESET is_valid=FALSE and is correctly excluded, per the canonical
    -- classifier's own behavior (verified from source this session).
    IF r.import_consumption_kwh IS DISTINCT FROM 0.090 THEN
        RAISE EXCEPTION 'Scenario 1: expected import_consumption_kwh 0.090 (GOOD+GAP+ROLLOVER only, RESET excluded), got %', r.import_consumption_kwh;
    END IF;

    IF r.export_consumption_kwh IS DISTINCT FROM 0.020 THEN
        RAISE EXCEPTION 'Scenario 1: expected export_consumption_kwh 0.020 (4 x GOOD), got %', r.export_consumption_kwh;
    END IF;

    IF r.source_interval_count <> 4 THEN
        RAISE EXCEPTION 'Scenario 1: expected source_interval_count 4, got %', r.source_interval_count;
    END IF;

    IF r.valid_import_intervals <> 3 OR r.invalid_import_intervals <> 1 THEN
        RAISE EXCEPTION 'Scenario 1: expected valid_import_intervals=3, invalid_import_intervals=1 (RESET only), got valid=% invalid=%', r.valid_import_intervals, r.invalid_import_intervals;
    END IF;

    IF r.valid_export_intervals <> 4 OR r.invalid_export_intervals <> 0 THEN
        RAISE EXCEPTION 'Scenario 1: expected valid_export_intervals=4, invalid_export_intervals=0, got valid=% invalid=%', r.valid_export_intervals, r.invalid_export_intervals;
    END IF;

    -- Confirmed fact, not the originally-assumed one: GAP has is_valid=TRUE
    -- in the canonical classifier, so it contributes to consumption and is
    -- ALSO counted here -- gap_interval_count is informational, not
    -- exclusionary.
    IF r.gap_interval_count <> 1 THEN
        RAISE EXCEPTION 'Scenario 1: expected gap_interval_count 1, got %', r.gap_interval_count;
    END IF;

    IF r.reset_interval_count <> 1 THEN
        RAISE EXCEPTION 'Scenario 1: expected reset_interval_count 1, got %', r.reset_interval_count;
    END IF;

    IF r.rollover_interval_count <> 1 THEN
        RAISE EXCEPTION 'Scenario 1: expected rollover_interval_count 1, got %', r.rollover_interval_count;
    END IF;

    -- Only RESET is invalid (import_is_valid=FALSE); export is always valid.
    IF r.invalid_interval_count <> 1 THEN
        RAISE EXCEPTION 'Scenario 1: expected invalid_interval_count 1 (RESET only), got %', r.invalid_interval_count;
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 2 — HOURLY DERIVED FROM 15-MINUTE ONLY
--
-- Device B, two 15-minute buckets in the same hour [10:00,11:00) UTC, each
-- with one simple GOOD native interval. Proves the hourly refresh function
-- (which, per its own source, reads exclusively from
-- analytics.energy_consumption_15min) produces the additive sum of the two
-- 15-minute rows.
-- =============================================================================

INSERT INTO analytics.energy_consumption_1min
(
    bucket_start, organization_id, site_id, device_id,
    previous_bucket_start, elapsed_minutes, source_sample_count,
    import_register_wh, previous_import_register_wh, import_consumption_wh, import_consumption_kwh,
    import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
    export_register_wh, previous_export_register_wh, export_consumption_wh, export_consumption_kwh,
    export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
    gap_detected, quality_rule_id, gap_threshold_minutes, quality_rule_scope, quality_rule_scope_key
)
SELECT
    fixture.bucket_start, '95000000-0000-0000-0000-000000000001', '95100000-0000-0000-0000-000000000001', '95300000-0000-0000-0000-000000000002',
    fixture.bucket_start - INTERVAL '1 minute', 1, 1,
    fixture.import_current, fixture.import_previous, import_result.delta_wh, import_result.delta_wh / 1000.0,
    import_result.quality_code, import_result.is_valid, import_result.reset_detected, import_result.rollover_detected,
    fixture.export_current, fixture.export_previous, export_result.delta_wh, export_result.delta_wh / 1000.0,
    export_result.quality_code, export_result.is_valid, export_result.reset_detected, export_result.rollover_detected,
    FALSE, NULL, 5, 'TEST', 'TEST'
FROM
(
    VALUES
        (TIMESTAMPTZ '2026-01-01 10:05:00+00', 1015::numeric, 1000::numeric, 2005::numeric, 2000::numeric),
        (TIMESTAMPTZ '2026-01-01 10:20:00+00', 1025::numeric, 1000::numeric, 2005::numeric, 2000::numeric)
) AS fixture(bucket_start, import_current, import_previous, export_current, export_previous)

CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    fixture.import_current, fixture.import_previous, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5
) import_result

CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    fixture.export_current, fixture.export_previous, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5
) export_result;

SELECT analytics.refresh_energy_consumption_15min(TIMESTAMPTZ '2026-01-01 10:00:00+00', TIMESTAMPTZ '2026-01-01 10:30:00+00');

DO $$
DECLARE
    v_count BIGINT;
BEGIN
    SELECT count(*) INTO v_count
    FROM analytics.energy_consumption_15min
    WHERE device_id = '95300000-0000-0000-0000-000000000002';

    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Scenario 2: expected 2 distinct 15-minute rows (10:00 and 10:15 buckets), got %', v_count;
    END IF;
END
$$;

SELECT analytics.refresh_energy_consumption_hourly(TIMESTAMPTZ '2026-01-01 10:00:00+00', TIMESTAMPTZ '2026-01-01 11:00:00+00');

DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r
    FROM analytics.energy_consumption_hourly
    WHERE device_id = '95300000-0000-0000-0000-000000000002'
      AND bucket_start = TIMESTAMPTZ '2026-01-01 10:00:00+00';

    IF r IS NULL THEN
        RAISE EXCEPTION 'Hourly rollup produced no row for [10:00,11:00)';
    END IF;

    -- Additive sum of the two 15-minute rows: 0.015 + 0.025 = 0.040 kWh.
    -- This is only possible if the hourly function derived from the
    -- persisted 15-minute rows, matching its own source-code comment
    -- ("must never recalculate energy from coarse cumulative register
    -- MIN/MAX values") and its actual FROM clause
    -- (analytics.energy_consumption_15min only).
    IF r.import_consumption_kwh IS DISTINCT FROM 0.040 THEN
        RAISE EXCEPTION 'Scenario 2: expected hourly import_consumption_kwh 0.040 (additive sum of two 15-min rows), got %', r.import_consumption_kwh;
    END IF;

    IF r.source_interval_count <> 2 THEN
        RAISE EXCEPTION 'Scenario 2: expected hourly source_interval_count 2, got %', r.source_interval_count;
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 3 — DAILY DERIVED FROM 15-MINUTE ONLY, SITE-LOCAL TIMEZONE
--
-- Device C. Two 15-minute buckets, 18:00 and 18:30 UTC on 2025-12-31, both
-- inside the SAME UTC hour [18:00,19:00). In Asia/Kolkata (UTC+05:30), local
-- midnight falls at 18:30 UTC -- so the 18:00 bucket is still 2025-12-31
-- locally, while the 18:30 bucket is already 2026-01-01 locally. If daily
-- were (incorrectly) derived from an hourly-first rollup, both quarter-hours
-- would be merged into the single UTC hour and attributed to one date. The
-- real daily refresh function reads only analytics.energy_consumption_15min
-- (confirmed from source), so it must produce two separate daily rows with
-- the consumption correctly split by site-local calendar day.
--
-- These 15-minute rows are seeded directly (this scenario tests the daily
-- function's own source/timezone logic, not 15-minute-rollup arithmetic,
-- which scenario 1 already proves against the real classifier output).
-- =============================================================================

INSERT INTO analytics.energy_consumption_15min
(
    bucket_start, organization_id, site_id, device_id,
    source_interval_count, import_consumption_kwh, export_consumption_kwh,
    valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
    gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count,
    first_source_bucket, last_source_bucket
)
VALUES
(
    TIMESTAMPTZ '2025-12-31 18:00:00+00', '95000000-0000-0000-0000-000000000001', '95100000-0000-0000-0000-000000000001', '95300000-0000-0000-0000-000000000003',
    1, 0.050, 0.010,
    1, 0, 1, 0,
    0, 0, 0, 0,
    TIMESTAMPTZ '2025-12-31 18:00:00+00', TIMESTAMPTZ '2025-12-31 18:00:00+00'
),
(
    TIMESTAMPTZ '2025-12-31 18:30:00+00', '95000000-0000-0000-0000-000000000001', '95100000-0000-0000-0000-000000000001', '95300000-0000-0000-0000-000000000003',
    1, 0.070, 0.015,
    1, 0, 1, 0,
    0, 0, 0, 0,
    TIMESTAMPTZ '2025-12-31 18:30:00+00', TIMESTAMPTZ '2025-12-31 18:30:00+00'
);

SELECT analytics.refresh_energy_consumption_daily(TIMESTAMPTZ '2025-12-31 00:00:00+00', TIMESTAMPTZ '2026-01-02 00:00:00+00');

DO $$
DECLARE
    v_count BIGINT;
    r_dec31 RECORD;
    r_jan1  RECORD;
BEGIN
    SELECT count(*) INTO v_count
    FROM analytics.energy_consumption_daily
    WHERE device_id = '95300000-0000-0000-0000-000000000003';

    -- The discriminating assertion: two source buckets sharing one UTC hour
    -- must still produce two separate site-local daily rows.
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Scenario 3: expected 2 distinct site-local daily rows (would collapse to 1 if daily were derived from an hourly-first rollup), got %', v_count;
    END IF;

    SELECT * INTO r_dec31
    FROM analytics.energy_consumption_daily
    WHERE device_id = '95300000-0000-0000-0000-000000000003'
      AND consumption_date = DATE '2025-12-31';

    IF r_dec31 IS NULL THEN
        RAISE EXCEPTION 'Scenario 3: no daily row found for site-local 2025-12-31';
    END IF;

    IF r_dec31.import_consumption_kwh IS DISTINCT FROM 0.050 THEN
        RAISE EXCEPTION 'Scenario 3: expected 2025-12-31 import_consumption_kwh 0.050 (18:00 UTC bucket only), got %', r_dec31.import_consumption_kwh;
    END IF;

    IF r_dec31.site_timezone IS DISTINCT FROM 'Asia/Kolkata' THEN
        RAISE EXCEPTION 'Scenario 3: expected site_timezone Asia/Kolkata on the 2025-12-31 row, got %', r_dec31.site_timezone;
    END IF;

    -- Local midnight for 2025-12-31 in Asia/Kolkata is 2025-12-30 18:30 UTC.
    IF r_dec31.bucket_start IS DISTINCT FROM TIMESTAMPTZ '2025-12-30 18:30:00+00' THEN
        RAISE EXCEPTION 'Scenario 3: expected 2025-12-31 bucket_start (local midnight) 2025-12-30 18:30:00+00, got %', r_dec31.bucket_start;
    END IF;

    SELECT * INTO r_jan1
    FROM analytics.energy_consumption_daily
    WHERE device_id = '95300000-0000-0000-0000-000000000003'
      AND consumption_date = DATE '2026-01-01';

    IF r_jan1 IS NULL THEN
        RAISE EXCEPTION 'Scenario 3: no daily row found for site-local 2026-01-01';
    END IF;

    IF r_jan1.import_consumption_kwh IS DISTINCT FROM 0.070 THEN
        RAISE EXCEPTION 'Scenario 3: expected 2026-01-01 import_consumption_kwh 0.070 (18:30 UTC bucket only), got %', r_jan1.import_consumption_kwh;
    END IF;

    -- Local midnight for 2026-01-01 in Asia/Kolkata is 2025-12-31 18:30 UTC
    -- -- the exact instant that separates the two source buckets.
    IF r_jan1.bucket_start IS DISTINCT FROM TIMESTAMPTZ '2025-12-31 18:30:00+00' THEN
        RAISE EXCEPTION 'Scenario 3: expected 2026-01-01 bucket_start (local midnight) 2025-12-31 18:30:00+00, got %', r_jan1.bucket_start;
    END IF;
END
$$;

ROLLBACK;

SELECT 'Energy consumption semantic contract assertions passed.' AS result;
