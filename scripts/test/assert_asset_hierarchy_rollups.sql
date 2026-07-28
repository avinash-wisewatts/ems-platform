BEGIN;

CREATE TEMP TABLE test_asset_rollup_context
(
    organization_id UUID NOT NULL,
    site_id UUID NOT NULL,
    gateway_id UUID NOT NULL,
    profile_id UUID NOT NULL,
    device_model_id UUID NOT NULL,

    root_asset_id UUID NOT NULL,
    parent_asset_id UUID NOT NULL,
    child_asset_id UUID NOT NULL,

    parent_device_id UUID NOT NULL,
    child_device_id UUID NOT NULL
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
        'Asset Hierarchy Rollup Meter',
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
        is_active
    )
    VALUES
    (
        '30000000-0000-4000-8000-000000000001',
        'Asset Rollup Test Organization',
        'ASSET_ROLLUP_TEST_ORG',
        TRUE
    );

    INSERT INTO metadata.grafana_organization_map
    (
        grafana_org_id,
        organization_id,
        is_active
    )
    VALUES
    (
        900000002,
        '30000000-0000-4000-8000-000000000001',
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
        '30000000-0000-4000-8000-000000000002',
        '30000000-0000-4000-8000-000000000001',
        'Asset Rollup Test Site',
        'ASSET_ROLLUP_TEST_SITE',
        'Asia/Kolkata',
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
        '30000000-0000-4000-8000-000000000003',
        '30000000-0000-4000-8000-000000000001',
        '30000000-0000-4000-8000-000000000002',
        'Asset Rollup Test Gateway',
        'ASSET-ROLLUP-GW'
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
            '30000000-0000-4000-8000-000000000010',
            '30000000-0000-4000-8000-000000000001',
            '30000000-0000-4000-8000-000000000002',
            NULL,
            'Rollup Root',
            'active',
            'NOT_REQUIRED'
        ),
        (
            '30000000-0000-4000-8000-000000000011',
            '30000000-0000-4000-8000-000000000001',
            '30000000-0000-4000-8000-000000000002',
            '30000000-0000-4000-8000-000000000010',
            'Rollup Parent',
            'active',
            'NOT_REQUIRED'
        ),
        (
            '30000000-0000-4000-8000-000000000012',
            '30000000-0000-4000-8000-000000000001',
            '30000000-0000-4000-8000-000000000002',
            '30000000-0000-4000-8000-000000000011',
            'Rollup Child',
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
            '30000000-0000-4000-8000-000000000020',
            '30000000-0000-4000-8000-000000000001',
            '30000000-0000-4000-8000-000000000003',
            v_profile_id,
            v_device_model_id,
            'Rollup Parent Meter',
            'ROLLUP-PARENT-METER',
            'MQTT'
        ),
        (
            '30000000-0000-4000-8000-000000000021',
            '30000000-0000-4000-8000-000000000001',
            '30000000-0000-4000-8000-000000000003',
            v_profile_id,
            v_device_model_id,
            'Rollup Child Meter',
            'ROLLUP-CHILD-METER',
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
            '30000000-0000-4000-8000-000000000011',
            '30000000-0000-4000-8000-000000000020',
            'PRIMARY_METER'
        ),
        (
            '30000000-0000-4000-8000-000000000012',
            '30000000-0000-4000-8000-000000000021',
            'PRIMARY_METER'
        );

    INSERT INTO test_asset_rollup_context
    VALUES
    (
        '30000000-0000-4000-8000-000000000001',
        '30000000-0000-4000-8000-000000000002',
        '30000000-0000-4000-8000-000000000003',
        v_profile_id,
        v_device_model_id,

        '30000000-0000-4000-8000-000000000010',
        '30000000-0000-4000-8000-000000000011',
        '30000000-0000-4000-8000-000000000012',

        '30000000-0000-4000-8000-000000000020',
        '30000000-0000-4000-8000-000000000021'
    );
END;
$$;


-- Validate recursive closure depth.
DO $$
DECLARE
    v_depth INTEGER;
BEGIN
    SELECT depth
    INTO v_depth
    FROM analytics.v_asset_hierarchy_closure
    WHERE ancestor_asset_id =
        '30000000-0000-4000-8000-000000000010'
      AND descendant_asset_id =
        '30000000-0000-4000-8000-000000000012';

    IF v_depth <> 2 THEN
        RAISE EXCEPTION
            'Expected recursive closure depth 2, found %',
            v_depth;
    END IF;
END;
$$;


-- Validate self, direct-child and descendant rows.
DO $$
DECLARE
    v_rows INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_rows
    FROM analytics.v_asset_hierarchy_closure
    WHERE ancestor_asset_id =
        '30000000-0000-4000-8000-000000000010';

    IF v_rows <> 3 THEN
        RAISE EXCEPTION
            'Expected 3 closure rows for test root, found %',
            v_rows;
    END IF;
END;
$$;


-- Validate cycle prevention.
DO $$
BEGIN
    BEGIN
        UPDATE metadata.assets
        SET parent_asset_id =
            '30000000-0000-4000-8000-000000000012'
        WHERE id =
            '30000000-0000-4000-8000-000000000010';

        RAISE EXCEPTION
            'Hierarchy cycle was not rejected';

    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM NOT LIKE
               'Asset hierarchy cycle detected%'
            THEN
                RAISE;
            END IF;
    END;
END;
$$;


-- Validate self-parent prevention.
DO $$
BEGIN
    BEGIN
        UPDATE metadata.assets
        SET parent_asset_id = id
        WHERE id =
            '30000000-0000-4000-8000-000000000011';

        RAISE EXCEPTION
            'Self-parent relationship was not rejected';

    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM NOT LIKE
               'Asset % cannot be its own parent'
            THEN
                RAISE;
            END IF;
    END;
END;
$$;


-- Validate the daily rollup contract.
DO $$
DECLARE
    v_definition TEXT;
BEGIN
    SELECT pg_get_viewdef
    (
        'analytics.v_asset_hierarchy_rollup_daily'::regclass,
        TRUE
    )
    INTO v_definition;

    IF POSITION('DIRECT_METER' IN v_definition) = 0 THEN
        RAISE EXCEPTION
            'Daily rollup does not contain direct-meter policy';
    END IF;

    IF POSITION('DESCENDANT_ROLLUP' IN v_definition) = 0 THEN
        RAISE EXCEPTION
            'Daily rollup does not contain descendant fallback';
    END IF;

    IF POSITION('DIRECT_METER_NO_DATA' IN v_definition) = 0 THEN
        RAISE EXCEPTION
            'Daily rollup does not fail closed on missing direct data';
    END IF;
END;
$$;


-- Validate direct-preferred invariant over all currently materialized rows.
DO $$
DECLARE
    v_violations BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_violations
    FROM analytics.v_asset_hierarchy_rollup_daily
    WHERE
        (
            direct_meter_configured
            AND reported_import_consumption_kwh
                IS DISTINCT FROM direct_import_consumption_kwh
        )
        OR
        (
            NOT direct_meter_configured
            AND reported_import_consumption_kwh
                IS DISTINCT FROM descendant_import_consumption_kwh
        )
        OR
        (
            direct_meter_configured
            AND reported_export_consumption_kwh
                IS DISTINCT FROM direct_export_consumption_kwh
        )
        OR
        (
            NOT direct_meter_configured
            AND reported_export_consumption_kwh
                IS DISTINCT FROM descendant_export_consumption_kwh
        );

    IF v_violations <> 0 THEN
        RAISE EXCEPTION
            'Found % DIRECT_PREFERRED policy violation(s)',
            v_violations;
    END IF;
END;
$$;


ROLLBACK;

SELECT
    'Asset hierarchy rollup assertions passed.'
    AS result;
