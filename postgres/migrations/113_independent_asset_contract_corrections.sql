-- ============================================================================
-- Migration 113: Independent asset contract corrections
-- ============================================================================
--
-- Corrects Story 5.1 result semantics without changing the established
-- admin.create_asset signature:
--
-- * coverage does not depend on Grafana provisioning;
-- * DIRECT_METER_REQUIRED creation reports MISSING_DIRECT_METER;
-- * asset creation never commissions the asset automatically;
-- * coverage deficiencies remain non-blocking validation warnings.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.create_asset
(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID,
    p_site_id UUID,
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
    v_name TEXT := btrim(p_name);
    v_lifecycle TEXT := upper(btrim(p_lifecycle_status));
    v_metering TEXT := upper(btrim(p_metering_requirement));
    v_asset_id UUID;
    v_audit_id UUID := gen_random_uuid();
    v_coverage_status TEXT;
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
        RAISE EXCEPTION 'Portal actor is not authorized to create assets.'
            USING ERRCODE = '42501';
    END IF;

    IF p_organization_id IS NULL OR p_site_id IS NULL THEN
        RAISE EXCEPTION 'Organization and site are required.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.sites s
        WHERE s.id = p_site_id
          AND s.organization_id = p_organization_id
          AND s.lifecycle_status IN ('DRAFT', 'ACTIVE')
    ) THEN
        RAISE EXCEPTION 'Select a draft or active site in the chosen organization.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        p_site_id
    ) THEN
        RAISE EXCEPTION 'Portal actor cannot access the selected site.'
            USING ERRCODE = '42501';
    END IF;

    IF v_name IS NULL OR v_name = '' OR length(v_name) > 200 THEN
        RAISE EXCEPTION 'Asset name is required and must not exceed 200 characters.'
            USING ERRCODE = '22023';
    END IF;

    IF p_asset_type_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM metadata.asset_types WHERE id = p_asset_type_id
    ) THEN
        RAISE EXCEPTION 'Select a valid asset type.'
            USING ERRCODE = '22023';
    END IF;

    IF v_lifecycle NOT IN (
        'DRAFT', 'COMMISSIONING', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED'
    ) THEN
        RAISE EXCEPTION 'Select a valid asset lifecycle status.'
            USING ERRCODE = '22023';
    END IF;

    IF v_metering NOT IN (
        'DIRECT_METER_REQUIRED',
        'DESCENDANT_COVERAGE_ALLOWED',
        'NOT_REQUIRED'
    ) THEN
        RAISE EXCEPTION 'Select a valid asset metering requirement.'
            USING ERRCODE = '22023';
    END IF;

    IF p_parent_asset_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM metadata.assets parent
        WHERE parent.id = p_parent_asset_id
          AND parent.organization_id = p_organization_id
          AND parent.site_id = p_site_id
    ) THEN
        RAISE EXCEPTION 'Parent asset must belong to the selected organization and site.'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO metadata.assets
    (
        organization_id,
        site_id,
        building_id,
        floor_id,
        space_id,
        asset_type_id,
        parent_asset_id,
        name,
        status,
        lifecycle_status,
        metering_requirement
    )
    VALUES
    (
        p_organization_id,
        p_site_id,
        p_building_id,
        p_floor_id,
        p_space_id,
        p_asset_type_id,
        p_parent_asset_id,
        v_name,
        'active',
        v_lifecycle,
        v_metering
    )
    RETURNING id INTO v_asset_id;

    v_coverage_status :=
        CASE v_metering
            WHEN 'NOT_REQUIRED'
                THEN 'EXCLUDED'
            WHEN 'DIRECT_METER_REQUIRED'
                THEN 'MISSING_DIRECT_METER'
            WHEN 'DESCENDANT_COVERAGE_ALLOWED'
                THEN 'NO_REQUIRED_DESCENDANTS'
        END;

    v_result := jsonb_build_object(
        'success', TRUE,
        'entity_type', 'ASSET',
        'entity_id', v_asset_id,
        'asset_id', v_asset_id,
        'organization_id', p_organization_id,
        'site_id', p_site_id,
        'building_id', p_building_id,
        'floor_id', p_floor_id,
        'space_id', p_space_id,
        'parent_asset_id', p_parent_asset_id,
        'asset_type_id', p_asset_type_id,
        'asset_name', v_name,
        'lifecycle_status', v_lifecycle,
        'commissioning_status', 'NOT_STARTED',
        'metering_requirement', v_metering,
        'coverage_status', COALESCE(v_coverage_status, 'UNKNOWN'),
        'validation_warnings',
            CASE
                WHEN v_coverage_status IN (
                    'MISSING_DIRECT_METER',
                    'MISSING_DESCENDANT_COVERAGE',
                    'NO_REQUIRED_DESCENDANTS'
                )
                THEN jsonb_build_array(v_coverage_status)
                ELSE '[]'::jsonb
            END,
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit
    (id, requested_by, request_payload, result_payload)
    VALUES
    (
        v_audit_id,
        v_actor_username,
        jsonb_build_object(
            'operation', 'CREATE_ASSET',
            'actor_portal_user_id', p_actor_portal_user_id,
            'organization_id', p_organization_id,
            'site_id', p_site_id,
            'asset_type_id', p_asset_type_id,
            'parent_asset_id', p_parent_asset_id,
            'building_id', p_building_id,
            'floor_id', p_floor_id,
            'space_id', p_space_id,
            'name', v_name,
            'lifecycle_status', v_lifecycle,
            'metering_requirement', v_metering
        ),
        v_result
    );

    RETURN v_result;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'An asset with this name already exists under the selected parent.'
            USING ERRCODE = '23505';
END;
$function$;

COMMENT ON FUNCTION admin.create_asset
(
    BIGINT,
    UUID,
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
'Creates an independent asset with optional physical location and parent asset. Creation never commissions the asset and coverage warnings do not block creation.';
