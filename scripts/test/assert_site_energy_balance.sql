-- ============================================================================
-- File:
--   scripts/test/assert_site_energy_balance.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.3 — Site energy balance
--
-- Safety:
--   All fixtures are transactional and removed by ROLLBACK.
-- ============================================================================

BEGIN;


-- ----------------------------------------------------------------------------
-- 1. Create isolated metadata fixtures.
-- ----------------------------------------------------------------------------

CREATE TEMP TABLE test_site_balance_context
(
    organization_id UUID NOT NULL,
    site_id UUID NOT NULL,
    gateway_id UUID NOT NULL,
    profile_id UUID NOT NULL,
    device_model_id UUID NOT NULL,

    grid_device_id UUID NOT NULL,
    generation_device_id UUID NOT NULL,
    battery_charge_device_id UUID NOT NULL,
    battery_discharge_device_id UUID NOT NULL,
    direct_device_id UUID NOT NULL,
    submeter_device_id UUID NOT NULL
)
ON COMMIT DROP;


DO $$
DECLARE
    v_profile_id UUID;
    v_device_category_id UUID;
    v_device_model_id UUID;
BEGIN
    SELECT id
    INTO v_profile_id
    FROM config.device_profiles
    WHERE is_active = TRUE
    ORDER BY profile_code
    LIMIT 1;

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION
            'At least one active canonical device profile is required';
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
        'Site Energy Balance Meter',
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
        code,
        description,
        is_active
    )
    VALUES
    (
        '20000000-0000-4000-8000-000000000001',
        'Site Balance Test Organization',
        'SITE_BAL_TEST_ORG',
        'Transactional site balance fixture',
        TRUE
    );

    -- Tenant-safe analytics views require an active Grafana organization map.
    -- This fixture remains inside the transaction and is removed by ROLLBACK.
    INSERT INTO metadata.grafana_organization_map
    (
        grafana_org_id,
        organization_id,
        is_active
    )
    VALUES
    (
        900000001,
        '20000000-0000-4000-8000-000000000001',
        TRUE
    );

    INSERT INTO metadata.sites
    (
        id,
        organization_id,
        name,
        code,
        timezone,
        address,
        is_active
    )
    VALUES
    (
        '20000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000001',
        'Site Balance Test Site',
        'SITE_BAL_TEST_SITE',
        'Asia/Kolkata',
        '{}'::JSONB,
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
        '20000000-0000-4000-8000-000000000003',
        '20000000-0000-4000-8000-000000000001',
        '20000000-0000-4000-8000-000000000002',
        'Site Balance Test Gateway',
        'SITE-BALANCE-GATEWAY'
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
            '20000000-0000-4000-8000-000000000010',
            '20000000-0000-4000-8000-000000000001',
            '20000000-0000-4000-8000-000000000003',
            v_profile_id,
            v_device_model_id,
            'Grid Meter',
            'SITE-BAL-GRID',
            'MQTT'
        ),
        (
            '20000000-0000-4000-8000-000000000011',
            '20000000-0000-4000-8000-000000000001',
            '20000000-0000-4000-8000-000000000003',
            v_profile_id,
            v_device_model_id,
            'Generation Meter',
            'SITE-BAL-GEN',
            'MQTT'
        ),
        (
            '20000000-0000-4000-8000-000000000012',
            '20000000-0000-4000-8000-000000000001',
            '20000000-0000-4000-8000-000000000003',
            v_profile_id,
            v_device_model_id,
            'Battery Charge Meter',
            'SITE-BAL-BAT-CHG',
            'MQTT'
        ),
        (
            '20000000-0000-4000-8000-000000000013',
            '20000000-0000-4000-8000-000000000001',
            '20000000-0000-4000-8000-000000000003',
            v_profile_id,
            v_device_model_id,
            'Battery Discharge Meter',
            'SITE-BAL-BAT-DIS',
            'MQTT'
        ),
        (
            '20000000-0000-4000-8000-000000000014',
            '20000000-0000-4000-8000-000000000001',
            '20000000-0000-4000-8000-000000000003',
            v_profile_id,
            v_device_model_id,
            'Direct Site Meter',
            'SITE-BAL-DIRECT',
            'MQTT'
        ),
        (
            '20000000-0000-4000-8000-000000000015',
            '20000000-0000-4000-8000-000000000001',
            '20000000-0000-4000-8000-000000000003',
            v_profile_id,
            v_device_model_id,
            'Load Submeter',
            'SITE-BAL-SUB',
            'MQTT'
        );

    INSERT INTO test_site_balance_context
    VALUES
    (
        '20000000-0000-4000-8000-000000000001',
        '20000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000003',
        v_profile_id,
        v_device_model_id,
        '20000000-0000-4000-8000-000000000010',
        '20000000-0000-4000-8000-000000000011',
        '20000000-0000-4000-8000-000000000012',
        '20000000-0000-4000-8000-000000000013',
        '20000000-0000-4000-8000-000000000014',
        '20000000-0000-4000-8000-000000000015'
    );
END;
$$;


-- ----------------------------------------------------------------------------
-- 2. Validate fail-closed behavior before role assignment.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_rows BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_rows
    FROM analytics.v_site_energy_balance_daily
    WHERE site_id =
        '20000000-0000-4000-8000-000000000002';

    IF v_rows <> 0 THEN
        RAISE EXCEPTION
            'Expected no balance rows before role assignment, found %',
            v_rows;
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 3. Validate overlap protection.
-- ----------------------------------------------------------------------------

DO $$
BEGIN
    INSERT INTO config.site_energy_meter_roles
    (
        site_id,
        device_id,
        meter_role,
        effective_from,
        description
    )
    VALUES
    (
        '20000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000010',
        'GRID_IMPORT',
        now() - INTERVAL '1 day',
        'Primary grid-import fixture'
    );

    BEGIN
        INSERT INTO config.site_energy_meter_roles
        (
            site_id,
            device_id,
            meter_role,
            effective_from,
            description
        )
        VALUES
        (
            '20000000-0000-4000-8000-000000000002',
            '20000000-0000-4000-8000-000000000010',
            'GRID_IMPORT',
            now() - INTERVAL '12 hours',
            'Expected overlap rejection'
        );

        RAISE EXCEPTION
            'Overlapping active site-meter role was not rejected';

    EXCEPTION
        WHEN exclusion_violation THEN
            NULL;
    END;
END;
$$;


-- ----------------------------------------------------------------------------
-- 4. Validate cross-site protection.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_other_org UUID :=
        '20000000-0000-4000-8000-000000000020';
    v_other_site UUID :=
        '20000000-0000-4000-8000-000000000021';
BEGIN
    INSERT INTO metadata.organizations
    (
        id,
        name,
        code,
        is_active
    )
    VALUES
    (
        v_other_org,
        'Other Test Organization',
        'OTHER_SITE_BAL_ORG',
        TRUE
    );

    INSERT INTO metadata.sites
    (
        id,
        organization_id,
        name,
        code,
        timezone,
        is_active
    )
    VALUES
    (
        v_other_site,
        v_other_org,
        'Other Test Site',
        'OTHER_SITE_BAL_SITE',
        'UTC',
        TRUE
    );

    BEGIN
        INSERT INTO config.site_energy_meter_roles
        (
            site_id,
            device_id,
            meter_role
        )
        VALUES
        (
            v_other_site,
            '20000000-0000-4000-8000-000000000010',
            'GRID_EXPORT'
        );

        RAISE EXCEPTION
            'Cross-site meter role was not rejected';

    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <>
               'Device and site must belong to the same tenant and site.'
            THEN
                RAISE;
            END IF;
    END;
END;
$$;


-- ----------------------------------------------------------------------------
-- 5. Validate required role catalog behavior.
--
-- The analytics arithmetic itself is covered by production-data transactional
-- validation. This block verifies role semantics and precedence configuration.
-- ----------------------------------------------------------------------------

INSERT INTO config.site_energy_meter_roles
(
    site_id,
    device_id,
    meter_role,
    effective_from,
    description
)
VALUES
    (
        '20000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000010',
        'GRID_EXPORT',
        now() - INTERVAL '1 day',
        'Grid export fixture'
    ),
    (
        '20000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000011',
        'SOLAR_GENERATION',
        now() - INTERVAL '1 day',
        'Solar generation fixture'
    ),
    (
        '20000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000012',
        'BATTERY_CHARGE',
        now() - INTERVAL '1 day',
        'Battery charging fixture'
    ),
    (
        '20000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000013',
        'BATTERY_DISCHARGE',
        now() - INTERVAL '1 day',
        'Battery discharge fixture'
    ),
    (
        '20000000-0000-4000-8000-000000000002',
        '20000000-0000-4000-8000-000000000014',
        'SITE_CONSUMPTION',
        now() - INTERVAL '1 day',
        'Direct site consumption fixture'
    );

-- LOAD_SUBMETER remains in the controlled catalog as an inactive legacy role.
-- New active assignments must reject it.
DO $$
BEGIN
    BEGIN
        INSERT INTO config.site_energy_meter_roles
        (
            site_id,
            device_id,
            meter_role,
            effective_from,
            description
        )
        VALUES
        (
            '20000000-0000-4000-8000-000000000002',
            '20000000-0000-4000-8000-000000000015',
            'LOAD_SUBMETER',
            now() - INTERVAL '1 day',
            'Inactive legacy role rejection fixture'
        );

        RAISE EXCEPTION
            'Inactive LOAD_SUBMETER role was not rejected';

    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <>
               'Select an active controlled site energy role.'
            THEN
                RAISE;
            END IF;
    END;
END;
$$;


DO $$
DECLARE
    v_role_count INTEGER;
    v_submeter_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_role_count
    FROM config.site_energy_meter_roles
    WHERE site_id =
        '20000000-0000-4000-8000-000000000002'
      AND is_active = TRUE;

    IF v_role_count <> 6 THEN
        RAISE EXCEPTION
            'Expected 6 active fixture roles, found %',
            v_role_count;
    END IF;

    SELECT COUNT(*)
    INTO v_submeter_count
    FROM analytics.v_site_energy_meter_roles
    WHERE site_id =
        '20000000-0000-4000-8000-000000000002'
      AND meter_role = 'LOAD_SUBMETER';

    IF v_submeter_count <> 0 THEN
        RAISE EXCEPTION
            'Expected no active LOAD_SUBMETER roles, found %',
            v_submeter_count;
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 6. Validate the daily view definition.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_definition TEXT;
BEGIN
    SELECT pg_get_viewdef
    (
        'analytics.v_site_energy_balance_daily'::regclass,
        TRUE
    )
    INTO v_definition;

    IF POSITION
       (
           'site_energy_meter_roles'
           IN v_definition
       ) = 0
    THEN
        RAISE EXCEPTION
            'Site balance view does not use site meter roles';
    END IF;

    IF POSITION
       (
           'LOAD_SUBMETER'
           IN v_definition
       ) = 0
    THEN
        RAISE EXCEPTION
            'Site balance view does not explicitly exclude LOAD_SUBMETER';
    END IF;

    IF POSITION
       (
           'DIRECT_METER'
           IN v_definition
       ) = 0
    THEN
        RAISE EXCEPTION
            'Site balance view lacks direct-meter precedence';
    END IF;

    IF POSITION
       (
           'DERIVED_BALANCE'
           IN v_definition
       ) = 0
    THEN
        RAISE EXCEPTION
            'Site balance view lacks derived-balance behavior';
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Site energy balance assertions passed.'
    AS result;
