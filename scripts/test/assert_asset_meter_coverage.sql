\set ON_ERROR_STOP on

BEGIN;

DO
$$
DECLARE
    v_org_id UUID := '40000000-0000-4000-8000-000000000001';
    v_site_id UUID := '40000000-0000-4000-8000-000000000002';
    v_gateway_id UUID := '40000000-0000-4000-8000-000000000003';

    v_direct_asset UUID := '40000000-0000-4000-8000-000000000010';
    v_missing_direct_asset UUID := '40000000-0000-4000-8000-000000000011';
    v_parent_asset UUID := '40000000-0000-4000-8000-000000000012';
    v_child_configured UUID := '40000000-0000-4000-8000-000000000013';
    v_child_missing UUID := '40000000-0000-4000-8000-000000000014';
    v_not_required UUID := '40000000-0000-4000-8000-000000000015';

    v_device_direct UUID := '40000000-0000-4000-8000-000000000020';
    v_device_child UUID := '40000000-0000-4000-8000-000000000021';

    v_profile_id UUID;
    v_device_category_id UUID;
    v_device_model_id UUID;
    v_status TEXT;
    v_percent NUMERIC;
BEGIN
    SELECT id
    INTO v_profile_id
    FROM config.device_profiles
    ORDER BY created_at, id
    LIMIT 1;

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION 'No device profile available for coverage test';
    END IF;

    SELECT id
    INTO v_device_category_id
    FROM config.device_categories
    WHERE lower(name) = 'energy meter'
    ORDER BY id
    LIMIT 1;

    IF v_device_category_id IS NULL THEN
        RAISE EXCEPTION
            'The canonical Energy Meter device category is required';
    END IF;

    INSERT INTO metadata.device_models
    (
        vendor,
        model,
        device_type,
        device_category_id
    )
    VALUES
    (
        'EMS Test',
        'Asset Meter Coverage Meter',
        'Energy Meter',
        v_device_category_id
    )
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE
    SET device_category_id = EXCLUDED.device_category_id,
        device_type = EXCLUDED.device_type
    RETURNING id
    INTO v_device_model_id;

    INSERT INTO metadata.organizations
    (
        id,
        name,
        code
    )
    VALUES
    (
        v_org_id,
        'Meter Coverage Test Organization',
        'METER_COVERAGE_TEST'
    );

    INSERT INTO metadata.sites
    (
        id,
        organization_id,
        name,
        code,
        timezone
    )
    VALUES
    (
        v_site_id,
        v_org_id,
        'Meter Coverage Test Site',
        'METER_COVERAGE_SITE',
        'Asia/Kolkata'
    );

    INSERT INTO metadata.grafana_organization_map
    (
        organization_id,
        grafana_org_id,
        is_active
    )
    VALUES
    (
        v_org_id,
        4001,
        TRUE
    );

    INSERT INTO metadata.gateways
    (
        id,
        organization_id,
        site_id,
        name,
        external_id
    )
    VALUES
    (
        v_gateway_id,
        v_org_id,
        v_site_id,
        'Meter Coverage Test Gateway',
        'METER-COVERAGE-GW'
    );

    INSERT INTO metadata.assets
    (
        id,
        organization_id,
        site_id,
        parent_asset_id,
        name,
        status,
        metering_requirement
    )
    VALUES
        (
            v_direct_asset,
            v_org_id,
            v_site_id,
            NULL,
            'Direct Configured Asset',
            'active',
            'DIRECT_METER_REQUIRED'
        ),
        (
            v_missing_direct_asset,
            v_org_id,
            v_site_id,
            NULL,
            'Direct Missing Asset',
            'active',
            'DIRECT_METER_REQUIRED'
        ),
        (
            v_parent_asset,
            v_org_id,
            v_site_id,
            NULL,
            'Descendant Coverage Parent',
            'active',
            'DESCENDANT_COVERAGE_ALLOWED'
        ),
        (
            v_child_configured,
            v_org_id,
            v_site_id,
            v_parent_asset,
            'Configured Child',
            'active',
            'DIRECT_METER_REQUIRED'
        ),
        (
            v_child_missing,
            v_org_id,
            v_site_id,
            v_parent_asset,
            'Missing Child',
            'active',
            'DIRECT_METER_REQUIRED'
        ),
        (
            v_not_required,
            v_org_id,
            v_site_id,
            NULL,
            'Excluded Asset',
            'active',
            'NOT_REQUIRED'
        );

    INSERT INTO metadata.devices
    (
        id,
        organization_id,
        gateway_id,
        profile_id,
        device_model_id,
        name,
        external_id,
        protocol
    )
    VALUES
        (
            v_device_direct,
            v_org_id,
            v_gateway_id,
            v_profile_id,
            v_device_model_id,
            'Direct Meter Device',
            'DIRECT-METER-DEVICE',
            'MQTT'
        ),
        (
            v_device_child,
            v_org_id,
            v_gateway_id,
            v_profile_id,
            v_device_model_id,
            'Child Meter Device',
            'CHILD-METER-DEVICE',
            'MQTT'
        );

    INSERT INTO metadata.asset_devices
    (
        asset_id,
        device_id,
        relationship_type
    )
    VALUES
        (
            v_direct_asset,
            v_device_direct,
            'PRIMARY_METER'
        ),
        (
            v_child_configured,
            v_device_child,
            'PRIMARY_METER'
        );

    SELECT coverage_status, configuration_coverage_percent
    INTO v_status, v_percent
    FROM analytics.v_asset_meter_coverage_configuration
    WHERE asset_id = v_direct_asset;

    IF v_status <> 'CONFIGURED' OR v_percent <> 100.0 THEN
        RAISE EXCEPTION
            'Direct configured asset failed: status %, percent %',
            v_status,
            v_percent;
    END IF;

    SELECT coverage_status, configuration_coverage_percent
    INTO v_status, v_percent
    FROM analytics.v_asset_meter_coverage_configuration
    WHERE asset_id = v_missing_direct_asset;

    IF v_status <> 'MISSING_DIRECT_METER' OR v_percent <> 0.0 THEN
        RAISE EXCEPTION
            'Direct missing asset failed: status %, percent %',
            v_status,
            v_percent;
    END IF;

    SELECT coverage_status, configuration_coverage_percent
    INTO v_status, v_percent
    FROM analytics.v_asset_meter_coverage_configuration
    WHERE asset_id = v_parent_asset;

    IF v_status <> 'PARTIALLY_CONFIGURED' OR v_percent <> 50.0 THEN
        RAISE EXCEPTION
            'Descendant coverage failed: status %, percent %',
            v_status,
            v_percent;
    END IF;

    SELECT coverage_status, configuration_coverage_percent
    INTO v_status, v_percent
    FROM analytics.v_asset_meter_coverage_configuration
    WHERE asset_id = v_not_required;

    IF v_status <> 'EXCLUDED' OR v_percent IS NOT NULL THEN
        RAISE EXCEPTION
            'Excluded asset failed: status %, percent %',
            v_status,
            v_percent;
    END IF;
END;
$$;

ROLLBACK;
