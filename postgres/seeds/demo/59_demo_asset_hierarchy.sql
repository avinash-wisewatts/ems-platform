-- ============================================================================
-- 59_demo_asset_hierarchy.sql
--
-- Demo operational asset hierarchy
--
-- WiseWatts Demo
--   └── Demo Hotel Site
--         └── Chiller Plant Room
--               ├── Chiller 1
--               ├── Primary Pump 1
--               └── Secondary Pump 1
--
-- Device assignments:
--
-- ENI-ENERGY-001 -> Chiller 1
-- ENI-ENERGY-002 -> Primary Pump 1
-- ENI-ENERGY-003 -> Secondary Pump 1
-- ============================================================================

DO
$$
DECLARE

    v_org_id UUID;
    v_site_id UUID;

    v_chiller_type UUID;
    v_pump_type UUID;

    v_plant_room_id UUID;

    v_chiller_1 UUID;
    v_primary_pump_1 UUID;
    v_secondary_pump_1 UUID;

BEGIN

    SELECT id
    INTO v_org_id
    FROM metadata.organizations
    WHERE code = 'WW-DEMO';

    SELECT id
    INTO v_site_id
    FROM metadata.sites
    WHERE name = 'Demo Hotel Site';

    SELECT id
    INTO v_chiller_type
    FROM metadata.asset_types
    WHERE name = 'Chiller';

    SELECT id
    INTO v_pump_type
    FROM metadata.asset_types
    WHERE name = 'Pump';

    INSERT INTO metadata.assets
    (
        organization_id,
        site_id,
        name,
        metering_requirement,
        metadata
    )
    VALUES
    (
        v_org_id,
        v_site_id,
        'Chiller Plant Room',
        'NOT_REQUIRED',
        '{}'::jsonb
    )
    ON CONFLICT DO NOTHING;

    SELECT id
    INTO v_plant_room_id
    FROM metadata.assets
    WHERE site_id = v_site_id
      AND name = 'Chiller Plant Room';

    INSERT INTO metadata.assets
    (
        organization_id,
        site_id,
        asset_type_id,
        parent_asset_id,
        name,
        metering_requirement
    )
    VALUES
    (
        v_org_id,
        v_site_id,
        v_chiller_type,
        v_plant_room_id,
        'Chiller 1',
        'NOT_REQUIRED'
    )
    ON CONFLICT DO NOTHING;

    INSERT INTO metadata.assets
    (
        organization_id,
        site_id,
        asset_type_id,
        parent_asset_id,
        name,
        metering_requirement
    )
    VALUES
    (
        v_org_id,
        v_site_id,
        v_pump_type,
        v_plant_room_id,
        'Primary Pump 1',
        'NOT_REQUIRED'
    )
    ON CONFLICT DO NOTHING;

    INSERT INTO metadata.assets
    (
        organization_id,
        site_id,
        asset_type_id,
        parent_asset_id,
        name,
        metering_requirement
    )
    VALUES
    (
        v_org_id,
        v_site_id,
        v_pump_type,
        v_plant_room_id,
        'Secondary Pump 1',
        'NOT_REQUIRED'
    )
    ON CONFLICT DO NOTHING;

END
$$;
