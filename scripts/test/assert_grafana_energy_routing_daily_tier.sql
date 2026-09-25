\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS — Phase 1D Grafana energy resolution-routing contract
--
-- Proves analytics.resolve_grafana_energy_routing_resolution's corrected
-- four-bracket tier progression (native/15m/1h/1d), and that the live
-- Grafana-facing entry point (analytics.get_grafana_asset_energy_intervals)
-- actually reaches the daily tier for long ranges end-to-end.
--
-- IMPORTANT (discovered this session, not assumed): analytics.v_energy_
-- reporting_hourly/daily are NOT reads of the Phase 1B persisted
-- analytics.energy_consumption_hourly/daily tables. They are live,
-- query-time GROUP BY aggregations over analytics.v_energy_reporting_15min
-- -> analytics.v_energy_semantic_rollup_15min -> analytics.v_energy_
-- consumption_native (verified via pg_get_viewdef against a live database
-- this session). Therefore this test seeds the NATIVE tier
-- (analytics.energy_consumption_1min), via a real call to the canonical
-- classifier analytics.classify_energy_register_delta(), exactly as Phase
-- 1B's own tests do -- it does not fake any canonical calculation, and it
-- does not seed the (uninvolved, for this call path) persisted hourly/daily
-- tables. All test records are created inside one transaction and rolled
-- back.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixture: one organization/site (Asia/Kolkata), one gateway, two devices
-- (each with its own asset + PRIMARY_METER relationship, since an asset may
-- have only one PRIMARY_METER device), one site-specific capture policy
-- fixed far in the past so every tested range resolves cleanly with no
-- capture-policy-change rejection. A second, unrelated organization proves
-- tenant isolation.
-- ---------------------------------------------------------------------------

INSERT INTO metadata.organizations (id, name, code, description, is_active)
VALUES
    ('96000000-0000-0000-0000-000000000001', 'Grafana Routing Contract Tenant', 'GRAFANA_ROUTING_CONTRACT', 'Disposable Phase 1D routing contract tenant', TRUE),
    ('96000000-0000-0000-0000-000000000002', 'Grafana Routing Contract Other Tenant', 'GRAFANA_ROUTING_CONTRACT_OTHER', 'Disposable Phase 1D tenant-isolation control tenant', TRUE);

INSERT INTO metadata.sites (id, organization_id, name, code, timezone, address, is_active)
VALUES ('96100000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-000000000001', 'Grafana Routing Contract Site', 'GRAFANA_ROUTING_CONTRACT_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE);

INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id)
VALUES ('96200000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-000000000001', '96100000-0000-0000-0000-000000000001', 'Grafana Routing Contract Gateway', 'GRC_GATEWAY_1');

INSERT INTO metadata.device_models (id, vendor, model, device_category_id)
SELECT '96250000-0000-0000-0000-000000000001', 'Routing Contract Test Vendor', 'Routing Contract Test Meter', dc.id
FROM config.device_categories dc
WHERE lower(dc.name) = 'energy meter';

-- Migration 263: analytics.get_canonical_energy_read now attributes via
-- metadata.asset_points, not PRIMARY_METER, so these devices need a
-- profile (asset_points has an FK to config.device_point_configuration,
-- populated only for profiled devices via the sync trigger).
INSERT INTO metadata.devices (id, organization_id, gateway_id, device_model_id, profile_id, name, external_id)
SELECT
    v.id, '96000000-0000-0000-0000-000000000001', '96200000-0000-0000-0000-000000000001', '96250000-0000-0000-0000-000000000001',
    (SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'),
    v.name, v.external_id
FROM (
    VALUES
        ('96300000-0000-0000-0000-000000000001'::uuid, 'Hourly Regression Device', 'GRC_DEVICE_HOURLY'),
        ('96300000-0000-0000-0000-000000000002'::uuid, 'Daily End-to-End Device', 'GRC_DEVICE_DAILY')
) AS v(id, name, external_id);

INSERT INTO metadata.assets (id, organization_id, site_id, name, external_id, metering_requirement)
VALUES
    ('96400000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-000000000001', '96100000-0000-0000-0000-000000000001', 'Hourly Regression Asset', 'GRC_ASSET_HOURLY', 'NOT_REQUIRED'),
    ('96400000-0000-0000-0000-000000000002', '96000000-0000-0000-0000-000000000001', '96100000-0000-0000-0000-000000000001', 'Daily End-to-End Asset', 'GRC_ASSET_DAILY', 'NOT_REQUIRED');

INSERT INTO metadata.asset_devices (asset_id, device_id, relationship_type)
VALUES
    ('96400000-0000-0000-0000-000000000001', '96300000-0000-0000-0000-000000000001', 'PRIMARY_METER'),
    ('96400000-0000-0000-0000-000000000002', '96300000-0000-0000-0000-000000000002', 'PRIMARY_METER');

-- Migration 263 attribution: confirm both ENERGY_IMPORT_TOTAL and
-- ENERGY_EXPORT_TOTAL on each asset's own device, open-ended and well
-- before every range this test exercises.
INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
SELECT a.asset_id, a.device_id, lp.id, '96000000-0000-0000-0000-000000000001', TIMESTAMPTZ '2026-06-01 00:00:00+00' - INTERVAL '2000 days', NULL
FROM (
    VALUES
        ('96400000-0000-0000-0000-000000000001'::uuid, '96300000-0000-0000-0000-000000000001'::uuid),
        ('96400000-0000-0000-0000-000000000002'::uuid, '96300000-0000-0000-0000-000000000002'::uuid)
) AS a(asset_id, device_id)
CROSS JOIN metadata.logical_points lp
WHERE lp.name IN ('ENERGY_IMPORT_TOTAL', 'ENERGY_EXPORT_TOTAL');

INSERT INTO metadata.grafana_organization_map (grafana_org_id, organization_id, is_active)
VALUES
    (966001, '96000000-0000-0000-0000-000000000001', TRUE),
    (966002, '96000000-0000-0000-0000-000000000002', TRUE);

INSERT INTO config.telemetry_capture_policies
(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
VALUES
('96100000-0000-0000-0000-000000000001', 60, 'WALL_CLOCK', 900, TIMESTAMPTZ '2026-06-01 00:00:00+00' - INTERVAL '2000 days', TRUE);

-- ---------------------------------------------------------------------------
-- Native-tier data, seeded via a real call to the canonical classifier
-- (analytics.classify_energy_register_delta), exactly as Phase 1B's own
-- contract test does. Reference instant fixed for determinism.
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
    fixture.bucket_start, '96000000-0000-0000-0000-000000000001', '96100000-0000-0000-0000-000000000001', fixture.device_id,
    fixture.bucket_start - INTERVAL '1 minute', 1, 1,
    fixture.import_current, fixture.import_previous, import_result.delta_wh, import_result.delta_wh / 1000.0,
    import_result.quality_code, import_result.is_valid, import_result.reset_detected, import_result.rollover_detected,
    fixture.export_current, fixture.export_previous, export_result.delta_wh, export_result.delta_wh / 1000.0,
    export_result.quality_code, export_result.is_valid, export_result.reset_detected, export_result.rollover_detected,
    FALSE, NULL, 5, 'TEST', 'TEST'
FROM
(
    VALUES
        -- Hourly-regression device: one native interval inside a 30-day range.
        ('96300000-0000-0000-0000-000000000001'::uuid, TIMESTAMPTZ '2026-06-02 09:00:00+00', 1010::numeric, 1000::numeric, 2005::numeric, 2000::numeric),
        -- Daily end-to-end device: one native interval inside a >90-day range.
        ('96300000-0000-0000-0000-000000000002'::uuid, TIMESTAMPTZ '2026-07-21 09:00:00+00', 2010::numeric, 2000::numeric, 3005::numeric, 3000::numeric)
) AS fixture(device_id, bucket_start, import_current, import_previous, export_current, export_previous)

CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    fixture.import_current, fixture.import_previous, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5
) import_result

CROSS JOIN LATERAL analytics.classify_energy_register_delta
(
    fixture.export_current, fixture.export_previous, 1, 'INCREASING', 'NONE', NULL, 'REJECT_DELTA', 500, 5
) export_result;

DO $$
DECLARE
    v_codes TEXT[];
BEGIN
    SELECT array_agg(import_quality_code ORDER BY bucket_start)
    INTO v_codes
    FROM analytics.energy_consumption_1min
    WHERE device_id IN ('96300000-0000-0000-0000-000000000001', '96300000-0000-0000-0000-000000000002');

    IF v_codes IS DISTINCT FROM ARRAY['GOOD','GOOD'] THEN
        RAISE EXCEPTION 'Fixture setup error: expected classifier codes [GOOD,GOOD], got %', v_codes;
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 1 — Pure router assertions (no fixture dependency; the router is
-- an IMMUTABLE function with no table dependency).
-- =============================================================================

DO $$
DECLARE
    v_ref TIMESTAMPTZ := TIMESTAMPTZ '2026-06-01 00:00:00+00';
    v_result TEXT;
BEGIN
    v_result := analytics.resolve_grafana_energy_routing_resolution(v_ref, v_ref + INTERVAL '12 hours');
    IF v_result IS DISTINCT FROM 'native' THEN
        RAISE EXCEPTION 'Router: expected ''native'' for a 12-hour range, got %', v_result;
    END IF;

    v_result := analytics.resolve_grafana_energy_routing_resolution(v_ref, v_ref + INTERVAL '7 days');
    IF v_result IS DISTINCT FROM '15m' THEN
        RAISE EXCEPTION 'Router: expected ''15m'' for a 7-day range, got %', v_result;
    END IF;

    v_result := analytics.resolve_grafana_energy_routing_resolution(v_ref, v_ref + INTERVAL '30 days');
    IF v_result IS DISTINCT FROM '1h' THEN
        RAISE EXCEPTION 'Router: expected ''1h'' for a 30-day range, got %', v_result;
    END IF;

    v_result := analytics.resolve_grafana_energy_routing_resolution(v_ref, v_ref + INTERVAL '90 days');
    IF v_result IS DISTINCT FROM '1h' THEN
        RAISE EXCEPTION 'Router: expected ''1h'' at the exact 90-day boundary, got %', v_result;
    END IF;

    v_result := analytics.resolve_grafana_energy_routing_resolution(v_ref, v_ref + INTERVAL '91 days');
    IF v_result IS DISTINCT FROM '1d' THEN
        RAISE EXCEPTION 'Router: expected ''1d'' for a 91-day range, got %', v_result;
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 2 — Hourly regression guard: a <=90-day long range must still
-- reach the hourly tier end-to-end through the real, unmodified
-- get_grafana_asset_energy_intervals -> get_canonical_energy_read chain.
-- =============================================================================

DO $$
DECLARE
    v_ref TIMESTAMPTZ := TIMESTAMPTZ '2026-06-01 00:00:00+00';
    r RECORD;
    v_count INTEGER;
BEGIN
    SELECT count(*) INTO v_count
    FROM analytics.get_grafana_asset_energy_intervals(
        966001, '96400000-0000-0000-0000-000000000001', v_ref, v_ref + INTERVAL '30 days'
    );

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Scenario 2: expected exactly 1 row for the 30-day hourly-regression range, got %', v_count;
    END IF;

    SELECT * INTO r
    FROM analytics.get_grafana_asset_energy_intervals(
        966001, '96400000-0000-0000-0000-000000000001', v_ref, v_ref + INTERVAL '30 days'
    );

    IF r.elapsed_minutes IS DISTINCT FROM 60 THEN
        RAISE EXCEPTION 'Scenario 2: expected elapsed_minutes 60 (hourly), got %', r.elapsed_minutes;
    END IF;

    IF r.import_consumption_kwh IS DISTINCT FROM 0.010 THEN
        RAISE EXCEPTION 'Scenario 2: expected import_consumption_kwh 0.010, got %', r.import_consumption_kwh;
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 3 — Daily end-to-end: a >90-day range must reach the daily tier
-- end-to-end through the real, unmodified function chain.
-- =============================================================================

DO $$
DECLARE
    v_ref TIMESTAMPTZ := TIMESTAMPTZ '2026-06-01 00:00:00+00';
    r RECORD;
    v_count INTEGER;
BEGIN
    SELECT count(*) INTO v_count
    FROM analytics.get_grafana_asset_energy_intervals(
        966001, '96400000-0000-0000-0000-000000000002', v_ref, v_ref + INTERVAL '91 days'
    );

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Scenario 3: expected exactly 1 row for the 91-day daily end-to-end range, got %', v_count;
    END IF;

    SELECT * INTO r
    FROM analytics.get_grafana_asset_energy_intervals(
        966001, '96400000-0000-0000-0000-000000000002', v_ref, v_ref + INTERVAL '91 days'
    );

    IF r.elapsed_minutes IS DISTINCT FROM 1440 THEN
        RAISE EXCEPTION 'Scenario 3: expected elapsed_minutes 1440 (daily), got %', r.elapsed_minutes;
    END IF;

    IF r.import_consumption_kwh IS DISTINCT FROM 0.010 THEN
        RAISE EXCEPTION 'Scenario 3: expected import_consumption_kwh 0.010, got %', r.import_consumption_kwh;
    END IF;
END
$$;

-- =============================================================================
-- SCENARIO 4 — Tenant isolation: the same >90-day query, issued under an
-- unrelated organization's grafana_org_id, must return zero rows.
-- =============================================================================

DO $$
DECLARE
    v_ref TIMESTAMPTZ := TIMESTAMPTZ '2026-06-01 00:00:00+00';
    v_count INTEGER;
BEGIN
    SELECT count(*) INTO v_count
    FROM analytics.get_grafana_asset_energy_intervals(
        966002, '96400000-0000-0000-0000-000000000002', v_ref, v_ref + INTERVAL '91 days'
    );

    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Scenario 4: expected 0 rows when querying another organization''s grafana_org_id against this asset, got %', v_count;
    END IF;
END
$$;

ROLLBACK;

SELECT 'Grafana energy resolution-routing contract assertions passed.' AS result;
