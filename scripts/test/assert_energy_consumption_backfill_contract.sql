\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS — Phase 1E-B historical backfill contract
--
-- Proves analytics.backfill_energy_consumption_per_flow_quality() correctly
-- orchestrates the real, unmodified Phase 1E-A refresh functions over a
-- historical range, and specifically proves the corrected reconstructability
-- model (Audit/EMS Analytics Platform — Phase 1E-B Implementation Plan.txt):
--   - buckets with surviving native source are fully reconstructed;
--   - a 15-minute row whose per-flow columns are ALREADY populated (e.g. by
--     prior real-time operation) survives a backfill re-run unchanged even
--     when no native source exists for it at all (forward durability);
--   - a 15-minute row whose per-flow columns are genuinely unreconstructable
--     (legacy NULL, no surviving native) remains NULL, never zeroed, and its
--     pre-existing values are completely unaffected;
--   - hourly/daily correctly propagate both populated and NULL per-flow
--     data from the 15-minute tier, without any special-case code.
--
-- No new calculation logic is exercised here. Native-tier fixtures use real
-- calls to analytics.classify_energy_register_delta(), exactly as every
-- prior phase's tests do. All test records are created inside one
-- transaction and rolled back.
-- =============================================================================

BEGIN;

INSERT INTO metadata.organizations (id, name, code, description, is_active)
VALUES
    ('98000000-0000-0000-0000-000000000001', 'Backfill Contract Tenant', 'BACKFILL_CONTRACT', 'Disposable Phase 1E-B backfill contract tenant', TRUE),
    ('98000000-0000-0000-0000-000000000002', 'Backfill Contract Other Tenant', 'BACKFILL_CONTRACT_OTHER', 'Disposable Phase 1E-B tenant-isolation control tenant', TRUE);

INSERT INTO metadata.sites (id, organization_id, name, code, timezone, address, is_active)
VALUES
    ('98100000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-000000000001', 'Backfill Contract Site', 'BACKFILL_CONTRACT_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE),
    ('98100000-0000-0000-0000-000000000002', '98000000-0000-0000-0000-000000000002', 'Backfill Contract Other Site', 'BACKFILL_CONTRACT_OTHER_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE);

-- ---------------------------------------------------------------------------
-- Device A: the exact Phase 1E-A seven-combination fixture, reused verbatim,
-- to prove full 15m reconstruction, hourly/daily propagation, and
-- import/export quality fidelity via the new backfill procedure.
-- ---------------------------------------------------------------------------

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
    fixture.bucket_start, '98000000-0000-0000-0000-000000000001', '98100000-0000-0000-0000-000000000001', '98300000-0000-0000-0000-000000000001',
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
        ('GOOD/GOOD',        TIMESTAMPTZ '2026-01-01 09:00:00+00', 1::numeric,  1010::numeric, 1000::numeric, 'NONE'::text,          NULL::numeric, 1::numeric,  2010::numeric, 2000::numeric, 'NONE'::text,          NULL::numeric),
        ('GAP/GOOD',         TIMESTAMPTZ '2026-01-01 09:15:00+00', 10::numeric, 1020::numeric, 1000::numeric, 'NONE'::text,          NULL::numeric, 1::numeric,  2010::numeric, 2000::numeric, 'NONE'::text,          NULL::numeric),
        ('GOOD/GAP',         TIMESTAMPTZ '2026-01-01 09:30:00+00', 1::numeric,  1010::numeric, 1000::numeric, 'NONE'::text,          NULL::numeric, 10::numeric, 2020::numeric, 2000::numeric, 'NONE'::text,          NULL::numeric),
        ('RESET/GOOD',       TIMESTAMPTZ '2026-01-01 09:45:00+00', 1::numeric,  500::numeric,  1030::numeric, 'NONE'::text,          NULL::numeric, 1::numeric,  2010::numeric, 2000::numeric, 'NONE'::text,          NULL::numeric),
        ('GOOD/RESET',       TIMESTAMPTZ '2026-01-01 10:00:00+00', 1::numeric,  1010::numeric, 1000::numeric, 'NONE'::text,          NULL::numeric, 1::numeric,  500::numeric,  2030::numeric, 'NONE'::text,          NULL::numeric),
        ('ROLLOVER/GOOD',    TIMESTAMPTZ '2026-01-01 10:15:00+00', 1::numeric,  50::numeric,   990::numeric,  'FIXED_MODULUS'::text, 1000::numeric, 1::numeric,  2010::numeric, 2000::numeric, 'NONE'::text,          NULL::numeric),
        ('GOOD/ROLLOVER',    TIMESTAMPTZ '2026-01-01 10:30:00+00', 1::numeric,  1010::numeric, 1000::numeric, 'NONE'::text,          NULL::numeric, 1::numeric,  50::numeric,   1990::numeric, 'FIXED_MODULUS'::text, 2000::numeric)
) AS fixture(label, bucket_start,
             import_elapsed, import_current, import_previous, import_rollover_behavior, import_rollover_value,
             export_elapsed, export_current, export_previous, export_rollover_behavior, export_rollover_value)

CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    fixture.import_current, fixture.import_previous, fixture.import_elapsed,
    'INCREASING', fixture.import_rollover_behavior, fixture.import_rollover_value,
    'REJECT_DELTA', 500, 5
) import_result

CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    fixture.export_current, fixture.export_previous, fixture.export_elapsed,
    'INCREASING', fixture.export_rollover_behavior, fixture.export_rollover_value,
    'REJECT_DELTA', 500, 5
) export_result;

-- Device T (org B): tenant-isolation control, single GOOD/GOOD interval.
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
    TIMESTAMPTZ '2026-01-01 09:00:00+00', '98000000-0000-0000-0000-000000000002', '98100000-0000-0000-0000-000000000002', '98300000-0000-0000-0000-000000000002',
    TIMESTAMPTZ '2026-01-01 08:59:00+00', 1, 1,
    3010, 3000, import_result.delta_wh, import_result.delta_wh / 1000.0,
    import_result.quality_code, import_result.is_valid, import_result.reset_detected, import_result.rollover_detected,
    4010, 4000, export_result.delta_wh, export_result.delta_wh / 1000.0,
    export_result.quality_code, export_result.is_valid, export_result.reset_detected, export_result.rollover_detected,
    FALSE, NULL, 5, 'TEST', 'TEST'
FROM (SELECT 1) AS one_row
CROSS JOIN LATERAL analytics.classify_energy_register_delta(3010, 3000, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5) import_result
CROSS JOIN LATERAL analytics.classify_energy_register_delta(4010, 4000, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5) export_result;

-- Device TZ: Phase 1B/1D's exact site-local-midnight-crossing native pair,
-- proving timezone bucketing survives the backfill procedure.
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
    fixture.bucket_start, '98000000-0000-0000-0000-000000000001', '98100000-0000-0000-0000-000000000001', '98300000-0000-0000-0000-000000000005',
    fixture.bucket_start - INTERVAL '1 minute', 1, 1,
    fixture.import_current, fixture.import_previous, import_result.delta_wh, import_result.delta_wh / 1000.0,
    import_result.quality_code, import_result.is_valid, import_result.reset_detected, import_result.rollover_detected,
    fixture.export_current, fixture.export_previous, export_result.delta_wh, export_result.delta_wh / 1000.0,
    export_result.quality_code, export_result.is_valid, export_result.reset_detected, export_result.rollover_detected,
    FALSE, NULL, 5, 'TEST', 'TEST'
FROM
(
    VALUES
        (TIMESTAMPTZ '2025-12-31 18:00:00+00', 1010::numeric, 1000::numeric, 2010::numeric, 2000::numeric),
        (TIMESTAMPTZ '2025-12-31 18:30:00+00', 1020::numeric, 1010::numeric, 2020::numeric, 2010::numeric)
) AS fixture(bucket_start, import_current, import_previous, export_current, export_previous)
CROSS JOIN LATERAL analytics.classify_energy_register_delta(fixture.import_current, fixture.import_previous, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5) import_result
CROSS JOIN LATERAL analytics.classify_energy_register_delta(fixture.export_current, fixture.export_previous, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5) export_result;

-- ---------------------------------------------------------------------------
-- Device D ("durability"): a 15-minute row seeded directly with per-flow
-- columns ALREADY populated (simulating prior real-time operation/backfill)
-- and NO native source at all -- proves already-materialized per-flow data
-- survives a backfill re-run untouched even absent native, and correctly
-- propagates to hourly/daily.
-- ---------------------------------------------------------------------------

INSERT INTO analytics.energy_consumption_15min
(
    bucket_start, organization_id, site_id, device_id,
    source_interval_count, import_consumption_kwh, export_consumption_kwh,
    valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
    gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count,
    import_gap_intervals, export_gap_intervals, import_reset_intervals, export_reset_intervals,
    import_rollover_intervals, export_rollover_intervals,
    first_source_bucket, last_source_bucket, calculated_at
)
VALUES
(
    TIMESTAMPTZ '2026-02-01 09:00:00+00', '98000000-0000-0000-0000-000000000001', '98100000-0000-0000-0000-000000000001', '98300000-0000-0000-0000-000000000003',
    4, 0.050, 0.045,
    3, 1, 3, 1,
    1, 1, 0, 1,
    1, 0, 0, 1,
    0, 0,
    TIMESTAMPTZ '2026-02-01 09:00:00+00', TIMESTAMPTZ '2026-02-01 09:00:00+00', TIMESTAMPTZ '2026-01-15 00:00:00+00'
);

-- ---------------------------------------------------------------------------
-- Device E ("unreconstructable"): a 15-minute row seeded directly with
-- per-flow columns NULL (simulating a legacy pre-Phase-1E-A row) and NO
-- native source at all -- proves genuinely unreconstructable history stays
-- NULL, never zeroed, and its pre-existing values are unaffected.
-- ---------------------------------------------------------------------------

INSERT INTO analytics.energy_consumption_15min
(
    bucket_start, organization_id, site_id, device_id,
    source_interval_count, import_consumption_kwh, export_consumption_kwh,
    valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
    gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count,
    first_source_bucket, last_source_bucket, calculated_at
)
VALUES
(
    TIMESTAMPTZ '2026-03-01 09:00:00+00', '98000000-0000-0000-0000-000000000001', '98100000-0000-0000-0000-000000000001', '98300000-0000-0000-0000-000000000004',
    1, 0.030, 0.025,
    1, 0, 1, 0,
    0, 0, 0, 0,
    TIMESTAMPTZ '2026-03-01 09:00:00+00', TIMESTAMPTZ '2026-03-01 09:00:00+00', TIMESTAMPTZ '2025-06-01 00:00:00+00'
);

-- Fixture sanity check.
DO $$
DECLARE
    v_import_codes TEXT[];
    v_export_codes TEXT[];
BEGIN
    SELECT array_agg(import_quality_code ORDER BY bucket_start), array_agg(export_quality_code ORDER BY bucket_start)
    INTO v_import_codes, v_export_codes
    FROM analytics.energy_consumption_1min
    WHERE device_id = '98300000-0000-0000-0000-000000000001';

    IF v_import_codes IS DISTINCT FROM ARRAY['GOOD','GAP','GOOD','RESET','GOOD','ROLLOVER','GOOD'] THEN
        RAISE EXCEPTION 'Fixture setup error: expected import codes [GOOD,GAP,GOOD,RESET,GOOD,ROLLOVER,GOOD], got %', v_import_codes;
    END IF;
    IF v_export_codes IS DISTINCT FROM ARRAY['GOOD','GOOD','GAP','GOOD','RESET','GOOD','ROLLOVER'] THEN
        RAISE EXCEPTION 'Fixture setup error: expected export codes [GOOD,GOOD,GAP,GOOD,RESET,GOOD,ROLLOVER], got %', v_export_codes;
    END IF;
END
$$;

-- =============================================================================
-- FIRST BACKFILL RUN over the entire fixture range.
-- =============================================================================

DO $$
DECLARE
    v_batches INTEGER;
    v_errors INTEGER;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE batch_error IS NOT NULL)
    INTO v_batches, v_errors
    FROM analytics.backfill_energy_consumption_per_flow_quality(
        TIMESTAMPTZ '2025-12-31 00:00:00+00', TIMESTAMPTZ '2026-04-01 00:00:00+00', INTERVAL '7 days'
    );

    IF v_batches < 1 THEN
        RAISE EXCEPTION 'Backfill: expected at least one batch to run, got %', v_batches;
    END IF;

    IF v_errors <> 0 THEN
        RAISE EXCEPTION 'Backfill: expected zero batch errors on the first run, got %', v_errors;
    END IF;
END
$$;

-- Scenario 1 — Device A: 15-minute per-flow reconstruction (exact Phase 1E-A values).
DO $$
DECLARE
    v_import_gap BIGINT[]; v_export_gap BIGINT[]; v_import_reset BIGINT[]; v_export_reset BIGINT[];
    v_import_rollover BIGINT[]; v_export_rollover BIGINT[]; v_import_kwh NUMERIC[]; v_export_kwh NUMERIC[];
BEGIN
    SELECT
        array_agg(import_gap_intervals ORDER BY bucket_start), array_agg(export_gap_intervals ORDER BY bucket_start),
        array_agg(import_reset_intervals ORDER BY bucket_start), array_agg(export_reset_intervals ORDER BY bucket_start),
        array_agg(import_rollover_intervals ORDER BY bucket_start), array_agg(export_rollover_intervals ORDER BY bucket_start),
        array_agg(import_consumption_kwh ORDER BY bucket_start), array_agg(export_consumption_kwh ORDER BY bucket_start)
    INTO v_import_gap, v_export_gap, v_import_reset, v_export_reset, v_import_rollover, v_export_rollover, v_import_kwh, v_export_kwh
    FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000001';

    IF v_import_gap IS DISTINCT FROM ARRAY[0,1,0,0,0,0,0]::BIGINT[] THEN RAISE EXCEPTION 'Scenario 1: import_gap_intervals mismatch: %', v_import_gap; END IF;
    IF v_export_gap IS DISTINCT FROM ARRAY[0,0,1,0,0,0,0]::BIGINT[] THEN RAISE EXCEPTION 'Scenario 1: export_gap_intervals mismatch: %', v_export_gap; END IF;
    IF v_import_reset IS DISTINCT FROM ARRAY[0,0,0,1,0,0,0]::BIGINT[] THEN RAISE EXCEPTION 'Scenario 1: import_reset_intervals mismatch: %', v_import_reset; END IF;
    IF v_export_reset IS DISTINCT FROM ARRAY[0,0,0,0,1,0,0]::BIGINT[] THEN RAISE EXCEPTION 'Scenario 1: export_reset_intervals mismatch: %', v_export_reset; END IF;
    IF v_import_rollover IS DISTINCT FROM ARRAY[0,0,0,0,0,1,0]::BIGINT[] THEN RAISE EXCEPTION 'Scenario 1: import_rollover_intervals mismatch: %', v_import_rollover; END IF;
    IF v_export_rollover IS DISTINCT FROM ARRAY[0,0,0,0,0,0,1]::BIGINT[] THEN RAISE EXCEPTION 'Scenario 1: export_rollover_intervals mismatch: %', v_export_rollover; END IF;
    IF v_import_kwh IS DISTINCT FROM ARRAY[0.010,0.020,0.010,NULL,0.010,0.060,0.010]::NUMERIC[] THEN RAISE EXCEPTION 'Scenario 1: import_consumption_kwh mismatch: %', v_import_kwh; END IF;
    IF v_export_kwh IS DISTINCT FROM ARRAY[0.010,0.010,0.020,0.010,NULL,0.010,0.060]::NUMERIC[] THEN RAISE EXCEPTION 'Scenario 1: export_consumption_kwh mismatch: %', v_export_kwh; END IF;
END
$$;

-- Scenario 2 — Device A: hourly propagation.
DO $$
DECLARE h9 RECORD; h10 RECORD;
BEGIN
    SELECT * INTO h9 FROM analytics.energy_consumption_hourly WHERE device_id = '98300000-0000-0000-0000-000000000001' AND bucket_start = TIMESTAMPTZ '2026-01-01 09:00:00+00';
    IF h9 IS NULL THEN RAISE EXCEPTION 'Scenario 2: expected hourly row for 09:00'; END IF;
    IF (h9.import_gap_intervals, h9.export_gap_intervals, h9.import_reset_intervals, h9.export_reset_intervals, h9.import_rollover_intervals, h9.export_rollover_intervals)
       IS DISTINCT FROM (1::BIGINT,1::BIGINT,1::BIGINT,0::BIGINT,0::BIGINT,0::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 2: hour 09:00 per-flow mismatch';
    END IF;
    IF h9.import_consumption_kwh IS DISTINCT FROM 0.040 OR h9.export_consumption_kwh IS DISTINCT FROM 0.050 THEN
        RAISE EXCEPTION 'Scenario 2: hour 09:00 kwh mismatch: %/%', h9.import_consumption_kwh, h9.export_consumption_kwh;
    END IF;

    SELECT * INTO h10 FROM analytics.energy_consumption_hourly WHERE device_id = '98300000-0000-0000-0000-000000000001' AND bucket_start = TIMESTAMPTZ '2026-01-01 10:00:00+00';
    IF h10 IS NULL THEN RAISE EXCEPTION 'Scenario 2: expected hourly row for 10:00'; END IF;
    IF (h10.import_gap_intervals, h10.export_gap_intervals, h10.import_reset_intervals, h10.export_reset_intervals, h10.import_rollover_intervals, h10.export_rollover_intervals)
       IS DISTINCT FROM (0::BIGINT,0::BIGINT,0::BIGINT,1::BIGINT,1::BIGINT,1::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 2: hour 10:00 per-flow mismatch';
    END IF;
    IF h10.import_consumption_kwh IS DISTINCT FROM 0.080 OR h10.export_consumption_kwh IS DISTINCT FROM 0.070 THEN
        RAISE EXCEPTION 'Scenario 2: hour 10:00 kwh mismatch: %/%', h10.import_consumption_kwh, h10.export_consumption_kwh;
    END IF;
END
$$;

-- Scenario 3 — Device A: daily propagation, tenant isolation (device T).
DO $$
DECLARE d RECORD; t RECORD;
BEGIN
    SELECT * INTO d FROM analytics.energy_consumption_daily WHERE device_id = '98300000-0000-0000-0000-000000000001';
    IF d IS NULL THEN RAISE EXCEPTION 'Scenario 3: expected daily row for device A'; END IF;
    IF (d.import_gap_intervals, d.export_gap_intervals, d.import_reset_intervals, d.export_reset_intervals, d.import_rollover_intervals, d.export_rollover_intervals)
       IS DISTINCT FROM (1::BIGINT,1::BIGINT,1::BIGINT,1::BIGINT,1::BIGINT,1::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 3: daily per-flow mismatch';
    END IF;
    IF d.import_consumption_kwh IS DISTINCT FROM 0.120 OR d.export_consumption_kwh IS DISTINCT FROM 0.120 THEN
        RAISE EXCEPTION 'Scenario 3: daily kwh mismatch';
    END IF;

    SELECT * INTO t FROM analytics.energy_consumption_daily WHERE device_id = '98300000-0000-0000-0000-000000000002';
    IF t IS NULL THEN RAISE EXCEPTION 'Scenario 3: expected daily row for tenant-control device T'; END IF;
    IF t.organization_id IS DISTINCT FROM '98000000-0000-0000-0000-000000000002' THEN
        RAISE EXCEPTION 'Scenario 3: tenant control device T shows organization_id %, expected org B', t.organization_id;
    END IF;
    IF (t.import_gap_intervals, t.export_gap_intervals, t.import_reset_intervals, t.export_reset_intervals, t.import_rollover_intervals, t.export_rollover_intervals)
       IS DISTINCT FROM (0::BIGINT,0::BIGINT,0::BIGINT,0::BIGINT,0::BIGINT,0::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 3: tenant control device T shows unexpected non-zero per-flow counters';
    END IF;
END
$$;

-- Scenario 4 — Device TZ: site-local-midnight-crossing daily boundary survives the backfill procedure.
DO $$
DECLARE r1 RECORD; r2 RECORD;
BEGIN
    SELECT * INTO r1 FROM analytics.energy_consumption_daily WHERE device_id = '98300000-0000-0000-0000-000000000005' AND consumption_date = DATE '2025-12-31';
    IF r1 IS NULL THEN RAISE EXCEPTION 'Scenario 4: expected daily row for 2025-12-31'; END IF;
    IF r1.import_consumption_kwh IS DISTINCT FROM 0.010 OR r1.bucket_start IS DISTINCT FROM TIMESTAMPTZ '2025-12-30 18:30:00+00' THEN
        RAISE EXCEPTION 'Scenario 4: 2025-12-31 row mismatch: kwh=%, bucket_start=%', r1.import_consumption_kwh, r1.bucket_start;
    END IF;

    SELECT * INTO r2 FROM analytics.energy_consumption_daily WHERE device_id = '98300000-0000-0000-0000-000000000005' AND consumption_date = DATE '2026-01-01';
    IF r2 IS NULL THEN RAISE EXCEPTION 'Scenario 4: expected daily row for 2026-01-01'; END IF;
    IF r2.import_consumption_kwh IS DISTINCT FROM 0.010 OR r2.bucket_start IS DISTINCT FROM TIMESTAMPTZ '2025-12-31 18:30:00+00' THEN
        RAISE EXCEPTION 'Scenario 4: 2026-01-01 row mismatch: kwh=%, bucket_start=%', r2.import_consumption_kwh, r2.bucket_start;
    END IF;
END
$$;

-- Scenario 5 — Device D ("durability"): already-populated 15-minute per-flow
-- data survives the backfill re-run unchanged despite no native source, and
-- correctly propagates to hourly/daily.
DO $$
DECLARE d15 RECORD; dh RECORD; dd RECORD;
BEGIN
    SELECT * INTO d15 FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000003';
    IF (d15.import_gap_intervals, d15.export_gap_intervals, d15.import_reset_intervals, d15.export_reset_intervals, d15.import_rollover_intervals, d15.export_rollover_intervals)
       IS DISTINCT FROM (1::BIGINT,0::BIGINT,0::BIGINT,1::BIGINT,0::BIGINT,0::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 5: Device D 15-minute per-flow values changed unexpectedly after backfill (expected unchanged, no native source exists)';
    END IF;
    IF d15.import_consumption_kwh IS DISTINCT FROM 0.050 OR d15.export_consumption_kwh IS DISTINCT FROM 0.045 THEN
        RAISE EXCEPTION 'Scenario 5: Device D pre-existing kwh values changed unexpectedly after backfill';
    END IF;

    SELECT * INTO dh FROM analytics.energy_consumption_hourly WHERE device_id = '98300000-0000-0000-0000-000000000003' AND bucket_start = TIMESTAMPTZ '2026-02-01 09:00:00+00';
    IF dh IS NULL THEN RAISE EXCEPTION 'Scenario 5: expected an hourly row derived from Device D''s surviving 15-minute per-flow data'; END IF;
    IF (dh.import_gap_intervals, dh.export_gap_intervals, dh.import_reset_intervals, dh.export_reset_intervals)
       IS DISTINCT FROM (1::BIGINT,0::BIGINT,0::BIGINT,1::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 5: Device D hourly per-flow propagation mismatch';
    END IF;

    SELECT * INTO dd FROM analytics.energy_consumption_daily WHERE device_id = '98300000-0000-0000-0000-000000000003';
    IF dd IS NULL THEN RAISE EXCEPTION 'Scenario 5: expected a daily row derived from Device D''s surviving 15-minute per-flow data'; END IF;
    IF (dd.import_gap_intervals, dd.export_gap_intervals, dd.import_reset_intervals, dd.export_reset_intervals)
       IS DISTINCT FROM (1::BIGINT,0::BIGINT,0::BIGINT,1::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 5: Device D daily per-flow propagation mismatch';
    END IF;
END
$$;

-- Scenario 6 — Device E ("unreconstructable"): per-flow columns remain NULL
-- (never zeroed), pre-existing values unaffected, and NULL correctly
-- propagates through hourly/daily.
DO $$
DECLARE e15 RECORD; eh RECORD; ed RECORD;
BEGIN
    SELECT * INTO e15 FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000004';
    IF (e15.import_gap_intervals, e15.export_gap_intervals, e15.import_reset_intervals, e15.export_reset_intervals, e15.import_rollover_intervals, e15.export_rollover_intervals)
       IS DISTINCT FROM (NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 6: Device E per-flow columns were NOT left NULL (must never infer GOOD/zero from absent native source): %,%,%,%,%,%',
            e15.import_gap_intervals, e15.export_gap_intervals, e15.import_reset_intervals, e15.export_reset_intervals, e15.import_rollover_intervals, e15.export_rollover_intervals;
    END IF;
    IF e15.import_consumption_kwh IS DISTINCT FROM 0.030 OR e15.export_consumption_kwh IS DISTINCT FROM 0.025 THEN
        RAISE EXCEPTION 'Scenario 6: Device E pre-existing kwh values changed unexpectedly after backfill';
    END IF;

    SELECT * INTO eh FROM analytics.energy_consumption_hourly WHERE device_id = '98300000-0000-0000-0000-000000000004' AND bucket_start = TIMESTAMPTZ '2026-03-01 09:00:00+00';
    IF eh IS NULL THEN RAISE EXCEPTION 'Scenario 6: expected an hourly row (derivable from Device E''s existing kwh/combined data) even though per-flow is NULL'; END IF;
    IF eh.import_gap_intervals IS NOT NULL OR eh.export_gap_intervals IS NOT NULL THEN
        RAISE EXCEPTION 'Scenario 6: Device E hourly per-flow columns should propagate as NULL (SUM of NULL), got %/%', eh.import_gap_intervals, eh.export_gap_intervals;
    END IF;
    IF eh.import_consumption_kwh IS DISTINCT FROM 0.030 THEN
        RAISE EXCEPTION 'Scenario 6: Device E hourly kwh should still correctly sum from the 15-minute tier despite NULL per-flow columns';
    END IF;

    SELECT * INTO ed FROM analytics.energy_consumption_daily WHERE device_id = '98300000-0000-0000-0000-000000000004';
    IF ed IS NULL THEN RAISE EXCEPTION 'Scenario 6: expected a daily row for Device E'; END IF;
    IF ed.import_gap_intervals IS NOT NULL THEN
        RAISE EXCEPTION 'Scenario 6: Device E daily per-flow columns should propagate as NULL, got %', ed.import_gap_intervals;
    END IF;
END
$$;

-- =============================================================================
-- Scenario 7 — Idempotent rerun: identical backfill call over the same
-- range must produce byte-for-byte identical results.
-- =============================================================================

DO $$
DECLARE
    v_a_before RECORD; v_a_after RECORD;
    v_d_before RECORD; v_d_after RECORD;
    v_e_before RECORD; v_e_after RECORD;
BEGIN
    SELECT import_gap_intervals, export_gap_intervals, import_reset_intervals, export_reset_intervals, import_rollover_intervals, export_rollover_intervals, import_consumption_kwh, export_consumption_kwh
    INTO v_a_before FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000001' AND bucket_start = TIMESTAMPTZ '2026-01-01 09:15:00+00';

    SELECT import_gap_intervals, export_gap_intervals, import_reset_intervals, export_reset_intervals, import_rollover_intervals, export_rollover_intervals, import_consumption_kwh, export_consumption_kwh
    INTO v_d_before FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000003';

    SELECT import_gap_intervals, export_gap_intervals, import_reset_intervals, export_reset_intervals, import_rollover_intervals, export_rollover_intervals, import_consumption_kwh, export_consumption_kwh
    INTO v_e_before FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000004';

    PERFORM * FROM analytics.backfill_energy_consumption_per_flow_quality(
        TIMESTAMPTZ '2025-12-31 00:00:00+00', TIMESTAMPTZ '2026-04-01 00:00:00+00', INTERVAL '7 days'
    );

    SELECT import_gap_intervals, export_gap_intervals, import_reset_intervals, export_reset_intervals, import_rollover_intervals, export_rollover_intervals, import_consumption_kwh, export_consumption_kwh
    INTO v_a_after FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000001' AND bucket_start = TIMESTAMPTZ '2026-01-01 09:15:00+00';

    SELECT import_gap_intervals, export_gap_intervals, import_reset_intervals, export_reset_intervals, import_rollover_intervals, export_rollover_intervals, import_consumption_kwh, export_consumption_kwh
    INTO v_d_after FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000003';

    SELECT import_gap_intervals, export_gap_intervals, import_reset_intervals, export_reset_intervals, import_rollover_intervals, export_rollover_intervals, import_consumption_kwh, export_consumption_kwh
    INTO v_e_after FROM analytics.energy_consumption_15min WHERE device_id = '98300000-0000-0000-0000-000000000004';

    IF v_a_before IS DISTINCT FROM v_a_after THEN RAISE EXCEPTION 'Scenario 7: Device A row changed on backfill rerun (not idempotent)'; END IF;
    IF v_d_before IS DISTINCT FROM v_d_after THEN RAISE EXCEPTION 'Scenario 7: Device D row changed on backfill rerun (not idempotent)'; END IF;
    IF v_e_before IS DISTINCT FROM v_e_after THEN RAISE EXCEPTION 'Scenario 7: Device E row changed on backfill rerun (not idempotent)'; END IF;
END
$$;

ROLLBACK;

SELECT 'Energy consumption historical backfill contract assertions passed.' AS result;
