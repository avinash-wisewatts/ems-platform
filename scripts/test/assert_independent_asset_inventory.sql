\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
    v_org_one UUID;
    v_org_two UUID;
    v_site_one UUID;
    v_site_two UUID;
    v_building UUID;
    v_floor UUID;
    v_space UUID;
    v_asset_type UUID;

    v_org_one_admin BIGINT;
    v_org_two_admin BIGINT;

    v_parent_result JSONB;
    v_child_result JSONB;
    v_unmetered_result JSONB;

    v_parent_asset UUID;
    v_child_asset UUID;
    v_unmetered_asset UUID;
    v_other_asset UUID;

    v_visible_count INTEGER;
    v_other_visible_count INTEGER;
    v_audit_count INTEGER;
BEGIN
    INSERT INTO metadata.organizations
    (
        name,
        code,
        timezone,
        lifecycle_status,
        is_active
    )
    VALUES
    (
        'Epic 5 Test Organization One',
        'EPIC5_TEST_ORG_ONE',
        'Europe/London',
        'ACTIVE',
        TRUE
    )
    RETURNING id INTO v_org_one;

    INSERT INTO metadata.organizations
    (
        name,
        code,
        timezone,
        lifecycle_status,
        is_active
    )
    VALUES
    (
        'Epic 5 Test Organization Two',
        'EPIC5_TEST_ORG_TWO',
        'Europe/London',
        'ACTIVE',
        TRUE
    )
    RETURNING id INTO v_org_two;

    INSERT INTO metadata.sites
    (
        organization_id,
        name,
        code,
        timezone,
        lifecycle_status,
        is_active
    )
    VALUES
    (
        v_org_one,
        'Epic 5 Site One',
        'EPIC5_SITE_ONE',
        'Europe/London',
        'ACTIVE',
        TRUE
    )
    RETURNING id INTO v_site_one;

    INSERT INTO metadata.sites
    (
        organization_id,
        name,
        code,
        timezone,
        lifecycle_status,
        is_active
    )
    VALUES
    (
        v_org_two,
        'Epic 5 Site Two',
        'EPIC5_SITE_TWO',
        'Europe/London',
        'ACTIVE',
        TRUE
    )
    RETURNING id INTO v_site_two;

    INSERT INTO metadata.buildings
    (
        organization_id,
        site_id,
        name,
        code
    )
    VALUES
    (
        v_org_one,
        v_site_one,
        'Epic 5 Building',
        'EPIC5_BUILDING'
    )
    RETURNING id INTO v_building;

    INSERT INTO metadata.floors
    (
        organization_id,
        building_id,
        name,
        code
    )
    VALUES
    (
        v_org_one,
        v_building,
        'Epic 5 Floor',
        'EPIC5_FLOOR'
    )
    RETURNING id INTO v_floor;

    INSERT INTO metadata.spaces
    (
        organization_id,
        floor_id,
        name,
        code
    )
    VALUES
    (
        v_org_one,
        v_floor,
        'Epic 5 Space',
        'EPIC5_SPACE'
    )
    RETURNING id INTO v_space;

    SELECT id
    INTO v_asset_type
    FROM admin.v_asset_types
    ORDER BY name
    LIMIT 1;

    INSERT INTO admin.portal_users
    (
        username,
        display_name,
        password_hash,
        role_code,
        organization_id,
        access_scope_mode,
        created_by
    )
    VALUES
    (
        'epic5-org-one-admin@example.test',
        'Epic 5 Organization One Admin',
        'test-only-password-hash',
        'ORG_ADMIN',
        v_org_one,
        'ORGANIZATION',
        'epic5-database-test'
    )
    RETURNING portal_user_id INTO v_org_one_admin;

    INSERT INTO admin.portal_users
    (
        username,
        display_name,
        password_hash,
        role_code,
        organization_id,
        access_scope_mode,
        created_by
    )
    VALUES
    (
        'epic5-org-two-admin@example.test',
        'Epic 5 Organization Two Admin',
        'test-only-password-hash',
        'ORG_ADMIN',
        v_org_two,
        'ORGANIZATION',
        'epic5-database-test'
    )
    RETURNING portal_user_id INTO v_org_two_admin;

    v_parent_result := admin.create_asset(
        p_actor_portal_user_id => v_org_one_admin,
        p_organization_id => v_org_one,
        p_site_id => v_site_one,
        p_name => 'Epic 5 Parent Asset',
        p_asset_type_id => v_asset_type,
        p_lifecycle_status => 'ACTIVE',
        p_metering_requirement => 'NOT_REQUIRED',
        p_building_id => v_building,
        p_floor_id => v_floor,
        p_space_id => v_space,
        p_parent_asset_id => NULL
    );

    v_parent_asset :=
        (v_parent_result ->> 'asset_id')::UUID;

    IF COALESCE(
        (v_parent_result ->> 'success')::BOOLEAN,
        FALSE
    ) IS NOT TRUE THEN
        RAISE EXCEPTION
            'Parent asset creation failed: %',
            v_parent_result;
    END IF;

    IF v_parent_result ->> 'commissioning_status'
       <> 'NOT_STARTED' THEN
        RAISE EXCEPTION
            'Expected parent commissioning to remain not started: %',
            v_parent_result;
    END IF;

    IF v_parent_result ->> 'coverage_status'
       <> 'EXCLUDED' THEN
        RAISE EXCEPTION
            'Expected parent coverage exclusion: %',
            v_parent_result;
    END IF;

    v_child_result := admin.create_asset(
        p_actor_portal_user_id => v_org_one_admin,
        p_organization_id => v_org_one,
        p_site_id => v_site_one,
        p_name => 'Epic 5 Child Asset',
        p_asset_type_id => v_asset_type,
        p_lifecycle_status => 'ACTIVE',
        p_metering_requirement => 'DIRECT_METER_REQUIRED',
        p_building_id => v_building,
        p_floor_id => v_floor,
        p_space_id => v_space,
        p_parent_asset_id => v_parent_asset
    );

    v_child_asset :=
        (v_child_result ->> 'asset_id')::UUID;

    IF v_child_result ->> 'commissioning_status'
       <> 'NOT_STARTED' THEN
        RAISE EXCEPTION
            'Expected child commissioning to remain not started: %',
            v_child_result;
    END IF;

    IF v_child_result ->> 'coverage_status'
       <> 'MISSING_DIRECT_METER' THEN
        RAISE EXCEPTION
            'Expected missing direct meter coverage: %',
            v_child_result;
    END IF;

    IF NOT (
        v_child_result -> 'validation_warnings'
        @> '["MISSING_DIRECT_METER"]'::JSONB
    ) THEN
        RAISE EXCEPTION
            'Expected missing direct meter warning: %',
            v_child_result;
    END IF;

    IF jsonb_array_length(
        v_child_result -> 'blocking_conditions'
    ) <> 0 THEN
        RAISE EXCEPTION
            'Direct-meter warning incorrectly blocked creation: %',
            v_child_result;
    END IF;

    v_unmetered_result := admin.create_asset(
        p_actor_portal_user_id => v_org_one_admin,
        p_organization_id => v_org_one,
        p_site_id => v_site_one,
        p_name => 'Epic 5 Unmetered Asset',
        p_asset_type_id => v_asset_type,
        p_lifecycle_status => 'DRAFT',
        p_metering_requirement => 'NOT_REQUIRED',
        p_building_id => NULL,
        p_floor_id => NULL,
        p_space_id => NULL,
        p_parent_asset_id => NULL
    );

    v_unmetered_asset :=
        (v_unmetered_result ->> 'asset_id')::UUID;

    v_other_asset := (
        admin.create_asset(
            p_actor_portal_user_id => v_org_two_admin,
            p_organization_id => v_org_two,
            p_site_id => v_site_two,
            p_name => 'Epic 5 Other Organization Asset',
            p_asset_type_id => v_asset_type,
            p_lifecycle_status => 'ACTIVE',
            p_metering_requirement => 'NOT_REQUIRED',
            p_building_id => NULL,
            p_floor_id => NULL,
            p_space_id => NULL,
            p_parent_asset_id => NULL
        ) ->> 'asset_id'
    )::UUID;

    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.assets AS asset
        WHERE asset.id = v_child_asset
          AND asset.organization_id = v_org_one
          AND asset.site_id = v_site_one
          AND asset.parent_asset_id = v_parent_asset
          AND asset.building_id = v_building
          AND asset.floor_id = v_floor
          AND asset.space_id = v_space
    ) THEN
        RAISE EXCEPTION
            'Asset hierarchy links were not persisted correctly.';
    END IF;

    BEGIN
        PERFORM admin.create_asset(
            p_actor_portal_user_id => v_org_two_admin,
            p_organization_id => v_org_one,
            p_site_id => v_site_one,
            p_name => 'Unauthorized Asset',
            p_asset_type_id => v_asset_type,
            p_lifecycle_status => 'ACTIVE',
            p_metering_requirement => 'NOT_REQUIRED',
            p_building_id => NULL,
            p_floor_id => NULL,
            p_space_id => NULL,
            p_parent_asset_id => NULL
        );

        RAISE EXCEPTION
            'Cross-tenant asset creation unexpectedly succeeded.';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;

    BEGIN
        PERFORM admin.create_asset(
            p_actor_portal_user_id => v_org_one_admin,
            p_organization_id => v_org_one,
            p_site_id => v_site_one,
            p_name => 'Invalid Parent Asset',
            p_asset_type_id => v_asset_type,
            p_lifecycle_status => 'ACTIVE',
            p_metering_requirement => 'NOT_REQUIRED',
            p_building_id => NULL,
            p_floor_id => NULL,
            p_space_id => NULL,
            p_parent_asset_id => v_other_asset
        );

        RAISE EXCEPTION
            'Cross-organization parent unexpectedly succeeded.';
    EXCEPTION
        WHEN invalid_parameter_value THEN
            NULL;
    END;

    BEGIN
        PERFORM admin.create_asset(
            p_actor_portal_user_id => v_org_one_admin,
            p_organization_id => v_org_one,
            p_site_id => v_site_one,
            p_name => 'Invalid Location Asset',
            p_asset_type_id => v_asset_type,
            p_lifecycle_status => 'ACTIVE',
            p_metering_requirement => 'NOT_REQUIRED',
            p_building_id => NULL,
            p_floor_id => v_floor,
            p_space_id => v_space,
            p_parent_asset_id => NULL
        );

        RAISE EXCEPTION
            'Floor without building unexpectedly succeeded.';
    EXCEPTION
        WHEN invalid_parameter_value
          OR integrity_constraint_violation THEN
            NULL;
    END;

    SELECT count(*)
    INTO v_visible_count
    FROM admin.list_accessible_assets(
        v_org_one_admin
    ) AS asset_row
    WHERE asset_row.asset_id IN
    (
        v_parent_asset,
        v_child_asset,
        v_unmetered_asset
    );

    IF v_visible_count <> 3 THEN
        RAISE EXCEPTION
            'Owning organization could not read all test assets.';
    END IF;

    SELECT count(*)
    INTO v_other_visible_count
    FROM admin.list_accessible_assets(
        v_org_two_admin
    ) AS asset_row
    WHERE asset_row.asset_id IN
    (
        v_parent_asset,
        v_child_asset,
        v_unmetered_asset
    );

    IF v_other_visible_count <> 0 THEN
        RAISE EXCEPTION
            'Another organization could read the test assets.';
    END IF;

    SELECT count(*)
    INTO v_audit_count
    FROM admin.onboarding_audit AS audit_record
    WHERE audit_record.id IN
    (
        (
            v_parent_result
            ->> 'audit_transaction_id'
        )::UUID,
        (
            v_child_result
            ->> 'audit_transaction_id'
        )::UUID,
        (
            v_unmetered_result
            ->> 'audit_transaction_id'
        )::UUID
    )
      AND audit_record.request_payload
          ->> 'operation' = 'CREATE_ASSET';

    IF v_audit_count <> 3 THEN
        RAISE EXCEPTION
            'Expected three asset audit records, found %.',
            v_audit_count;
    END IF;

    RAISE NOTICE
        'Epic 5 database assertions passed: parent %, child %, unmetered %.',
        v_parent_asset,
        v_child_asset,
        v_unmetered_asset;
END;
$test$;

ROLLBACK;
