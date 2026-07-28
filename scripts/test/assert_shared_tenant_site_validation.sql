\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
    org_a UUID := 'a1000000-0000-0000-0000-000000000001';
    org_b UUID := 'a1000000-0000-0000-0000-000000000002';
    site_a UUID := 'a2000000-0000-0000-0000-000000000001';
    site_b UUID := 'a2000000-0000-0000-0000-000000000002';
    building_a UUID := 'a3000000-0000-0000-0000-000000000001';
    floor_a UUID := 'a4000000-0000-0000-0000-000000000001';
    space_a UUID := 'a5000000-0000-0000-0000-000000000001';
    asset_a UUID := 'a6000000-0000-0000-0000-000000000001';
    asset_b UUID := 'a6000000-0000-0000-0000-000000000002';
    gateway_a UUID := 'a7000000-0000-0000-0000-000000000001';
    gateway_b UUID := 'a7000000-0000-0000-0000-000000000002';
    device_a UUID := 'a8000000-0000-0000-0000-000000000001';
    device_b UUID := 'a8000000-0000-0000-0000-000000000002';

    device_category_id UUID;
    device_model_id UUID;
BEGIN
    SELECT id
    INTO device_category_id
    FROM config.device_categories
    WHERE lower(name) = 'temperature sensor'
    ORDER BY id
    LIMIT 1;

    IF device_category_id IS NULL THEN
        RAISE EXCEPTION
            'The canonical Temperature Sensor device category is required';
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
        'Shared Validation Temperature Sensor',
        'Temperature Sensor',
        device_category_id
    )
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE
    SET device_category_id = EXCLUDED.device_category_id,
        device_type = EXCLUDED.device_type
    RETURNING id
    INTO device_model_id;

    INSERT INTO metadata.organizations (id, name, code)
    VALUES (org_a, 'Ownership A', 'OWNERSHIP_A'), (org_b, 'Ownership B', 'OWNERSHIP_B');

    INSERT INTO metadata.sites (id, organization_id, name, code)
    VALUES (site_a, org_a, 'Site A', 'SITE_A'), (site_b, org_b, 'Site B', 'SITE_B');

    INSERT INTO metadata.buildings (id, organization_id, site_id, name, code)
    VALUES (building_a, org_a, site_a, 'Building A', 'BUILDING_A');

    BEGIN
        INSERT INTO metadata.buildings (organization_id, site_id, name, code)
        VALUES (org_b, site_a, 'Invalid Building', 'INVALID_BUILDING');
        RAISE EXCEPTION 'Cross-tenant building was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO metadata.floors (id, organization_id, building_id, name, code)
    VALUES (floor_a, org_a, building_a, 'Floor A', 'FLOOR_A');

    BEGIN
        INSERT INTO metadata.floors (organization_id, building_id, name, code)
        VALUES (org_b, building_a, 'Invalid Floor', 'INVALID_FLOOR');
        RAISE EXCEPTION 'Cross-tenant floor was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO metadata.spaces (id, organization_id, floor_id, name, code)
    VALUES (space_a, org_a, floor_a, 'Space A', 'SPACE_A');

    BEGIN
        INSERT INTO metadata.spaces (organization_id, floor_id, name, code)
        VALUES (org_b, floor_a, 'Invalid Space', 'INVALID_SPACE');
        RAISE EXCEPTION 'Cross-tenant space was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO metadata.assets (
        id,
        organization_id,
        site_id,
        building_id,
        floor_id,
        space_id,
        name,
        metering_requirement
    ) VALUES (
        asset_a,
        org_a,
        site_a,
        building_a,
        floor_a,
        space_a,
        'Asset A',
        'NOT_REQUIRED'
    );

    INSERT INTO metadata.assets (
        id, organization_id, site_id, name, metering_requirement
    ) VALUES (
        asset_b, org_b, site_b, 'Asset B', 'NOT_REQUIRED'
    );

    BEGIN
        INSERT INTO metadata.assets (
            organization_id, site_id, name, metering_requirement
        ) VALUES (
            org_b, site_a, 'Invalid Asset Site', 'NOT_REQUIRED'
        );
        RAISE EXCEPTION 'Cross-tenant asset/site was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE metadata.assets SET parent_asset_id = asset_b WHERE id = asset_a;
        RAISE EXCEPTION 'Cross-tenant asset parent was accepted';
    EXCEPTION
        WHEN check_violation OR foreign_key_violation OR raise_exception THEN NULL;
    END;

    INSERT INTO metadata.gateways (
        id, organization_id, site_id, space_id, name, external_id
    ) VALUES (
        gateway_a, org_a, site_a, space_a, 'Gateway A', 'GW_A'
    ), (
        gateway_b, org_b, site_b, NULL, 'Gateway B', 'GW_B'
    );

    BEGIN
        INSERT INTO metadata.gateways (
            organization_id, site_id, name, external_id
        ) VALUES (
            org_b, site_a, 'Invalid Gateway', 'INVALID_GW'
        );
        RAISE EXCEPTION 'Cross-tenant gateway/site was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO metadata.devices (
        id,
        organization_id,
        gateway_id,
        device_model_id,
        name,
        external_id
    ) VALUES (
        device_a,
        org_a,
        gateway_a,
        device_model_id,
        'Device A',
        'DEV_A'
    ), (
        device_b,
        org_b,
        gateway_b,
        device_model_id,
        'Device B',
        'DEV_B'
    );

    BEGIN
        INSERT INTO metadata.devices (
            organization_id, gateway_id, name, external_id
        ) VALUES (
            org_b, gateway_a, 'Invalid Device', 'INVALID_DEV'
        );
        RAISE EXCEPTION 'Cross-tenant device/gateway was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO metadata.asset_devices (asset_id, device_id, relationship_type)
    VALUES (asset_a, device_a, 'TEMPERATURE_SENSOR');

    BEGIN
        INSERT INTO metadata.asset_devices (asset_id, device_id, relationship_type)
        VALUES (asset_a, device_b, 'TEMPERATURE_SENSOR');
        RAISE EXCEPTION 'Cross-tenant asset-device relationship was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$$;

ROLLBACK;
\echo 'Shared tenant and site validation assertions passed.'
