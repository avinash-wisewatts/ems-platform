-- ============================================================================
-- File:
--   scripts/test/assert_canonical_energy_read_asset_points_attribution.sql
--
-- Purpose:
--   Regression test for migration 263: analytics.get_canonical_energy_read()
--   migrated from PRIMARY_METER device resolution to metadata.asset_points
--   attribution, resolving ENERGY_IMPORT_TOTAL and ENERGY_EXPORT_TOTAL
--   independently (per ADR-018 Amendment 7 / migration 254's canonical
--   measurement groups) and combining them per-interval without summing or
--   cross-attributing either direction.
--
--   Covers the full regression scenario list from the approved design:
--     1. Normal confirmed assignment (Import + Export on the same device).
--     2. No confirmed assignment at all -- zero rows, not an error.
--     3. Cross-tenant denial.
--     4. Effective assignment boundaries (per direction).
--     5. Source replacement mid-range (Import only) -- stitched slices, no
--        leakage across the cutover.
--     6. Multiple Energy measurement types on DIFFERENT devices (Import on
--        device A, Export on device B) -- combined per bucket without
--        summing or cross-attribution.
--     7. A single confirmed direction (Import only, Export never assigned)
--        -- Import populated, Export NULL, no error.
--     8. Existing resolution tiers -- native/5m/15m/1h/1d all dispatch
--        correctly against the same underlying data.
--     9. Confirmed assignment with no recorded telemetry -- zero rows.
--    10. Long/historical range -- no artificial window cap.
--
--   Everything here runs inside one transaction that is rolled back at the
--   end -- no fixture data ever persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_org                UUID;
    v_org_other          UUID;
    v_site               UUID;
    v_gateway            UUID;
    v_device_model       UUID;
    v_energy_category    UUID;

    v_grafana_org_id       BIGINT := 910001;
    v_grafana_org_id_other BIGINT := 910002;

    v_import_point_id    UUID;
    v_export_point_id    UUID;
    v_profile_id         UUID;

    v_device_normal       UUID;  -- scenario 1: Import+Export, same device
    v_device_no_telemetry UUID;  -- scenario 9
    v_device_a            UUID;  -- scenario 5: outgoing (Import)
    v_device_b            UUID;  -- scenario 5: incoming (Import)
    v_device_import_side  UUID;  -- scenario 6: Import source
    v_device_export_side  UUID;  -- scenario 6: Export source
    v_device_import_only  UUID;  -- scenario 7
    v_device_tiers        UUID;  -- scenario 8
    v_device_boundary     UUID;  -- scenario 4

    v_asset_normal         UUID;
    v_asset_unassigned     UUID;
    v_asset_no_telemetry   UUID;
    v_asset_replacement    UUID;
    v_asset_multidevice    UUID;
    v_asset_single_direction UUID;
    v_asset_boundary       UUID;
    v_asset_tiers          UUID;

    v_now                TIMESTAMPTZ := date_trunc('minute', now()) - INTERVAL '1 hour';
    -- Scenario 8 only: anchored to the start of an hour (HH:05 and HH:06), so
    -- its two one-minute rows always share one 5m, 15m, UTC/site-local hourly
    -- and site-local daily bucket regardless of when the test runs. (A
    -- minute-relative anchor split them across buckets whenever the run's
    -- minute ended in 4 or 9.)
    v_tiers_t0           TIMESTAMPTZ := date_trunc('hour', now()) - INTERVAL '2 hours' + INTERVAL '5 minutes';
    v_policy_from        TIMESTAMPTZ;

    v_result_count       INT;
    v_row                RECORD;
BEGIN
    v_policy_from := v_now - INTERVAL '30 days';

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
    VALUES ('WiseWatts Test', 'Energy Consumption Attribution Test Meter', 'Energy Meter', v_energy_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Energy Consumption Attribution Test Org', 'ENERGY_ATTR_TEST_ORG', 'UTC')
    RETURNING id INTO v_org;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Energy Consumption Attribution Test Org (Other Tenant)', 'ENERGY_ATTR_TEST_ORG_OTHER', 'UTC')
    RETURNING id INTO v_org_other;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'Energy Consumption Attribution Test Site', 'ENERGY_ATTR_TEST_SITE', 'UTC', TRUE)
    RETURNING id INTO v_site;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Energy Consumption Attribution Test Gateway', 'ENERGY-ATTR-GW')
    RETURNING id INTO v_gateway;

    INSERT INTO metadata.grafana_organization_map(grafana_org_id, organization_id, is_active)
    VALUES (v_grafana_org_id, v_org, TRUE);

    INSERT INTO metadata.grafana_organization_map(grafana_org_id, organization_id, is_active)
    VALUES (v_grafana_org_id_other, v_org_other, TRUE);

    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site, 60, 'WALL_CLOCK', 60, v_policy_from, TRUE);

    -- ------------------------------------------------------------------
    -- Devices
    -- ------------------------------------------------------------------
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter Normal', 'ATTR-METER-NORMAL') RETURNING id INTO v_device_normal;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter No Telemetry', 'ATTR-METER-NO-TELEMETRY') RETURNING id INTO v_device_no_telemetry;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter A', 'ATTR-METER-A') RETURNING id INTO v_device_a;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter B', 'ATTR-METER-B') RETURNING id INTO v_device_b;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter Import Side', 'ATTR-METER-IMPORT-SIDE') RETURNING id INTO v_device_import_side;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter Export Side', 'ATTR-METER-EXPORT-SIDE') RETURNING id INTO v_device_export_side;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter Import Only', 'ATTR-METER-IMPORT-ONLY') RETURNING id INTO v_device_import_only;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter Tiers', 'ATTR-METER-TIERS') RETURNING id INTO v_device_tiers;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Attr Test Meter Boundary', 'ATTR-METER-BOUNDARY') RETURNING id INTO v_device_boundary;

    -- ------------------------------------------------------------------
    -- Assets
    -- ------------------------------------------------------------------
    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Attr -- Normal Asset', 'ATTR_ASSET_NORMAL', 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id INTO v_asset_normal;
    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Attr -- Unassigned Asset', 'ATTR_ASSET_UNASSIGNED', 'NOT_REQUIRED', 'ACTIVE') RETURNING id INTO v_asset_unassigned;
    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Attr -- No Telemetry Asset', 'ATTR_ASSET_NO_TELEMETRY', 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id INTO v_asset_no_telemetry;
    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Attr -- Source Replacement Asset', 'ATTR_ASSET_REPLACEMENT', 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id INTO v_asset_replacement;
    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Attr -- Multi-Device Asset', 'ATTR_ASSET_MULTIDEVICE', 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id INTO v_asset_multidevice;
    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Attr -- Single Direction Asset', 'ATTR_ASSET_SINGLE_DIRECTION', 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id INTO v_asset_single_direction;
    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Attr -- Boundary Asset', 'ATTR_ASSET_BOUNDARY', 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id INTO v_asset_boundary;
    INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status)
    VALUES (v_org, v_site, 'Attr -- Resolution Tiers Asset', 'ATTR_ASSET_TIERS', 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id INTO v_asset_tiers;

    -- ==================================================================
    -- SCENARIO 1 -- normal confirmed assignment: Import and Export both
    -- confirmed on the SAME device, matching today's real-world shape.
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES
        (v_asset_normal, v_device_normal, v_import_point_id, v_org, v_policy_from, NULL),
        (v_asset_normal, v_device_normal, v_export_point_id, v_org, v_policy_from, NULL);

    INSERT INTO analytics.energy_consumption_1min(
        bucket_start, organization_id, site_id, device_id,
        import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
        export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
        gap_detected
    ) VALUES
        (v_now,                      v_org, v_site, v_device_normal, 2.0, 'GOOD', TRUE, FALSE, FALSE, 0.5, 'GOOD', TRUE, FALSE, FALSE, FALSE),
        (v_now + INTERVAL '1 minute',v_org, v_site, v_device_normal, 2.1, 'GOOD', TRUE, FALSE, FALSE, 0.6, 'GOOD', TRUE, FALSE, FALSE, FALSE);

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_normal, v_now, v_now + INTERVAL '2 minutes', 'native', 'strict');
    IF v_result_count <> 2 THEN
        RAISE EXCEPTION 'SCENARIO 1 FAILED: expected 2 native rows for the normal assigned asset, got %', v_result_count;
    END IF;

    SELECT * INTO v_row
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_normal, v_now, v_now + INTERVAL '30 seconds', 'native', 'strict');
    IF v_row.import_consumption_kwh IS DISTINCT FROM 2.0 OR v_row.export_consumption_kwh IS DISTINCT FROM 0.5 THEN
        RAISE EXCEPTION 'SCENARIO 1 FAILED: expected import=2.0/export=0.5 for the first bucket, got import=%/export=%', v_row.import_consumption_kwh, v_row.export_consumption_kwh;
    END IF;
    IF v_row.resolved_device_id IS DISTINCT FROM v_device_normal THEN
        RAISE EXCEPTION 'SCENARIO 1 FAILED: expected resolved_device_id to be the single confirmed device, got %', v_row.resolved_device_id;
    END IF;
    IF v_row.import_quality_status IS DISTINCT FROM 'GOOD' OR v_row.export_quality_status IS DISTINCT FROM 'GOOD' THEN
        RAISE EXCEPTION 'SCENARIO 1 FAILED: expected GOOD/GOOD quality status, got %/%', v_row.import_quality_status, v_row.export_quality_status;
    END IF;

    RAISE NOTICE 'SCENARIO 1 passed: normal confirmed assignment (Import+Export, same device) returns correct native data.';

    -- ==================================================================
    -- SCENARIO 2 -- no confirmed assignment at all -- zero rows, no error.
    -- ==================================================================
    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_unassigned, v_now, v_now + INTERVAL '2 minutes', 'native', 'strict');
    IF v_result_count <> 0 THEN
        RAISE EXCEPTION 'SCENARIO 2 FAILED: unassigned asset unexpectedly returned % row(s)', v_result_count;
    END IF;

    RAISE NOTICE 'SCENARIO 2 passed: an asset with no confirmed asset_points assignment returns zero rows, not an error.';

    -- ==================================================================
    -- SCENARIO 3 -- cross-tenant denial: a caller from a different
    -- grafana_org_id sees zero rows for the normal asset, never data.
    -- ==================================================================
    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id_other, v_asset_normal, v_now, v_now + INTERVAL '2 minutes', 'native', 'strict');
    IF v_result_count <> 0 THEN
        RAISE EXCEPTION 'SCENARIO 3 FAILED: cross-tenant caller unexpectedly saw % row(s)', v_result_count;
    END IF;

    RAISE NOTICE 'SCENARIO 3 passed: a caller in a different tenant is denied (zero rows, no error).';

    -- ==================================================================
    -- SCENARIO 4 -- effective assignment boundaries: a binding that starts
    -- partway through the available telemetry excludes samples before its
    -- own effective_from, per direction.
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (v_asset_boundary, v_device_boundary, v_import_point_id, v_org, v_now + INTERVAL '1 minute', NULL);
    -- Deliberately no Export binding for this asset -- boundary scenario
    -- only needs to prove Import-side effective_from enforcement.

    INSERT INTO analytics.energy_consumption_1min(
        bucket_start, organization_id, site_id, device_id,
        import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
        export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
        gap_detected
    ) VALUES
        (v_now,                       v_org, v_site, v_device_boundary, 8.0, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE),
        (v_now + INTERVAL '1 minute', v_org, v_site, v_device_boundary, 9.0, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE);

    -- The binding's effective_from (v_now+1min) excludes the first sample.
    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_boundary, v_now, v_now + INTERVAL '2 minutes', 'native', 'strict');
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'SCENARIO 4 FAILED: expected exactly 1 row on/after the binding''s effective_from, got %', v_result_count;
    END IF;

    SELECT * INTO v_row
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_boundary, v_now, v_now + INTERVAL '2 minutes', 'native', 'strict');
    IF v_row.interval_start IS DISTINCT FROM (v_now + INTERVAL '1 minute') THEN
        RAISE EXCEPTION 'SCENARIO 4 FAILED: expected the surviving row to be the one at/after effective_from, got interval_start=%', v_row.interval_start;
    END IF;

    RAISE NOTICE 'SCENARIO 4 passed: a confirmed assignment''s effective_from boundary excludes samples before it.';

    -- ==================================================================
    -- SCENARIO 5 -- source replacement mid-range (Import only): device A
    -- confirmed until a cutover, device B confirmed from that cutover
    -- onward. Each source contributes only its own effective slice.
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (v_asset_replacement, v_device_a, v_import_point_id, v_org, v_now, v_now + INTERVAL '3 minutes');
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (v_asset_replacement, v_device_b, v_import_point_id, v_org, v_now + INTERVAL '3 minutes', NULL);

    INSERT INTO analytics.energy_consumption_1min(
        bucket_start, organization_id, site_id, device_id,
        import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
        export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
        gap_detected
    ) VALUES
        (v_now,                       v_org, v_site, v_device_a, 5.0, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE),
        (v_now + INTERVAL '10 minutes', v_org, v_site, v_device_a, 999.0, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE),
        (v_now + INTERVAL '4 minutes', v_org, v_site, v_device_b, 7.0, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE);

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_replacement, v_now, v_now + INTERVAL '20 minutes', 'native', 'strict');
    IF v_result_count <> 2 THEN
        RAISE EXCEPTION 'SCENARIO 5 FAILED: expected exactly 2 rows across the source-replacement boundary, got %', v_result_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_replacement, v_now, v_now + INTERVAL '20 minutes', 'native', 'strict')
        WHERE interval_start = v_now AND import_consumption_kwh = 5.0
    ) THEN
        RAISE EXCEPTION 'SCENARIO 5 FAILED: expected the outgoing device''s in-window sample (5.0 kWh) to be present';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_replacement, v_now, v_now + INTERVAL '20 minutes', 'native', 'strict')
        WHERE interval_start = v_now + INTERVAL '4 minutes' AND import_consumption_kwh = 7.0
    ) THEN
        RAISE EXCEPTION 'SCENARIO 5 FAILED: expected the incoming device''s in-window sample (7.0 kWh) to be present';
    END IF;

    IF EXISTS (
        SELECT 1 FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_replacement, v_now, v_now + INTERVAL '20 minutes', 'native', 'strict')
        WHERE import_consumption_kwh = 999.0
    ) THEN
        RAISE EXCEPTION 'SCENARIO 5 FAILED: the outgoing device''s telemetry AFTER its binding closed must never leak into the result';
    END IF;

    RAISE NOTICE 'SCENARIO 5 passed: source replacement mid-range stitches each device''s own effective slice, no leakage across the cutover.';

    -- ==================================================================
    -- SCENARIO 6 -- multiple Energy measurement types on DIFFERENT
    -- devices: Import confirmed on device_import_side, Export confirmed
    -- on device_export_side. Each output row must combine both directions'
    -- own readings WITHOUT summing or cross-attributing either one.
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES
        (v_asset_multidevice, v_device_import_side, v_import_point_id, v_org, v_policy_from, NULL),
        (v_asset_multidevice, v_device_export_side, v_export_point_id, v_org, v_policy_from, NULL);

    INSERT INTO analytics.energy_consumption_1min(
        bucket_start, organization_id, site_id, device_id,
        import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
        export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
        gap_detected
    ) VALUES
        -- Import-side device: real import reading, but its OWN export
        -- column (from the same physical device row) must never leak out.
        (v_now, v_org, v_site, v_device_import_side, 3.0, 'GOOD', TRUE, FALSE, FALSE, 111.0, 'GOOD', TRUE, FALSE, FALSE, FALSE),
        -- Export-side device: real export reading, whose OWN import column
        -- must never leak out either.
        (v_now, v_org, v_site, v_device_export_side, 222.0, 'GOOD', TRUE, FALSE, FALSE, 4.0, 'GOOD', TRUE, FALSE, FALSE, FALSE);

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_multidevice, v_now, v_now + INTERVAL '1 minute', 'native', 'strict');
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'SCENARIO 6 FAILED: expected exactly 1 combined row for the shared bucket, got %', v_result_count;
    END IF;

    SELECT * INTO v_row
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_multidevice, v_now, v_now + INTERVAL '1 minute', 'native', 'strict');

    IF v_row.import_consumption_kwh IS DISTINCT FROM 3.0 THEN
        RAISE EXCEPTION 'SCENARIO 6 FAILED: expected import_consumption_kwh=3.0 (from the Import-side device), got %', v_row.import_consumption_kwh;
    END IF;
    IF v_row.export_consumption_kwh IS DISTINCT FROM 4.0 THEN
        RAISE EXCEPTION 'SCENARIO 6 FAILED: expected export_consumption_kwh=4.0 (from the Export-side device), got %', v_row.export_consumption_kwh;
    END IF;
    IF v_row.import_consumption_kwh IN (111.0, 222.0) OR v_row.export_consumption_kwh IN (111.0, 222.0) THEN
        RAISE EXCEPTION 'SCENARIO 6 FAILED: a same-device-row value leaked across directions (import=%/export=%)', v_row.import_consumption_kwh, v_row.export_consumption_kwh;
    END IF;
    IF v_row.resolved_device_id IS DISTINCT FROM v_device_import_side THEN
        RAISE EXCEPTION 'SCENARIO 6 FAILED: expected resolved_device_id to reflect the Import-side device (%), got %', v_device_import_side, v_row.resolved_device_id;
    END IF;

    RAISE NOTICE 'SCENARIO 6 passed: Import and Export confirmed on different devices are combined per bucket without summing or cross-attribution; resolved_device_id reflects the Import side.';

    -- ==================================================================
    -- SCENARIO 7 -- a single confirmed direction (Import only, Export
    -- never assigned) returns Import data with Export columns NULL, not
    -- an error and not requiring both directions.
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (v_asset_single_direction, v_device_import_only, v_import_point_id, v_org, v_policy_from, NULL);

    INSERT INTO analytics.energy_consumption_1min(
        bucket_start, organization_id, site_id, device_id,
        import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
        export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
        gap_detected
    ) VALUES
        (v_now, v_org, v_site, v_device_import_only, 6.5, 'GOOD', TRUE, FALSE, FALSE, 0.0, 'GOOD', TRUE, FALSE, FALSE, FALSE);

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_single_direction, v_now, v_now + INTERVAL '1 minute', 'native', 'strict');
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'SCENARIO 7 FAILED: expected exactly 1 row for the Import-only asset, got %', v_result_count;
    END IF;

    SELECT * INTO v_row
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_single_direction, v_now, v_now + INTERVAL '1 minute', 'native', 'strict');
    IF v_row.import_consumption_kwh IS DISTINCT FROM 6.5 THEN
        RAISE EXCEPTION 'SCENARIO 7 FAILED: expected import_consumption_kwh=6.5, got %', v_row.import_consumption_kwh;
    END IF;
    IF v_row.export_consumption_kwh IS NOT NULL THEN
        RAISE EXCEPTION 'SCENARIO 7 FAILED: expected export_consumption_kwh to be NULL (Export never confirmed), got %', v_row.export_consumption_kwh;
    END IF;
    IF v_row.export_quality_status IS NOT NULL THEN
        RAISE EXCEPTION 'SCENARIO 7 FAILED: expected export_quality_status to be NULL, got %', v_row.export_quality_status;
    END IF;

    RAISE NOTICE 'SCENARIO 7 passed: a single confirmed direction (Import only) returns its data with the other direction NULL, not an error.';

    -- ==================================================================
    -- SCENARIO 8 -- existing resolution tiers: native/5m/15m/1h/1d all
    -- dispatch correctly against the same underlying 1-minute data.
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES
        (v_asset_tiers, v_device_tiers, v_import_point_id, v_org, v_policy_from, NULL),
        (v_asset_tiers, v_device_tiers, v_export_point_id, v_org, v_policy_from, NULL);

    INSERT INTO analytics.energy_consumption_1min(
        bucket_start, organization_id, site_id, device_id,
        import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
        export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
        gap_detected
    ) VALUES
        (v_tiers_t0,                       v_org, v_site, v_device_tiers, 2.0, 'GOOD', TRUE, FALSE, FALSE, 0.5, 'GOOD', TRUE, FALSE, FALSE, FALSE),
        (v_tiers_t0 + INTERVAL '1 minute', v_org, v_site, v_device_tiers, 2.1, 'GOOD', TRUE, FALSE, FALSE, 0.6, 'GOOD', TRUE, FALSE, FALSE, FALSE);

    -- v_device_tiers has 2 one-minute rows at v_tiers_t0/v_tiers_t0+1min (import
    -- 2.0+2.1=4.1 kWh, export 0.5+0.6=1.1 kWh in total).
    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_tiers, v_tiers_t0, v_tiers_t0 + INTERVAL '2 minutes', 'native', 'strict');
    IF v_result_count <> 2 THEN
        RAISE EXCEPTION 'SCENARIO 8 FAILED: native tier expected 2 rows, got %', v_result_count;
    END IF;

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_tiers, v_tiers_t0, v_tiers_t0 + INTERVAL '5 minutes', '5m', 'native');
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'SCENARIO 8 FAILED: 5m tier expected 1 bucket, got %', v_result_count;
    END IF;

    SELECT * INTO v_row
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_tiers, v_tiers_t0, v_tiers_t0 + INTERVAL '5 minutes', '5m', 'native');
    IF round(v_row.import_consumption_kwh::numeric, 2) IS DISTINCT FROM 4.1 OR round(v_row.export_consumption_kwh::numeric, 2) IS DISTINCT FROM 1.1 THEN
        RAISE EXCEPTION 'SCENARIO 8 FAILED: 5m tier expected import=4.1/export=1.1, got import=%/export=%', v_row.import_consumption_kwh, v_row.export_consumption_kwh;
    END IF;

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_tiers, v_tiers_t0, v_tiers_t0 + INTERVAL '15 minutes', '15m', 'native');
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'SCENARIO 8 FAILED: 15m tier expected 1 bucket, got %', v_result_count;
    END IF;

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_tiers, v_tiers_t0, v_tiers_t0 + INTERVAL '1 hour', '1h', 'native');
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'SCENARIO 8 FAILED: 1h tier expected 1 bucket, got %', v_result_count;
    END IF;

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_tiers, v_tiers_t0, v_tiers_t0 + INTERVAL '1 day', '1d', 'native');
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'SCENARIO 8 FAILED: 1d tier expected 1 bucket, got %', v_result_count;
    END IF;

    RAISE NOTICE 'SCENARIO 8 passed: native/5m/15m/1h/1d resolution tiers all dispatch correctly against asset_points attribution.';

    -- ==================================================================
    -- SCENARIO 9 -- confirmed assignment, no recorded telemetry -- zero
    -- rows, not an error ("do not invent data").
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES
        (v_asset_no_telemetry, v_device_no_telemetry, v_import_point_id, v_org, v_policy_from, NULL),
        (v_asset_no_telemetry, v_device_no_telemetry, v_export_point_id, v_org, v_policy_from, NULL);

    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_no_telemetry, v_now, v_now + INTERVAL '2 minutes', 'native', 'strict');
    IF v_result_count <> 0 THEN
        RAISE EXCEPTION 'SCENARIO 9 FAILED: expected zero rows for a confirmed assignment with no telemetry, got %', v_result_count;
    END IF;

    RAISE NOTICE 'SCENARIO 9 passed: a confirmed assignment with no recorded telemetry returns zero rows, not an error.';

    -- ==================================================================
    -- SCENARIO 10 -- long/historical range -- no artificial window cap.
    -- ==================================================================
    SELECT count(*) INTO v_result_count
    FROM analytics.get_canonical_energy_read(v_grafana_org_id, v_asset_normal, v_policy_from, v_now + INTERVAL '2 minutes', 'native', 'strict');
    IF v_result_count <> 2 THEN
        RAISE EXCEPTION 'SCENARIO 10 FAILED: expected 2 rows over a multi-week range, got %', v_result_count;
    END IF;

    RAISE NOTICE 'SCENARIO 10 passed: a multi-week range returns all matching samples -- no artificial window limit.';

END;
$test$;

ROLLBACK;

SELECT
    'Canonical energy read asset_points attribution assertions passed.'
    AS result;
