-- ============================================================================
-- File:
--   scripts/test/assert_interval_quality_rules.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.2 — Configurable interval quality rules
--
-- Purpose:
--   Validate hierarchical rule resolution, effective dating, overlap
--   protection, and live analytics-view integration.
--
-- Safety:
--   All fixture changes execute inside a transaction and are rolled back.
-- ============================================================================

BEGIN;


-- ----------------------------------------------------------------------------
-- 1. Validate the platform default.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_platform_rules INTEGER;
    v_threshold NUMERIC;
BEGIN
    SELECT
        COUNT(*),
        MAX(gap_threshold_minutes)
    INTO
        v_platform_rules,
        v_threshold
    FROM config.interval_quality_rules
    WHERE scope_type = 'PLATFORM'
      AND is_active = TRUE
      AND effective_range @> now();

    IF v_platform_rules <> 1 THEN
        RAISE EXCEPTION
            'Expected exactly one active platform rule, found %',
            v_platform_rules;
    END IF;

    IF v_threshold <> 30 THEN
        RAISE EXCEPTION
            'Expected platform threshold 30, found %',
            v_threshold;
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 2. Create a self-contained metadata fixture.
--
-- Canonical test deployments intentionally exclude demo data, so assertions
-- must not depend on pre-existing organizations, sites, gateways, or devices.
-- Every row below is removed by the final transaction ROLLBACK.
-- ----------------------------------------------------------------------------

CREATE TEMP TABLE test_interval_quality_context
(
    organization_id UUID NOT NULL,
    site_id UUID NOT NULL,
    gateway_id UUID NOT NULL,
    device_id UUID NOT NULL,
    profile_id UUID NOT NULL
)
ON COMMIT DROP;


DO $$
DECLARE
    v_profile_id UUID;
BEGIN
    SELECT id
    INTO v_profile_id
    FROM config.device_profiles
    ORDER BY profile_code
    LIMIT 1;

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION
            'No canonical device profile is available for interval-quality assertions';
    END IF;

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
        '10000000-0000-4000-8000-000000000001'::UUID,
        'Interval Quality Test Organization',
        'IQR_TEST_ORG',
        'Transactional assertion fixture',
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
        '10000000-0000-4000-8000-000000000002'::UUID,
        '10000000-0000-4000-8000-000000000001'::UUID,
        'Interval Quality Test Site',
        'IQR_TEST_SITE',
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
        '10000000-0000-4000-8000-000000000003'::UUID,
        '10000000-0000-4000-8000-000000000001'::UUID,
        '10000000-0000-4000-8000-000000000002'::UUID,
        'Interval Quality Test Gateway',
        'IQR-TEST-GATEWAY-001'
    );

    INSERT INTO metadata.devices
    (
        id,
        organization_id,
        gateway_id,
        profile_id,
        name,
        external_id,
        protocol
    )
    VALUES
    (
        '10000000-0000-4000-8000-000000000004'::UUID,
        '10000000-0000-4000-8000-000000000001'::UUID,
        '10000000-0000-4000-8000-000000000003'::UUID,
        v_profile_id,
        'Interval Quality Test Device',
        'IQR-TEST-DEVICE-001',
        'MQTT'
    );

    INSERT INTO test_interval_quality_context
    (
        organization_id,
        site_id,
        gateway_id,
        device_id,
        profile_id
    )
    VALUES
    (
        '10000000-0000-4000-8000-000000000001'::UUID,
        '10000000-0000-4000-8000-000000000002'::UUID,
        '10000000-0000-4000-8000-000000000003'::UUID,
        '10000000-0000-4000-8000-000000000004'::UUID,
        v_profile_id
    );
END;
$$;


-- ----------------------------------------------------------------------------
-- 3. Validate hierarchical precedence.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_device_id UUID;
    v_profile_id UUID;
    v_site_id UUID;
    v_organization_id UUID;

    v_scope TEXT;
    v_threshold NUMERIC;
BEGIN
    SELECT
        device_id,
        profile_id,
        site_id,
        organization_id
    INTO
        v_device_id,
        v_profile_id,
        v_site_id,
        v_organization_id
    FROM test_interval_quality_context;


    -- Organization rule.
    INSERT INTO config.interval_quality_rules
    (
        organization_id,
        gap_threshold_minutes,
        effective_from,
        description
    )
    VALUES
    (
        v_organization_id,
        45,
        now() - INTERVAL '1 day',
        'Test organization override'
    );


    SELECT
        resolved_scope,
        gap_threshold_minutes
    INTO
        v_scope,
        v_threshold
    FROM config.resolve_interval_quality_rule
    (
        v_device_id,
        now()
    );

    IF v_scope <> 'ORGANIZATION'
       OR v_threshold <> 45
    THEN
        RAISE EXCEPTION
            'Organization precedence failed: scope %, threshold %',
            v_scope,
            v_threshold;
    END IF;


    -- Site rule must override organization.
    INSERT INTO config.interval_quality_rules
    (
        site_id,
        gap_threshold_minutes,
        effective_from,
        description
    )
    VALUES
    (
        v_site_id,
        40,
        now() - INTERVAL '1 day',
        'Test site override'
    );


    SELECT
        resolved_scope,
        gap_threshold_minutes
    INTO
        v_scope,
        v_threshold
    FROM config.resolve_interval_quality_rule
    (
        v_device_id,
        now()
    );

    IF v_scope <> 'SITE'
       OR v_threshold <> 40
    THEN
        RAISE EXCEPTION
            'Site precedence failed: scope %, threshold %',
            v_scope,
            v_threshold;
    END IF;


    -- Profile rule must override site.
    INSERT INTO config.interval_quality_rules
    (
        profile_id,
        gap_threshold_minutes,
        effective_from,
        description
    )
    VALUES
    (
        v_profile_id,
        35,
        now() - INTERVAL '1 day',
        'Test profile override'
    );


    SELECT
        resolved_scope,
        gap_threshold_minutes
    INTO
        v_scope,
        v_threshold
    FROM config.resolve_interval_quality_rule
    (
        v_device_id,
        now()
    );

    IF v_scope <> 'PROFILE'
       OR v_threshold <> 35
    THEN
        RAISE EXCEPTION
            'Profile precedence failed: scope %, threshold %',
            v_scope,
            v_threshold;
    END IF;


    -- Device rule must override every broader scope.
    INSERT INTO config.interval_quality_rules
    (
        device_id,
        gap_threshold_minutes,
        effective_from,
        description
    )
    VALUES
    (
        v_device_id,
        20,
        now() - INTERVAL '1 day',
        'Test device override'
    );


    SELECT
        resolved_scope,
        gap_threshold_minutes
    INTO
        v_scope,
        v_threshold
    FROM config.resolve_interval_quality_rule
    (
        v_device_id,
        now()
    );

    IF v_scope <> 'DEVICE'
       OR v_threshold <> 20
    THEN
        RAISE EXCEPTION
            'Device precedence failed: scope %, threshold %',
            v_scope,
            v_threshold;
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 4. Validate historical effective dating.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_device_id UUID;
    v_threshold NUMERIC;
    v_scope TEXT;
BEGIN
    SELECT device_id
    INTO v_device_id
    FROM test_interval_quality_context;

    -- The device fixture inserted above starts one day ago.
    -- A timestamp two days ago must therefore fall back to the platform rule.

    SELECT
        resolved_scope,
        gap_threshold_minutes
    INTO
        v_scope,
        v_threshold
    FROM config.resolve_interval_quality_rule
    (
        v_device_id,
        now() - INTERVAL '2 days'
    );

    IF v_scope <> 'PLATFORM'
       OR v_threshold <> 30
    THEN
        RAISE EXCEPTION
            'Historical resolution failed: scope %, threshold %',
            v_scope,
            v_threshold;
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 5. Validate overlapping active rules are rejected.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_device_id UUID;
BEGIN
    SELECT device_id
    INTO v_device_id
    FROM test_interval_quality_context;

    BEGIN
        INSERT INTO config.interval_quality_rules
        (
            device_id,
            gap_threshold_minutes,
            effective_from,
            description
        )
        VALUES
        (
            v_device_id,
            25,
            now() - INTERVAL '12 hours',
            'Expected overlap rejection'
        );

        RAISE EXCEPTION
            'Overlapping active device rule was not rejected';

    EXCEPTION
        WHEN exclusion_violation THEN
            NULL;
    END;
END;
$$;


-- ----------------------------------------------------------------------------
-- 6. Validate the production view uses the resolver and classifier.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_definition TEXT;
    v_classifier_references INTEGER;
BEGIN
    SELECT pg_get_viewdef
    (
        'analytics.v_energy_consumption_15min'::regclass,
        TRUE
    )
    INTO v_definition;

    IF POSITION
       (
           'resolve_interval_quality_rule'
           IN v_definition
       ) = 0
    THEN
        RAISE EXCEPTION
            '15-minute consumption view does not use the rule resolver';
    END IF;

    v_classifier_references :=
        (
            LENGTH(v_definition)
            -
            LENGTH
            (
                REPLACE
                (
                    v_definition,
                    'classify_energy_register_delta',
                    ''
                )
            )
        )
        /
        LENGTH('classify_energy_register_delta');

    IF v_classifier_references <> 2 THEN
        RAISE EXCEPTION
            'Expected two classifier references, found %',
            v_classifier_references;
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 7. Validate every current source row resolves a rule.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_unresolved_rows BIGINT;
BEGIN
    WITH source_rows AS
    (
        SELECT
            ca.bucket_start,
            ca.device_id
        FROM telemetry.ca_energy_15min ca

        JOIN metadata.grafana_organization_map gom
          ON gom.organization_id = ca.organization_id
         AND gom.is_active = TRUE
    )
    SELECT COUNT(*)
    INTO v_unresolved_rows
    FROM source_rows sr

    LEFT JOIN LATERAL
    config.resolve_interval_quality_rule
    (
        sr.device_id,
        sr.bucket_start
    ) resolved
      ON TRUE

    WHERE resolved.rule_id IS NULL;

    IF v_unresolved_rows <> 0 THEN
        RAISE EXCEPTION
            '% source interval row(s) have no resolved quality rule',
            v_unresolved_rows;
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Interval quality rule assertions passed.'
    AS result;
