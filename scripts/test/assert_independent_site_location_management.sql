\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
    v_org_one UUID;
    v_org_two UUID;

    v_org_one_admin BIGINT;
    v_org_two_admin BIGINT;

    v_site_result JSONB;
    v_building_result JSONB;
    v_floor_result JSONB;
    v_space_result JSONB;

    v_site_id UUID;
    v_building_id UUID;
    v_floor_id UUID;
    v_space_id UUID;

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
        'Epic 4 Test Organization One',
        'EPIC4_TEST_ORG_ONE',
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
        'Epic 4 Test Organization Two',
        'EPIC4_TEST_ORG_TWO',
        'Europe/London',
        'ACTIVE',
        TRUE
    )
    RETURNING id INTO v_org_two;

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
        'epic4-org-one-admin@example.test',
        'Epic 4 Organization One Admin',
        'test-only-password-hash',
        'ORG_ADMIN',
        v_org_one,
        'ORGANIZATION',
        'epic4-database-test'
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
        'epic4-org-two-admin@example.test',
        'Epic 4 Organization Two Admin',
        'test-only-password-hash',
        'ORG_ADMIN',
        v_org_two,
        'ORGANIZATION',
        'epic4-database-test'
    )
    RETURNING portal_user_id INTO v_org_two_admin;

    v_site_result := admin.create_site
    (
        v_org_one_admin,
        v_org_one,
        'Epic 4 Draft Site',
        'EPIC4_DRAFT_SITE',
        'Europe/London',
        'DRAFT'
    );

    IF COALESCE((v_site_result ->> 'success')::BOOLEAN, FALSE)
       IS NOT TRUE THEN
        RAISE EXCEPTION
            'Expected draft-site creation to succeed: %',
            v_site_result;
    END IF;

    IF v_site_result ->> 'entity_type' <> 'SITE' THEN
        RAISE EXCEPTION
            'Unexpected site result contract: %',
            v_site_result;
    END IF;

    v_site_id := (v_site_result ->> 'site_id')::UUID;

    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.sites AS site_record
        WHERE site_record.id = v_site_id
          AND site_record.organization_id = v_org_one
          AND site_record.lifecycle_status = 'DRAFT'
          AND site_record.is_active = FALSE
    ) THEN
        RAISE EXCEPTION
            'Draft site was not persisted with the expected state.';
    END IF;

    v_building_result := admin.create_building
    (
        v_org_one_admin,
        v_site_id,
        'Epic 4 Building',
        'EPIC4_BUILDING'
    );

    v_building_id :=
        (v_building_result ->> 'building_id')::UUID;

    v_floor_result := admin.create_floor
    (
        v_org_one_admin,
        v_building_id,
        'Epic 4 Floor',
        'EPIC4_FLOOR'
    );

    v_floor_id :=
        (v_floor_result ->> 'floor_id')::UUID;

    v_space_result := admin.create_space
    (
        v_org_one_admin,
        v_floor_id,
        'Epic 4 Space',
        'EPIC4_SPACE'
    );

    v_space_id :=
        (v_space_result ->> 'space_id')::UUID;

    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.buildings AS building
        JOIN metadata.floors AS floor_record
          ON floor_record.building_id = building.id
        JOIN metadata.spaces AS space_record
          ON space_record.floor_id = floor_record.id
        WHERE building.id = v_building_id
          AND building.site_id = v_site_id
          AND building.organization_id = v_org_one
          AND floor_record.id = v_floor_id
          AND floor_record.organization_id = v_org_one
          AND space_record.id = v_space_id
          AND space_record.organization_id = v_org_one
    ) THEN
        RAISE EXCEPTION
            'Physical hierarchy ownership was not derived correctly.';
    END IF;

    BEGIN
        PERFORM admin.create_site
        (
            v_org_one_admin,
            v_org_two,
            'Unauthorized Site',
            'UNAUTHORIZED_SITE',
            'Europe/London',
            'ACTIVE'
        );

        RAISE EXCEPTION
            'Cross-organization site creation unexpectedly succeeded.';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;

    BEGIN
        PERFORM admin.create_building
        (
            v_org_two_admin,
            v_site_id,
            'Unauthorized Building',
            'UNAUTHORIZED_BUILDING'
        );

        RAISE EXCEPTION
            'Cross-organization building creation unexpectedly succeeded.';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;

    BEGIN
        PERFORM admin.create_site
        (
            v_org_one_admin,
            v_org_one,
            'Invalid Code Site',
            '1INVALID_SITE',
            'Europe/London',
            'ACTIVE'
        );

        RAISE EXCEPTION
            'Numeric-leading site code unexpectedly succeeded.';
    EXCEPTION
        WHEN invalid_parameter_value THEN
            NULL;
    END;

    BEGIN
        UPDATE metadata.sites
        SET organization_id = v_org_two
        WHERE id = v_site_id;

        RAISE EXCEPTION
            'Site organization ownership unexpectedly changed.';
    EXCEPTION
        WHEN integrity_constraint_violation THEN
            NULL;
    END;

    SELECT count(*)
    INTO v_visible_count
    FROM admin.list_accessible_physical_locations(
        v_org_one_admin
    ) AS location_row
    WHERE location_row.site_id = v_site_id
      AND location_row.building_id = v_building_id
      AND location_row.floor_id = v_floor_id
      AND location_row.space_id = v_space_id;

    IF v_visible_count <> 1 THEN
        RAISE EXCEPTION
            'Owning organization did not receive the complete hierarchy.';
    END IF;

    SELECT count(*)
    INTO v_other_visible_count
    FROM admin.list_accessible_physical_locations(
        v_org_two_admin
    ) AS location_row
    WHERE location_row.site_id = v_site_id;

    IF v_other_visible_count <> 0 THEN
        RAISE EXCEPTION
            'Another organization could read the test hierarchy.';
    END IF;

    SELECT count(*)
    INTO v_audit_count
    FROM admin.onboarding_audit AS audit_record
    WHERE audit_record.id IN
    (
        (v_site_result ->> 'audit_transaction_id')::UUID,
        (v_building_result ->> 'audit_transaction_id')::UUID,
        (v_floor_result ->> 'audit_transaction_id')::UUID,
        (v_space_result ->> 'audit_transaction_id')::UUID
    )
      AND audit_record.request_payload ->> 'operation' IN
      (
          'CREATE_SITE',
          'CREATE_BUILDING',
          'CREATE_FLOOR',
          'CREATE_SPACE'
      );

    IF v_audit_count <> 4 THEN
        RAISE EXCEPTION
            'Expected four Epic 4 audit records, found %.',
            v_audit_count;
    END IF;

    RAISE NOTICE
        'Epic 4 database assertions passed: site %, building %, floor %, space %.',
        v_site_id,
        v_building_id,
        v_floor_id,
        v_space_id;
END;
$test$;

ROLLBACK;
