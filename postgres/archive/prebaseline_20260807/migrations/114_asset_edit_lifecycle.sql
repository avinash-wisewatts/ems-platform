-- ============================================================================
-- Migration 114: Controlled asset editing and lifecycle management
-- ============================================================================
--
-- Stories 5.4 and 5.5:
--
-- * one controlled update contract for asset metadata, hierarchy, location,
--   lifecycle, and metering requirement;
-- * organization and site ownership remain immutable;
-- * transitions into ACTIVE are reserved for the commissioning action;
-- * decommissioning preserves history and checks descendants/relationships;
-- * legacy status remains synchronized for coverage evaluation;
-- * every successful change is audited.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.update_asset
(
    p_actor_portal_user_id BIGINT,
    p_asset_id UUID,
    p_name TEXT,
    p_asset_type_id UUID,
    p_lifecycle_status TEXT,
    p_metering_requirement TEXT,
    p_building_id UUID DEFAULT NULL,
    p_floor_id UUID DEFAULT NULL,
    p_space_id UUID DEFAULT NULL,
    p_parent_asset_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
DECLARE
    v_actor_username TEXT;

    v_organization_id UUID;
    v_site_id UUID;

    v_old_name TEXT;
    v_old_asset_type_id UUID;
    v_old_lifecycle_status TEXT;
    v_old_metering_requirement TEXT;
    v_old_building_id UUID;
    v_old_floor_id UUID;
    v_old_space_id UUID;
    v_old_parent_asset_id UUID;

    v_name TEXT := btrim(p_name);
    v_lifecycle TEXT := upper(btrim(p_lifecycle_status));
    v_metering TEXT := upper(btrim(p_metering_requirement));

    v_legacy_status TEXT;
    v_coverage_status TEXT;
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT username
    INTO v_actor_username
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active portal actor was not found.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,
        'asset.manage'
    ) THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to update assets.'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        asset.organization_id,
        asset.site_id,
        asset.name,
        asset.asset_type_id,
        asset.lifecycle_status,
        asset.metering_requirement,
        asset.building_id,
        asset.floor_id,
        asset.space_id,
        asset.parent_asset_id
    INTO
        v_organization_id,
        v_site_id,
        v_old_name,
        v_old_asset_type_id,
        v_old_lifecycle_status,
        v_old_metering_requirement,
        v_old_building_id,
        v_old_floor_id,
        v_old_space_id,
        v_old_parent_asset_id
    FROM metadata.assets AS asset
    WHERE asset.id = p_asset_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Asset was not found.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        v_site_id
    ) THEN
        RAISE EXCEPTION
            'Portal actor cannot access the selected asset.'
            USING ERRCODE = '42501';
    END IF;

    IF v_name IS NULL
       OR v_name = ''
       OR length(v_name) > 200 THEN
        RAISE EXCEPTION
            'Asset name is required and must not exceed 200 characters.'
            USING ERRCODE = '22023';
    END IF;

    IF p_asset_type_id IS NULL
       OR NOT EXISTS
       (
           SELECT 1
           FROM metadata.asset_types
           WHERE id = p_asset_type_id
       ) THEN
        RAISE EXCEPTION 'Select a valid asset type.'
            USING ERRCODE = '22023';
    END IF;

    IF v_lifecycle NOT IN
    (
        'DRAFT',
        'COMMISSIONING',
        'ACTIVE',
        'INACTIVE',
        'DECOMMISSIONED'
    ) THEN
        RAISE EXCEPTION
            'Select a valid asset lifecycle status.'
            USING ERRCODE = '22023';
    END IF;

    IF v_metering NOT IN
    (
        'DIRECT_METER_REQUIRED',
        'DESCENDANT_COVERAGE_ALLOWED',
        'NOT_REQUIRED'
    ) THEN
        RAISE EXCEPTION
            'Select a valid asset metering requirement.'
            USING ERRCODE = '22023';
    END IF;

    IF v_old_lifecycle_status = 'DECOMMISSIONED'
       AND v_lifecycle <> 'DECOMMISSIONED' THEN
        RAISE EXCEPTION
            'A decommissioned asset cannot return to service.'
            USING ERRCODE = '22023';
    END IF;

    IF v_old_lifecycle_status <> 'ACTIVE'
       AND v_lifecycle = 'ACTIVE' THEN
        RAISE EXCEPTION
            'Use the controlled commissioning action to activate an asset.'
            USING ERRCODE = '22023';
    END IF;

    IF v_old_lifecycle_status = 'DRAFT'
       AND v_lifecycle NOT IN
       (
           'DRAFT',
           'COMMISSIONING',
           'INACTIVE',
           'DECOMMISSIONED'
       ) THEN
        RAISE EXCEPTION
            'Invalid asset lifecycle transition.'
            USING ERRCODE = '22023';
    END IF;

    IF v_old_lifecycle_status = 'COMMISSIONING'
       AND v_lifecycle NOT IN
       (
           'DRAFT',
           'COMMISSIONING',
           'INACTIVE',
           'DECOMMISSIONED'
       ) THEN
        RAISE EXCEPTION
            'Invalid asset lifecycle transition.'
            USING ERRCODE = '22023';
    END IF;

    IF v_old_lifecycle_status = 'ACTIVE'
       AND v_lifecycle NOT IN
       (
           'ACTIVE',
           'INACTIVE',
           'DECOMMISSIONED'
       ) THEN
        RAISE EXCEPTION
            'Invalid asset lifecycle transition.'
            USING ERRCODE = '22023';
    END IF;

    IF v_old_lifecycle_status = 'INACTIVE'
       AND v_lifecycle NOT IN
       (
           'DRAFT',
           'COMMISSIONING',
           'INACTIVE',
           'DECOMMISSIONED'
       ) THEN
        RAISE EXCEPTION
            'Invalid asset lifecycle transition.'
            USING ERRCODE = '22023';
    END IF;

    IF p_parent_asset_id = p_asset_id THEN
        RAISE EXCEPTION
            'An asset cannot be its own parent.'
            USING ERRCODE = '22023';
    END IF;

    IF p_parent_asset_id IS NOT NULL
       AND NOT EXISTS
       (
           SELECT 1
           FROM metadata.assets AS parent
           WHERE parent.id = p_parent_asset_id
             AND parent.organization_id = v_organization_id
             AND parent.site_id = v_site_id
             AND parent.lifecycle_status <> 'DECOMMISSIONED'
       ) THEN
        RAISE EXCEPTION
            'Parent asset must be available in the same organization and site.'
            USING ERRCODE = '22023';
    END IF;

    IF v_lifecycle = 'DECOMMISSIONED'
       AND v_old_lifecycle_status <> 'DECOMMISSIONED' THEN

        IF EXISTS
        (
            WITH RECURSIVE descendants AS
            (
                SELECT child.id
                FROM metadata.assets AS child
                WHERE child.parent_asset_id = p_asset_id

                UNION ALL

                SELECT child.id
                FROM metadata.assets AS child
                JOIN descendants AS ancestor
                  ON child.parent_asset_id = ancestor.id
            )
            SELECT 1
            FROM descendants
            JOIN metadata.assets AS descendant
              ON descendant.id = descendants.id
            WHERE descendant.lifecycle_status IN
            (
                'COMMISSIONING',
                'ACTIVE'
            )
        ) THEN
            RAISE EXCEPTION
                'Decommissioning is blocked by active or commissioning descendants.'
                USING ERRCODE = '22023';
        END IF;

        IF EXISTS
        (
            SELECT 1
            FROM metadata.asset_devices
            WHERE asset_id = p_asset_id
        )
        OR EXISTS
        (
            SELECT 1
            FROM metadata.asset_points
            WHERE asset_id = p_asset_id
        ) THEN
            RAISE EXCEPTION
                'Decommissioning is blocked by existing asset relationships.'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    v_legacy_status :=
        CASE
            WHEN v_lifecycle = 'ACTIVE'
                THEN 'active'
            ELSE 'inactive'
        END;

    UPDATE metadata.assets
    SET
        name = v_name,
        asset_type_id = p_asset_type_id,
        parent_asset_id = p_parent_asset_id,
        building_id = p_building_id,
        floor_id = p_floor_id,
        space_id = p_space_id,
        lifecycle_status = v_lifecycle,
        status = v_legacy_status,
        metering_requirement = v_metering,
        updated_at = now()
    WHERE id = p_asset_id;

    SELECT coverage.coverage_status
    INTO v_coverage_status
    FROM analytics.v_asset_meter_coverage_configuration AS coverage
    WHERE coverage.asset_id = p_asset_id;

    v_coverage_status := COALESCE(
        v_coverage_status,
        CASE
            WHEN v_lifecycle <> 'ACTIVE'
                THEN 'OUT_OF_SCOPE_INACTIVE'
            WHEN v_metering = 'NOT_REQUIRED'
                THEN 'EXCLUDED'
            WHEN v_metering = 'DIRECT_METER_REQUIRED'
                THEN 'MISSING_DIRECT_METER'
            WHEN v_metering = 'DESCENDANT_COVERAGE_ALLOWED'
                THEN 'NO_REQUIRED_DESCENDANTS'
            ELSE 'UNKNOWN_POLICY'
        END
    );

    v_result := jsonb_build_object(
        'success', TRUE,
        'entity_type', 'ASSET',
        'entity_id', p_asset_id,
        'asset_id', p_asset_id,
        'organization_id', v_organization_id,
        'site_id', v_site_id,
        'asset_name', v_name,
        'asset_type_id', p_asset_type_id,
        'parent_asset_id', p_parent_asset_id,
        'building_id', p_building_id,
        'floor_id', p_floor_id,
        'space_id', p_space_id,
        'lifecycle_status', v_lifecycle,
        'legacy_status', v_legacy_status,
        'commissioning_status',
            CASE
                WHEN v_lifecycle = 'ACTIVE'
                    THEN 'COMMISSIONED'
                WHEN v_lifecycle = 'COMMISSIONING'
                    THEN 'IN_PROGRESS'
                ELSE 'NOT_STARTED'
            END,
        'metering_requirement', v_metering,
        'coverage_status', v_coverage_status,
        'validation_warnings',
            CASE
                WHEN v_coverage_status IN
                (
                    'MISSING_DIRECT_METER',
                    'MISSING_DESCENDANT_COVERAGE',
                    'PARTIALLY_CONFIGURED',
                    'NO_REQUIRED_DESCENDANTS'
                )
                THEN jsonb_build_array(v_coverage_status)
                ELSE '[]'::jsonb
            END,
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit
    (
        id,
        requested_by,
        request_payload,
        result_payload
    )
    VALUES
    (
        v_audit_id,
        v_actor_username,
        jsonb_build_object(
            'operation', 'UPDATE_ASSET',
            'actor_portal_user_id', p_actor_portal_user_id,
            'asset_id', p_asset_id,
            'immutable_organization_id', v_organization_id,
            'immutable_site_id', v_site_id,
            'before', jsonb_build_object(
                'name', v_old_name,
                'asset_type_id', v_old_asset_type_id,
                'parent_asset_id', v_old_parent_asset_id,
                'building_id', v_old_building_id,
                'floor_id', v_old_floor_id,
                'space_id', v_old_space_id,
                'lifecycle_status', v_old_lifecycle_status,
                'metering_requirement',
                    v_old_metering_requirement
            ),
            'after', jsonb_build_object(
                'name', v_name,
                'asset_type_id', p_asset_type_id,
                'parent_asset_id', p_parent_asset_id,
                'building_id', p_building_id,
                'floor_id', p_floor_id,
                'space_id', p_space_id,
                'lifecycle_status', v_lifecycle,
                'metering_requirement', v_metering
            )
        ),
        v_result
    );

    RETURN v_result;

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION
            'An asset with this name already exists under the selected parent.'
            USING ERRCODE = '23505';
END;
$function$;

COMMENT ON FUNCTION admin.update_asset
(
    BIGINT,
    UUID,
    TEXT,
    UUID,
    TEXT,
    TEXT,
    UUID,
    UUID,
    UUID,
    UUID
)
IS
'Updates an accessible asset while preserving organization/site ownership, enforcing lifecycle and dependency rules, synchronizing legacy coverage status, and auditing the change.';

ALTER FUNCTION admin.update_asset
(
    BIGINT,
    UUID,
    TEXT,
    UUID,
    TEXT,
    TEXT,
    UUID,
    UUID,
    UUID,
    UUID
)
OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.update_asset
(
    BIGINT,
    UUID,
    TEXT,
    UUID,
    TEXT,
    TEXT,
    UUID,
    UUID,
    UUID,
    UUID
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.update_asset
(
    BIGINT,
    UUID,
    TEXT,
    UUID,
    TEXT,
    TEXT,
    UUID,
    UUID,
    UUID,
    UUID
)
TO ems_app;
