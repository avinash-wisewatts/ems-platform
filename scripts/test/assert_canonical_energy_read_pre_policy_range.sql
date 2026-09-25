-- ============================================================================
-- File:
--   scripts/test/assert_canonical_energy_read_pre_policy_range.sql
--
-- Purpose:
--   Regression test for migration 200: analytics.get_canonical_energy_read()
--   previously raised "no capture policy resolvable for site % at %"
--   whenever the requested p_from fell before the earliest capture policy a
--   site had ever had -- even though this only means "no telemetry could
--   ever have existed there," not a real misconfiguration. This broke the
--   Asset Dashboard's "Energy Consumption Trend" panel for any long
--   historical range on a recently-commissioned site (2026-08-25 live
--   investigation).
--
--   This test proves, against a fully synthetic, rollback-only fixture:
--     A. a range fully within the configured/data era still returns data,
--        unchanged;
--     B. a range before commissioning (before the earliest applicable
--        policy) returns zero rows rather than raising -- both when the
--        entire range predates the policy, and when the range straddles
--        the policy boundary;
--     C. a genuine gap between two policies inside an otherwise-configured
--        era still raises exactly as before -- this migration does not
--        blindly suppress real configuration errors;
--     D. tenant/asset scoping is unchanged (a mismatched grafana_org_id
--        still yields zero rows, not another tenant's data);
--     E. the exact parameters the Asset Dashboard panel uses
--        ('native', 'strict') behave correctly for both a normal recent
--        range and the previously-failing long historical range.
--
--   Everything here runs inside one transaction that is rolled back at the
--   end -- no fixture data ever persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_org               UUID;
    v_site              UUID;
    v_gateway           UUID;
    v_device            UUID;
    v_asset             UUID;
    v_grafana_org_id    BIGINT := 900001;

    v_org2              UUID;
    v_site2             UUID;
    v_gateway2          UUID;
    v_device2           UUID;
    v_asset2            UUID;
    v_grafana_org_id2   BIGINT := 900002;

    v_now               TIMESTAMPTZ := date_trunc('minute', now());
    v_policy_from       TIMESTAMPTZ;
    v_data_from         TIMESTAMPTZ;

    v_result_count      INT;
    v_row               RECORD;
    v_raised            BOOLEAN;
    v_error_message     TEXT;

    v_energy_category   UUID;
    v_device_model      UUID;

    v_import_point_id   UUID;
    v_export_point_id   UUID;
    v_profile_id        UUID;
BEGIN
    -- ------------------------------------------------------------------
    -- Shared fixture: one org/site/gateway/device/asset, PRIMARY_METER
    -- linked, with a capture policy starting v_policy_from and real
    -- energy_consumption_1min data only from v_data_from onward (mirrors
    -- the real observed shape: policy configured before data exists).
    -- ------------------------------------------------------------------

    v_policy_from := v_now - INTERVAL '10 days';
    v_data_from   := v_now - INTERVAL '5 days';

    SELECT id INTO v_energy_category
    FROM config.device_categories
    WHERE lower(name) = 'energy meter'
    LIMIT 1;

    IF v_energy_category IS NULL THEN
        RAISE EXCEPTION 'Fixture requires an Energy Meter device category on the canonical database';
    END IF;

    SELECT id INTO v_import_point_id FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL';
    SELECT id INTO v_export_point_id FROM metadata.logical_points WHERE name = 'ENERGY_EXPORT_TOTAL';

    IF v_import_point_id IS NULL OR v_export_point_id IS NULL THEN
        RAISE EXCEPTION 'Fixture requires ENERGY_IMPORT_TOTAL and ENERGY_EXPORT_TOTAL logical points';
    END IF;

    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the ENERGY_METER_ENISCOPE_V1 device profile (metadata.asset_points has an FK to config.device_point_configuration, populated only for profiled devices)';
    END IF;

    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Canonical Energy Read Test Meter', 'Energy Meter', v_energy_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Canonical Energy Read Test Org', 'CANON_ENERGY_TEST_ORG', 'Asia/Kolkata')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'Canonical Energy Read Test Site', 'CANON_ENERGY_TEST_SITE', 'Asia/Kolkata', TRUE)
    RETURNING id INTO v_site;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Canonical Energy Read Test Gateway', 'CANON-ENERGY-GW')
    RETURNING id INTO v_gateway;

    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Canonical Energy Read Test Device', 'CANON-ENERGY-DEV')
    RETURNING id INTO v_device;

    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Canonical Energy Read Test Asset', 'CANON_ENERGY_ASSET', 'DIRECT_METER_REQUIRED', 'ACTIVE')
    RETURNING id INTO v_asset;

    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset, v_device, 'PRIMARY_METER');

    -- Migration 263: attribution now reads metadata.asset_points, not
    -- PRIMARY_METER (the asset_devices row above is left in place as
    -- harmless, now-unused metadata). Effective from well before every
    -- range this test exercises, open-ended, so it never adds any
    -- additional clipping beyond what each TEST already expects from
    -- capture-policy resolution alone.
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES
        (v_asset, v_device, v_import_point_id, v_org, v_now - INTERVAL '10 years', NULL),
        (v_asset, v_device, v_export_point_id, v_org, v_now - INTERVAL '10 years', NULL);

    INSERT INTO metadata.grafana_organization_map(grafana_org_id, organization_id, is_active)
    VALUES (v_grafana_org_id, v_org, TRUE);

    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site, 60, 'WALL_CLOCK', 60, v_policy_from, TRUE);

    -- Three 1-minute rows of real data, all after v_data_from (well after
    -- v_policy_from, mirroring the real gap between "policy configured"
    -- and "device actually started producing telemetry").
    INSERT INTO analytics.energy_consumption_1min(
        bucket_start, organization_id, site_id, device_id,
        import_consumption_kwh, import_quality_code, import_is_valid,
        import_reset_detected, import_rollover_detected,
        export_consumption_kwh, export_quality_code, export_is_valid,
        export_reset_detected, export_rollover_detected, gap_detected
    ) VALUES
        (v_data_from,                      v_org, v_site, v_device, 1.0, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE),
        (v_data_from + INTERVAL '1 minute', v_org, v_site, v_device, 1.1, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE),
        (v_data_from + INTERVAL '2 minutes',v_org, v_site, v_device, 1.2, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE);

    -- ==================================================================
    -- TEST A -- a range fully within the configured/data era still
    -- returns data, unchanged.
    -- ==================================================================

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(
        v_grafana_org_id, v_asset,
        v_data_from, v_data_from + INTERVAL '3 minutes',
        'native', 'strict'
    );

    IF v_result_count <> 3 THEN
        RAISE EXCEPTION 'TEST A FAILED: expected 3 rows for a range fully within the data era, got %', v_result_count;
    END IF;

    RAISE NOTICE 'TEST A passed: current valid energy range returns data unchanged (% rows).', v_result_count;

    -- ==================================================================
    -- TEST B1 -- a range entirely before the earliest applicable policy
    -- returns zero rows, not an exception.
    -- ==================================================================

    v_raised := FALSE;
    BEGIN
        SELECT count(*) INTO v_result_count
        FROM analytics.get_canonical_energy_read(
            v_grafana_org_id, v_asset,
            v_policy_from - INTERVAL '20 days', v_policy_from - INTERVAL '10 days',
            'native', 'strict'
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_raised := TRUE;
            v_error_message := SQLERRM;
    END;

    IF v_raised THEN
        RAISE EXCEPTION 'TEST B1 FAILED: a range entirely before the earliest policy raised instead of returning empty: %', v_error_message;
    END IF;

    IF v_result_count <> 0 THEN
        RAISE EXCEPTION 'TEST B1 FAILED: expected 0 rows for a range entirely before the earliest policy, got %', v_result_count;
    END IF;

    RAISE NOTICE 'TEST B1 passed: range entirely before commissioning returns zero rows, no exception.';

    -- ==================================================================
    -- TEST B2 -- a range that straddles the policy boundary (starts
    -- before the earliest policy, ends after real data begins) also does
    -- not raise, and returns exactly the real data that exists.
    -- ==================================================================

    v_raised := FALSE;
    BEGIN
        SELECT count(*) INTO v_result_count
        FROM analytics.get_canonical_energy_read(
            v_grafana_org_id, v_asset,
            v_policy_from - INTERVAL '30 days', v_data_from + INTERVAL '3 minutes',
            'native', 'strict'
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_raised := TRUE;
            v_error_message := SQLERRM;
    END;

    IF v_raised THEN
        RAISE EXCEPTION 'TEST B2 FAILED: a range straddling the policy boundary raised instead of clipping: %', v_error_message;
    END IF;

    IF v_result_count <> 3 THEN
        RAISE EXCEPTION 'TEST B2 FAILED: expected exactly the 3 real rows for a straddling range, got %', v_result_count;
    END IF;

    RAISE NOTICE 'TEST B2 passed: range straddling the policy boundary is clipped, not rejected, and returns exactly the real data (% rows).', v_result_count;

    -- ==================================================================
    -- TEST C -- a genuine gap between two policies inside an otherwise-
    -- configured era still raises. Uses a second, independent site so
    -- the gap fixture cannot interact with the tests above.
    -- ==================================================================

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Canonical Energy Read Gap Test Org', 'CANON_ENERGY_TEST_ORG_GAP', 'Asia/Kolkata')
    RETURNING id INTO v_org2;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org2, 'Canonical Energy Read Gap Test Site', 'CANON_ENERGY_TEST_SITE_GAP', 'Asia/Kolkata', TRUE)
    RETURNING id INTO v_site2;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org2, v_site2, 'Canonical Energy Read Gap Test Gateway', 'CANON-ENERGY-GW-GAP')
    RETURNING id INTO v_gateway2;

    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org2, v_gateway2, v_device_model, v_profile_id, 'Canonical Energy Read Gap Test Device', 'CANON-ENERGY-DEV-GAP')
    RETURNING id INTO v_device2;

    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org2, v_site2, 'Canonical Energy Read Gap Test Asset', 'CANON_ENERGY_ASSET_GAP', 'DIRECT_METER_REQUIRED', 'ACTIVE')
    RETURNING id INTO v_asset2;

    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset2, v_device2, 'PRIMARY_METER');

    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES
        (v_asset2, v_device2, v_import_point_id, v_org2, v_now - INTERVAL '10 years', NULL),
        (v_asset2, v_device2, v_export_point_id, v_org2, v_now - INTERVAL '10 years', NULL);

    INSERT INTO metadata.grafana_organization_map(grafana_org_id, organization_id, is_active)
    VALUES (v_grafana_org_id2, v_org2, TRUE);

    -- Policy 1: covers [now-30d, now-20d) only.
    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, effective_to, is_enabled)
    VALUES (v_site2, 60, 'WALL_CLOCK', 60, v_now - INTERVAL '30 days', v_now - INTERVAL '20 days', TRUE);

    -- Deliberate gap: nothing covers [now-20d, now-15d).

    -- Policy 2: covers [now-15d, ) onward.
    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site2, 60, 'WALL_CLOCK', 60, v_now - INTERVAL '15 days', TRUE);

    v_raised := FALSE;
    BEGIN
        PERFORM 1
        FROM analytics.get_canonical_energy_read(
            v_grafana_org_id2, v_asset2,
            v_now - INTERVAL '18 days', v_now - INTERVAL '16 days',
            'native', 'strict'
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_raised := TRUE;
            v_error_message := SQLERRM;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST C FAILED: a range inside a genuine policy gap (p_from at or after the earliest-ever policy) did not raise -- a real configuration error was silently suppressed';
    END IF;

    IF v_error_message !~ 'no capture policy resolvable' THEN
        RAISE EXCEPTION 'TEST C FAILED: unexpected error for a genuine policy gap: %', v_error_message;
    END IF;

    RAISE NOTICE 'TEST C passed: a genuine gap between policies inside an otherwise-configured era still raises: %', v_error_message;

    -- ==================================================================
    -- TEST D -- tenant/asset scoping is unchanged: a mismatched
    -- grafana_org_id yields zero rows, never another tenant's data, and
    -- never an exception either.
    -- ==================================================================

    v_raised := FALSE;
    BEGIN
        SELECT count(*) INTO v_result_count
        FROM analytics.get_canonical_energy_read(
            v_grafana_org_id2, v_asset,
            v_data_from, v_data_from + INTERVAL '3 minutes',
            'native', 'strict'
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_raised := TRUE;
    END;

    IF v_raised THEN
        RAISE EXCEPTION 'TEST D FAILED: a cross-tenant request raised instead of returning zero rows';
    END IF;

    IF v_result_count <> 0 THEN
        RAISE EXCEPTION 'TEST D FAILED: a mismatched grafana_org_id returned % rows instead of zero -- tenant scoping regression', v_result_count;
    END IF;

    RAISE NOTICE 'TEST D passed: tenant/asset scoping is unchanged -- a mismatched org sees zero rows.';

    -- ==================================================================
    -- TEST E -- the exact Asset Dashboard panel parameters
    -- ('native', 'strict') behave correctly for both a normal recent
    -- range and the previously-failing long historical range.
    -- ==================================================================

    -- Normal recent range: real data, correct row content.
    SELECT * INTO v_row
    FROM analytics.get_canonical_energy_read(
        v_grafana_org_id, v_asset,
        v_data_from, v_data_from + INTERVAL '1 minute',
        'native', 'strict'
    )
    LIMIT 1;

    IF v_row.import_consumption_kwh IS DISTINCT FROM 1.0 THEN
        RAISE EXCEPTION 'TEST E FAILED: dashboard-parameter query returned unexpected import_consumption_kwh for the first bucket: %', v_row.import_consumption_kwh;
    END IF;

    -- Previously-failing long historical range (mirrors "select last 90
    -- days" on a recently-commissioned site): must not raise, must return
    -- exactly the real data.
    v_raised := FALSE;
    BEGIN
        SELECT count(*) INTO v_result_count
        FROM analytics.get_canonical_energy_read(
            v_grafana_org_id, v_asset,
            v_now - INTERVAL '90 days', v_now,
            'native', 'strict'
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_raised := TRUE;
            v_error_message := SQLERRM;
    END;

    IF v_raised THEN
        RAISE EXCEPTION 'TEST E FAILED: the exact dashboard parameters still raise for a 90-day range on a recently-commissioned site: %', v_error_message;
    END IF;

    IF v_result_count <> 3 THEN
        RAISE EXCEPTION 'TEST E FAILED: 90-day dashboard-parameter query returned % rows, expected exactly the 3 real rows', v_result_count;
    END IF;

    RAISE NOTICE 'TEST E passed: exact Asset Dashboard parameters work for both a normal range and the previously-failing 90-day historical range.';

END;
$test$;

ROLLBACK;

SELECT
    'Canonical energy read pre-policy-range assertions passed.'
    AS result;
