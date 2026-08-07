\set ON_ERROR_STOP on

BEGIN;

DO
$$
DECLARE
    v_org_id UUID := '51000000-0000-4000-8000-000000000001';
    v_site_id UUID := '51000000-0000-4000-8000-000000000002';
    v_gateway_id UUID := '51000000-0000-4000-8000-000000000003';
    v_asset_id UUID := '51000000-0000-4000-8000-000000000004';
    v_device_id UUID := '51000000-0000-4000-8000-000000000005';
    v_asset_type_id UUID;
    v_device_category_id UUID;
    v_status TEXT;
    v_count INTEGER;
BEGIN
    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'ORGANIZATION_LIFECYCLE';
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'Expected 4 organization lifecycle definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'SITE_LIFECYCLE';
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'Expected 4 site lifecycle definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'ASSET_LIFECYCLE';
    IF v_count <> 5 THEN
        RAISE EXCEPTION 'Expected 5 asset lifecycle definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'GATEWAY_LIFECYCLE';
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'Expected 4 gateway lifecycle definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'DEVICE_LIFECYCLE';
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'Expected 4 device lifecycle definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'COMMISSIONING_STATUS';
    IF v_count <> 6 THEN
        RAISE EXCEPTION 'Expected 6 commissioning definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'GRAFANA_PROVISIONING_STATUS';
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'Expected 4 Grafana provisioning definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'TELEMETRY_AVAILABILITY';
    IF v_count <> 7 THEN
        RAISE EXCEPTION 'Expected 7 telemetry availability definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'METERING_REQUIREMENT';
    IF v_count <> 3 THEN
        RAISE EXCEPTION 'Expected 3 metering requirement definitions, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM config.status_definitions
    WHERE status_domain = 'METER_COVERAGE_STATUS';
    IF v_count <> 7 THEN
        RAISE EXCEPTION 'Expected 7 meter coverage definitions, found %', v_count;
    END IF;

    SELECT id INTO v_asset_type_id
    FROM metadata.asset_types
    ORDER BY created_at, id
    LIMIT 1;

    SELECT id INTO v_device_category_id
    FROM config.device_categories
    ORDER BY created_at, id
    LIMIT 1;

    INSERT INTO metadata.organizations (id, name, code)
    VALUES (v_org_id, 'Lifecycle Test Organization', 'LIFECYCLE_TEST_ORG');

    SELECT lifecycle_status INTO v_status
    FROM metadata.organizations WHERE id = v_org_id;
    IF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Organization compatibility default expected ACTIVE, found %', v_status;
    END IF;

    INSERT INTO metadata.sites (id, organization_id, name, code, timezone)
    VALUES (v_site_id, v_org_id, 'Lifecycle Test Site', 'LIFECYCLE_TEST_SITE', 'UTC');

    SELECT lifecycle_status INTO v_status
    FROM metadata.sites WHERE id = v_site_id;
    IF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Site compatibility default expected ACTIVE, found %', v_status;
    END IF;

    INSERT INTO metadata.gateways
        (id, organization_id, site_id, name, external_id)
    VALUES
        (v_gateway_id, v_org_id, v_site_id, 'Lifecycle Test Gateway', 'LIFECYCLE-TEST-GW');

    SELECT lifecycle_status INTO v_status
    FROM metadata.gateways WHERE id = v_gateway_id;
    IF v_status <> 'REGISTERED' THEN
        RAISE EXCEPTION 'Gateway default expected REGISTERED, found %', v_status;
    END IF;

    INSERT INTO metadata.assets
        (id, organization_id, site_id, asset_type_id, name, metering_requirement)
    VALUES
        (v_asset_id, v_org_id, v_site_id, v_asset_type_id, 'Lifecycle Test Asset', 'NOT_REQUIRED');

    SELECT lifecycle_status INTO v_status
    FROM metadata.assets WHERE id = v_asset_id;
    IF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Asset compatibility default expected ACTIVE, found %', v_status;
    END IF;

    INSERT INTO metadata.device_models
        (vendor, model, device_type, device_category_id)
    VALUES
        ('Lifecycle Test Vendor', 'Lifecycle Test Model', 'Test', v_device_category_id)
    ON CONFLICT DO NOTHING;

    INSERT INTO metadata.devices
        (id, organization_id, gateway_id, device_model_id, name, external_id, protocol)
    SELECT
        v_device_id,
        v_org_id,
        v_gateway_id,
        dm.id,
        'Lifecycle Test Device',
        'LIFECYCLE-TEST-DEVICE',
        'MQTT'
    FROM metadata.device_models dm
    WHERE dm.vendor = 'Lifecycle Test Vendor'
      AND dm.model = 'Lifecycle Test Model';

    SELECT lifecycle_status INTO v_status
    FROM metadata.devices WHERE id = v_device_id;
    IF v_status <> 'REGISTERED' THEN
        RAISE EXCEPTION 'Device default expected REGISTERED, found %', v_status;
    END IF;

    BEGIN
        UPDATE metadata.organizations
        SET lifecycle_status = 'INVALID'
        WHERE id = v_org_id;
        RAISE EXCEPTION 'Invalid organization lifecycle value was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    BEGIN
        UPDATE metadata.sites
        SET lifecycle_status = 'INVALID'
        WHERE id = v_site_id;
        RAISE EXCEPTION 'Invalid site lifecycle value was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    BEGIN
        UPDATE metadata.assets
        SET lifecycle_status = 'INVALID'
        WHERE id = v_asset_id;
        RAISE EXCEPTION 'Invalid asset lifecycle value was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    BEGIN
        UPDATE metadata.gateways
        SET lifecycle_status = 'INVALID'
        WHERE id = v_gateway_id;
        RAISE EXCEPTION 'Invalid gateway lifecycle value was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    BEGIN
        UPDATE metadata.devices
        SET lifecycle_status = 'INVALID'
        WHERE id = v_device_id;

        RAISE EXCEPTION 'Invalid device lifecycle value was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM NOT LIKE
                'Select Registered, Inactive, or Decommissioned.%'
            THEN
                RAISE;
            END IF;
    END;
END;
$$;

ROLLBACK;

\echo 'Controlled lifecycle status assertions passed.'
