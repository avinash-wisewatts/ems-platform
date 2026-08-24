\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS — Phase 1E-A per-flow quality persistence contract
--
-- Proves that the six per-flow quality columns (import/export gap, reset,
-- rollover interval counts) already computed by analytics.v_energy_
-- semantic_rollup_15min are now correctly carried, unmodified in meaning,
-- through the real, unmodified refresh_energy_consumption_15min/hourly/
-- daily() functions into the persisted analytics.energy_consumption_
-- {15min,hourly,daily} tables -- and that the existing combined counters
-- and consumption-kwh semantics (GAP contributes, RESET excluded, ROLLOVER
-- contributes, per Phase 1B) are completely unaffected.
--
-- No new classification logic is exercised or asserted here -- every
-- native-tier row is produced by a real call to the canonical
-- analytics.classify_energy_register_delta(), exactly as Phase 1B's own
-- tests do. This test only proves the write-path no longer discards
-- already-computed per-flow information.
--
-- Fixture: two organizations/sites/devices. Device A carries seven native
-- intervals, one per 15-minute bucket, each exercising exactly one of the
-- seven required import/export quality combinations. Device B (a
-- different organization) carries a single GOOD/GOOD interval, used only
-- to prove no cross-tenant contamination in the persisted write path.
--
-- All test records are created inside one transaction and rolled back.
-- =============================================================================

BEGIN;

INSERT INTO metadata.organizations (id, name, code, description, is_active)
VALUES
    ('97000000-0000-0000-0000-000000000001', 'Per-Flow Quality Contract Tenant', 'PER_FLOW_QUALITY_CONTRACT', 'Disposable Phase 1E-A per-flow quality contract tenant', TRUE),
    ('97000000-0000-0000-0000-000000000002', 'Per-Flow Quality Contract Other Tenant', 'PER_FLOW_QUALITY_CONTRACT_OTHER', 'Disposable Phase 1E-A tenant-isolation control tenant', TRUE);

INSERT INTO metadata.sites (id, organization_id, name, code, timezone, address, is_active)
VALUES
    ('97100000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-000000000001', 'Per-Flow Quality Contract Site', 'PER_FLOW_QUALITY_CONTRACT_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE),
    ('97100000-0000-0000-0000-000000000002', '97000000-0000-0000-0000-000000000002', 'Per-Flow Quality Contract Other Site', 'PER_FLOW_QUALITY_CONTRACT_OTHER_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE);

-- ---------------------------------------------------------------------------
-- Native-tier data, device A: seven native 1-minute intervals, each in its
-- own 15-minute-aligned bucket, each row independently classified via a
-- real call to the canonical classifier for both import and export.
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
    fixture.bucket_start, '97000000-0000-0000-0000-000000000001', '97100000-0000-0000-0000-000000000001', '97300000-0000-0000-0000-000000000001',
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
        -- label,                    bucket_start,                          import: elapsed,cur,prev,rollover_behavior,rollover_value | export: elapsed,cur,prev,rollover_behavior,rollover_value
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

-- Tenant-isolation control: device B, a single GOOD/GOOD interval, same
-- UTC bucket as device A's first row, different organization entirely.
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
    TIMESTAMPTZ '2026-01-01 09:00:00+00', '97000000-0000-0000-0000-000000000002', '97100000-0000-0000-0000-000000000002', '97300000-0000-0000-0000-000000000002',
    TIMESTAMPTZ '2026-01-01 08:59:00+00', 1, 1,
    3010, 3000, import_result.delta_wh, import_result.delta_wh / 1000.0,
    import_result.quality_code, import_result.is_valid, import_result.reset_detected, import_result.rollover_detected,
    4010, 4000, export_result.delta_wh, export_result.delta_wh / 1000.0,
    export_result.quality_code, export_result.is_valid, export_result.reset_detected, export_result.rollover_detected,
    FALSE, NULL, 5, 'TEST', 'TEST'
FROM (SELECT 1) AS one_row
CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    3010, 3000, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5
) import_result
CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    4010, 4000, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5
) export_result;

-- Fixture sanity check: confirm the classifier actually produced the
-- seven distinct import/export combinations this test depends on.
DO $$
DECLARE
    v_import_codes TEXT[];
    v_export_codes TEXT[];
BEGIN
    SELECT array_agg(import_quality_code ORDER BY bucket_start), array_agg(export_quality_code ORDER BY bucket_start)
    INTO v_import_codes, v_export_codes
    FROM analytics.energy_consumption_1min
    WHERE device_id = '97300000-0000-0000-0000-000000000001';

    IF v_import_codes IS DISTINCT FROM ARRAY['GOOD','GAP','GOOD','RESET','GOOD','ROLLOVER','GOOD'] THEN
        RAISE EXCEPTION 'Fixture setup error: expected import codes [GOOD,GAP,GOOD,RESET,GOOD,ROLLOVER,GOOD], got %', v_import_codes;
    END IF;

    IF v_export_codes IS DISTINCT FROM ARRAY['GOOD','GOOD','GAP','GOOD','RESET','GOOD','ROLLOVER'] THEN
        RAISE EXCEPTION 'Fixture setup error: expected export codes [GOOD,GOOD,GAP,GOOD,RESET,GOOD,ROLLOVER], got %', v_export_codes;
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 1 — 15-minute persistence: exact per-flow and combined columns
-- for each of the seven independently-classified buckets.
-- =============================================================================

SELECT analytics.refresh_energy_consumption_15min(TIMESTAMPTZ '2026-01-01 09:00:00+00', TIMESTAMPTZ '2026-01-01 10:45:00+00');

DO $$
DECLARE
    v_import_gap BIGINT[];
    v_export_gap BIGINT[];
    v_import_reset BIGINT[];
    v_export_reset BIGINT[];
    v_import_rollover BIGINT[];
    v_export_rollover BIGINT[];
    v_gap_combined BIGINT[];
    v_reset_combined BIGINT[];
    v_rollover_combined BIGINT[];
    v_invalid_combined BIGINT[];
    v_import_kwh NUMERIC[];
    v_export_kwh NUMERIC[];
BEGIN
    SELECT
        array_agg(import_gap_intervals ORDER BY bucket_start),
        array_agg(export_gap_intervals ORDER BY bucket_start),
        array_agg(import_reset_intervals ORDER BY bucket_start),
        array_agg(export_reset_intervals ORDER BY bucket_start),
        array_agg(import_rollover_intervals ORDER BY bucket_start),
        array_agg(export_rollover_intervals ORDER BY bucket_start),
        array_agg(gap_interval_count ORDER BY bucket_start),
        array_agg(reset_interval_count ORDER BY bucket_start),
        array_agg(rollover_interval_count ORDER BY bucket_start),
        array_agg(invalid_interval_count ORDER BY bucket_start),
        array_agg(import_consumption_kwh ORDER BY bucket_start),
        array_agg(export_consumption_kwh ORDER BY bucket_start)
    INTO
        v_import_gap, v_export_gap, v_import_reset, v_export_reset, v_import_rollover, v_export_rollover,
        v_gap_combined, v_reset_combined, v_rollover_combined, v_invalid_combined,
        v_import_kwh, v_export_kwh
    FROM analytics.energy_consumption_15min
    WHERE device_id = '97300000-0000-0000-0000-000000000001';

    -- Buckets in order: GOOD/GOOD, GAP/GOOD, GOOD/GAP, RESET/GOOD, GOOD/RESET, ROLLOVER/GOOD, GOOD/ROLLOVER
    IF v_import_gap IS DISTINCT FROM ARRAY[0,1,0,0,0,0,0]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: import_gap_intervals mismatch: %', v_import_gap;
    END IF;
    IF v_export_gap IS DISTINCT FROM ARRAY[0,0,1,0,0,0,0]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: export_gap_intervals mismatch: %', v_export_gap;
    END IF;
    IF v_import_reset IS DISTINCT FROM ARRAY[0,0,0,1,0,0,0]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: import_reset_intervals mismatch: %', v_import_reset;
    END IF;
    IF v_export_reset IS DISTINCT FROM ARRAY[0,0,0,0,1,0,0]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: export_reset_intervals mismatch: %', v_export_reset;
    END IF;
    IF v_import_rollover IS DISTINCT FROM ARRAY[0,0,0,0,0,1,0]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: import_rollover_intervals mismatch: %', v_import_rollover;
    END IF;
    IF v_export_rollover IS DISTINCT FROM ARRAY[0,0,0,0,0,0,1]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: export_rollover_intervals mismatch: %', v_export_rollover;
    END IF;

    -- Combined counters (pre-existing behavior) must remain exactly as before this migration.
    IF v_gap_combined IS DISTINCT FROM ARRAY[0,1,1,0,0,0,0]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: combined gap_interval_count mismatch: %', v_gap_combined;
    END IF;
    IF v_reset_combined IS DISTINCT FROM ARRAY[0,0,0,1,1,0,0]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: combined reset_interval_count mismatch: %', v_reset_combined;
    END IF;
    IF v_rollover_combined IS DISTINCT FROM ARRAY[0,0,0,0,0,1,1]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: combined rollover_interval_count mismatch: %', v_rollover_combined;
    END IF;
    IF v_invalid_combined IS DISTINCT FROM ARRAY[0,0,0,1,1,0,0]::BIGINT[] THEN
        RAISE EXCEPTION 'Scenario 1: combined invalid_interval_count mismatch: %', v_invalid_combined;
    END IF;

    -- Consumption sums: GAP and ROLLOVER contribute; RESET is excluded (Phase 1B semantics, unaffected by this migration).
    IF v_import_kwh IS DISTINCT FROM ARRAY[0.010,0.020,0.010,NULL,0.010,0.060,0.010]::NUMERIC[] THEN
        RAISE EXCEPTION 'Scenario 1: import_consumption_kwh mismatch: %', v_import_kwh;
    END IF;
    IF v_export_kwh IS DISTINCT FROM ARRAY[0.010,0.010,0.020,0.010,NULL,0.010,0.060]::NUMERIC[] THEN
        RAISE EXCEPTION 'Scenario 1: export_consumption_kwh mismatch: %', v_export_kwh;
    END IF;
END
$$;

-- Tenant-isolation control at the 15-minute tier.
DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r
    FROM analytics.energy_consumption_15min
    WHERE device_id = '97300000-0000-0000-0000-000000000002';

    IF r IS NULL THEN
        RAISE EXCEPTION 'Tenant control: expected a 15-minute row for device B';
    END IF;

    IF r.organization_id IS DISTINCT FROM '97000000-0000-0000-0000-000000000002' THEN
        RAISE EXCEPTION 'Tenant control: device B row shows organization_id %, expected org B (no cross-tenant contamination)', r.organization_id;
    END IF;

    IF (r.import_gap_intervals, r.export_gap_intervals, r.import_reset_intervals, r.export_reset_intervals, r.import_rollover_intervals, r.export_rollover_intervals)
       IS DISTINCT FROM (0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT) THEN
        RAISE EXCEPTION 'Tenant control: device B (GOOD/GOOD only) shows unexpected non-zero per-flow quality counters';
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 2 — Hourly aggregation preserves the six per-flow semantics,
-- summed additively from the 15-minute tier only.
-- =============================================================================

SELECT analytics.refresh_energy_consumption_hourly(TIMESTAMPTZ '2026-01-01 09:00:00+00', TIMESTAMPTZ '2026-01-01 11:00:00+00');

DO $$
DECLARE
    h9 RECORD;
    h10 RECORD;
BEGIN
    SELECT * INTO h9 FROM analytics.energy_consumption_hourly
    WHERE device_id = '97300000-0000-0000-0000-000000000001' AND bucket_start = TIMESTAMPTZ '2026-01-01 09:00:00+00';

    IF h9 IS NULL THEN
        RAISE EXCEPTION 'Scenario 2: expected an hourly row for 09:00 (buckets GOOD/GOOD, GAP/GOOD, GOOD/GAP, RESET/GOOD)';
    END IF;

    IF (h9.import_gap_intervals, h9.export_gap_intervals, h9.import_reset_intervals, h9.export_reset_intervals, h9.import_rollover_intervals, h9.export_rollover_intervals)
       IS DISTINCT FROM (1::BIGINT, 1::BIGINT, 1::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 2: hour 09:00 per-flow counts mismatch: gap=(%,%) reset=(%,%) rollover=(%,%)',
            h9.import_gap_intervals, h9.export_gap_intervals, h9.import_reset_intervals, h9.export_reset_intervals, h9.import_rollover_intervals, h9.export_rollover_intervals;
    END IF;

    IF h9.import_consumption_kwh IS DISTINCT FROM 0.040 OR h9.export_consumption_kwh IS DISTINCT FROM 0.050 THEN
        RAISE EXCEPTION 'Scenario 2: hour 09:00 expected import/export kwh 0.040/0.050 (import: 10+20+10 excluding RESET; export: 10+10+20+10, RESET is on the import side this hour), got %/%', h9.import_consumption_kwh, h9.export_consumption_kwh;
    END IF;

    SELECT * INTO h10 FROM analytics.energy_consumption_hourly
    WHERE device_id = '97300000-0000-0000-0000-000000000001' AND bucket_start = TIMESTAMPTZ '2026-01-01 10:00:00+00';

    IF h10 IS NULL THEN
        RAISE EXCEPTION 'Scenario 2: expected an hourly row for 10:00 (buckets GOOD/RESET, ROLLOVER/GOOD, GOOD/ROLLOVER)';
    END IF;

    IF (h10.import_gap_intervals, h10.export_gap_intervals, h10.import_reset_intervals, h10.export_reset_intervals, h10.import_rollover_intervals, h10.export_rollover_intervals)
       IS DISTINCT FROM (0::BIGINT, 0::BIGINT, 0::BIGINT, 1::BIGINT, 1::BIGINT, 1::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 2: hour 10:00 per-flow counts mismatch: gap=(%,%) reset=(%,%) rollover=(%,%)',
            h10.import_gap_intervals, h10.export_gap_intervals, h10.import_reset_intervals, h10.export_reset_intervals, h10.import_rollover_intervals, h10.export_rollover_intervals;
    END IF;

    IF h10.import_consumption_kwh IS DISTINCT FROM 0.080 OR h10.export_consumption_kwh IS DISTINCT FROM 0.070 THEN
        RAISE EXCEPTION 'Scenario 2: hour 10:00 expected import/export kwh 0.080/0.070 (import: 10+60+10; export: 10+60 excluding RESET on the export side), got %/%', h10.import_consumption_kwh, h10.export_consumption_kwh;
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 3 — Daily aggregation preserves the six per-flow semantics,
-- summed from the 15-minute tier only, with site-local-timezone bucketing
-- unchanged from Phase 1B.
-- =============================================================================

SELECT analytics.refresh_energy_consumption_daily(TIMESTAMPTZ '2026-01-01 00:00:00+00', TIMESTAMPTZ '2026-01-02 00:00:00+00');

DO $$
DECLARE
    d RECORD;
BEGIN
    SELECT * INTO d FROM analytics.energy_consumption_daily
    WHERE device_id = '97300000-0000-0000-0000-000000000001';

    IF d IS NULL THEN
        RAISE EXCEPTION 'Scenario 3: expected a daily row for device A';
    END IF;

    IF d.site_timezone IS DISTINCT FROM 'Asia/Kolkata' THEN
        RAISE EXCEPTION 'Scenario 3: expected site_timezone Asia/Kolkata, got %', d.site_timezone;
    END IF;

    IF (d.import_gap_intervals, d.export_gap_intervals, d.import_reset_intervals, d.export_reset_intervals, d.import_rollover_intervals, d.export_rollover_intervals)
       IS DISTINCT FROM (1::BIGINT, 1::BIGINT, 1::BIGINT, 1::BIGINT, 1::BIGINT, 1::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 3: daily per-flow counts mismatch: gap=(%,%) reset=(%,%) rollover=(%,%)',
            d.import_gap_intervals, d.export_gap_intervals, d.import_reset_intervals, d.export_reset_intervals, d.import_rollover_intervals, d.export_rollover_intervals;
    END IF;

    IF (d.gap_interval_count, d.reset_interval_count, d.rollover_interval_count, d.invalid_interval_count)
       IS DISTINCT FROM (2::BIGINT, 2::BIGINT, 2::BIGINT, 2::BIGINT) THEN
        RAISE EXCEPTION 'Scenario 3: daily combined counts mismatch: gap=%, reset=%, rollover=%, invalid=%',
            d.gap_interval_count, d.reset_interval_count, d.rollover_interval_count, d.invalid_interval_count;
    END IF;

    IF d.import_consumption_kwh IS DISTINCT FROM 0.120 OR d.export_consumption_kwh IS DISTINCT FROM 0.120 THEN
        RAISE EXCEPTION 'Scenario 3: expected daily import/export kwh 0.120/0.120, got %/%', d.import_consumption_kwh, d.export_consumption_kwh;
    END IF;

    IF d.source_interval_count <> 7 THEN
        RAISE EXCEPTION 'Scenario 3: expected source_interval_count 7, got %', d.source_interval_count;
    END IF;
END
$$;

-- Tenant-isolation control at the daily tier.
DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r FROM analytics.energy_consumption_daily
    WHERE device_id = '97300000-0000-0000-0000-000000000002';

    IF r IS NULL THEN
        RAISE EXCEPTION 'Tenant control: expected a daily row for device B';
    END IF;

    IF r.organization_id IS DISTINCT FROM '97000000-0000-0000-0000-000000000002' THEN
        RAISE EXCEPTION 'Tenant control: device B daily row shows organization_id %, expected org B', r.organization_id;
    END IF;

    IF (r.import_gap_intervals, r.export_gap_intervals, r.import_reset_intervals, r.export_reset_intervals, r.import_rollover_intervals, r.export_rollover_intervals)
       IS DISTINCT FROM (0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT) THEN
        RAISE EXCEPTION 'Tenant control: device B daily row shows unexpected non-zero per-flow quality counters';
    END IF;
END
$$;

ROLLBACK;

SELECT 'Energy consumption per-flow quality persistence contract assertions passed.' AS result;
