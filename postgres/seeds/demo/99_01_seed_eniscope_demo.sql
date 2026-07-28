-- ============================================================================
-- File: 99_01_seed_eniscope_demo.sql
-- Purpose:
--   Demo metadata hierarchy for validating Eniscope telemetry ingestion.
--
-- Creates:
--   Organization
--       |
--       Site
--           |
--           Gateway
--               |
--               Device
--
-- This is test data only.
-- ============================================================================


DO $$

DECLARE

    v_org_id UUID;
    v_site_id UUID;
    v_gateway_id UUID;
    v_device_id UUID;

BEGIN


    --------------------------------------------------------------------------
    -- Organization
    --------------------------------------------------------------------------

    INSERT INTO metadata.organizations
    (
        name,
        code
    )
    VALUES
    (
        'WiseWatts Demo',
        'WW-DEMO'
    )
    ON CONFLICT (code)
    DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_org_id;



    --------------------------------------------------------------------------
    -- Site
    --------------------------------------------------------------------------

    INSERT INTO metadata.sites
    (
        organization_id,
        name,
        code
    )
    VALUES
    (
        v_org_id,
        'Demo Hotel Site',
        'HOTEL-DEMO'
    )
    ON CONFLICT (organization_id, code)
    DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_site_id;



    --------------------------------------------------------------------------
    -- Gateway
    --------------------------------------------------------------------------

    INSERT INTO metadata.gateways
    (
        organization_id,
        site_id,
        name,
        external_id
    )
    VALUES
    (
        v_org_id,
        v_site_id,
        'Eniscope Gateway Demo',
        'ENI-GW-DEMO-001'
    )
    RETURNING id INTO v_gateway_id;



    --------------------------------------------------------------------------
    -- Device
    --------------------------------------------------------------------------

    INSERT INTO metadata.devices
    (
        organization_id,
        gateway_id,
        name,
        external_id,
        serial_number,
        protocol
    )
    VALUES
    (
        v_org_id,
        v_gateway_id,
        'Eniscope Energy Meter Demo',
        'ENI-DEMO-001',
        'ENI-SERIAL-001',
        'MQTT'
    )
    RETURNING id INTO v_device_id;


END $$;
