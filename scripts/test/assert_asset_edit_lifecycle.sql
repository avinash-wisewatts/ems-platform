\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
    v_org UUID;
    v_site UUID;
    v_type UUID;
    v_actor BIGINT;

    v_parent JSONB;
    v_child JSONB;
    v_updated JSONB;

    v_parent_id UUID;
    v_child_id UUID;
    v_audit_id UUID;
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
        'Epic 5 Edit Test Organization',
        'EPIC5_EDIT_TEST_ORG',
        'Europe/London',
        'ACTIVE',
        TRUE
    )
    RETURNING id INTO v_org;

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
        v_org,
        'Epic 5 Edit Test Site',
        'EPIC5_EDIT_TEST_SITE',
        'Europe/London',
        'ACTIVE',
        TRUE
    )
    RETURNING id INTO v_site;

    SELECT id
    INTO v_type
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
        'epic5-edit-test@example.test',
        'Epic 5 Edit Test Admin',
        'test-only-password-hash',
        'ORG_ADMIN',
        v_org,
        'ORGANIZATION',
        'epic5-edit-test'
    )
    RETURNING portal_user_id INTO v_actor;

    v_parent := admin.create_asset(
        p_actor_portal_user_id => v_actor,
        p_organization_id => v_org,
        p_site_id => v_site,
        p_name => 'Edit Test Parent',
        p_asset_type_id => v_type,
        p_lifecycle_status => 'ACTIVE',
        p_metering_requirement => 'NOT_REQUIRED',
        p_building_id => NULL,
        p_floor_id => NULL,
        p_space_id => NULL,
        p_parent_asset_id => NULL
    );

    v_parent_id := (v_parent ->> 'asset_id')::UUID;

    v_child := admin.create_asset(
        p_actor_portal_user_id => v_actor,
        p_organization_id => v_org,
        p_site_id => v_site,
        p_name => 'Edit Test Child',
        p_asset_type_id => v_type,
        p_lifecycle_status => 'ACTIVE',
        p_metering_requirement => 'NOT_REQUIRED',
        p_building_id => NULL,
        p_floor_id => NULL,
        p_space_id => NULL,
        p_parent_asset_id => v_parent_id
    );

    v_child_id := (v_child ->> 'asset_id')::UUID;

    -- The child is still ACTIVE here, so it must block
    -- decommissioning of its parent.
    BEGIN
        PERFORM admin.update_asset(
            p_actor_portal_user_id => v_actor,
            p_asset_id => v_parent_id,
            p_name => 'Edit Test Parent',
            p_asset_type_id => v_type,
            p_lifecycle_status => 'DECOMMISSIONED',
            p_metering_requirement => 'NOT_REQUIRED',
            p_building_id => NULL,
            p_floor_id => NULL,
            p_space_id => NULL,
            p_parent_asset_id => NULL
        );

        RAISE EXCEPTION
            'Parent decommissioning unexpectedly succeeded.';
    EXCEPTION
        WHEN invalid_parameter_value THEN
            NULL;
    END;

    v_updated := admin.update_asset(
        p_actor_portal_user_id => v_actor,
        p_asset_id => v_child_id,
        p_name => 'Edited Test Child',
        p_asset_type_id => v_type,
        p_lifecycle_status => 'INACTIVE',
        p_metering_requirement => 'DIRECT_METER_REQUIRED',
        p_building_id => NULL,
        p_floor_id => NULL,
        p_space_id => NULL,
        p_parent_asset_id => v_parent_id
    );

    v_audit_id :=
        (v_updated ->> 'audit_transaction_id')::UUID;

    IF v_updated ->> 'asset_name'
       <> 'Edited Test Child' THEN
        RAISE EXCEPTION
            'Asset edit did not update the name: %',
            v_updated;
    END IF;

    IF v_updated ->> 'lifecycle_status'
       <> 'INACTIVE'
       OR v_updated ->> 'legacy_status'
          <> 'inactive'
       OR v_updated ->> 'coverage_status'
          <> 'OUT_OF_SCOPE_INACTIVE' THEN
        RAISE EXCEPTION
            'Lifecycle and coverage were not synchronized: %',
            v_updated;
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.assets AS asset
        WHERE asset.id = v_child_id
          AND asset.organization_id = v_org
          AND asset.site_id = v_site
          AND asset.name = 'Edited Test Child'
          AND asset.parent_asset_id = v_parent_id
          AND asset.lifecycle_status = 'INACTIVE'
          AND asset.status = 'inactive'
          AND asset.metering_requirement =
              'DIRECT_METER_REQUIRED'
    ) THEN
        RAISE EXCEPTION
            'Edited asset values were not persisted.';
    END IF;

    BEGIN
        PERFORM admin.update_asset(
            p_actor_portal_user_id => v_actor,
            p_asset_id => v_child_id,
            p_name => 'Edited Test Child',
            p_asset_type_id => v_type,
            p_lifecycle_status => 'ACTIVE',
            p_metering_requirement => 'DIRECT_METER_REQUIRED',
            p_building_id => NULL,
            p_floor_id => NULL,
            p_space_id => NULL,
            p_parent_asset_id => v_parent_id
        );

        RAISE EXCEPTION
            'Routine editing unexpectedly activated the asset.';
    EXCEPTION
        WHEN invalid_parameter_value THEN
            NULL;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM admin.onboarding_audit AS audit_record
        WHERE audit_record.id = v_audit_id
          AND audit_record.request_payload
              ->> 'operation' = 'UPDATE_ASSET'
          AND audit_record.request_payload
              ->> 'immutable_organization_id' = v_org::TEXT
          AND audit_record.request_payload
              ->> 'immutable_site_id' = v_site::TEXT
          AND audit_record.request_payload
              -> 'before'
              ->> 'lifecycle_status' = 'ACTIVE'
          AND audit_record.request_payload
              -> 'after'
              ->> 'lifecycle_status' = 'INACTIVE'
    ) THEN
        RAISE EXCEPTION
            'Expected update audit record was not found.';
    END IF;

    RAISE NOTICE
        'Epic 5 asset edit and lifecycle assertions passed.';
END;
$test$;

ROLLBACK;
