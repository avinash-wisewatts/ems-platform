-- Epic 5: independent asset inventory (Stories 5.1-5.3)

ALTER TABLE metadata.assets
    ADD COLUMN IF NOT EXISTS building_id UUID
        REFERENCES metadata.buildings(id)
        ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS floor_id UUID
        REFERENCES metadata.floors(id)
        ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_assets_building_id
    ON metadata.assets (building_id);
CREATE INDEX IF NOT EXISTS idx_assets_floor_id
    ON metadata.assets (floor_id);

COMMENT ON COLUMN metadata.assets.building_id IS
'Optional most-specific building placement when no floor or space is selected.';
COMMENT ON COLUMN metadata.assets.floor_id IS
'Optional most-specific floor placement when no space is selected.';

CREATE OR REPLACE FUNCTION metadata.validate_asset_physical_location()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_building_org UUID;
    v_building_site UUID;
    v_floor_org UUID;
    v_floor_building UUID;
    v_space_org UUID;
    v_space_floor UUID;
BEGIN
    IF NEW.floor_id IS NOT NULL AND NEW.building_id IS NULL THEN
        RAISE EXCEPTION 'Asset floor requires a building.'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.space_id IS NOT NULL
       AND (NEW.floor_id IS NULL OR NEW.building_id IS NULL) THEN
        RAISE EXCEPTION 'Asset space requires its floor and building.'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.building_id IS NOT NULL THEN
        SELECT organization_id, site_id
        INTO v_building_org, v_building_site
        FROM metadata.buildings
        WHERE id = NEW.building_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected building does not exist.'
                USING ERRCODE = '23503';
        END IF;

        IF v_building_org IS DISTINCT FROM NEW.organization_id
           OR v_building_site IS DISTINCT FROM NEW.site_id THEN
            RAISE EXCEPTION 'Selected building does not belong to the asset organization and site.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NEW.floor_id IS NOT NULL THEN
        SELECT organization_id, building_id
        INTO v_floor_org, v_floor_building
        FROM metadata.floors
        WHERE id = NEW.floor_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected floor does not exist.'
                USING ERRCODE = '23503';
        END IF;

        IF v_floor_org IS DISTINCT FROM NEW.organization_id
           OR v_floor_building IS DISTINCT FROM NEW.building_id THEN
            RAISE EXCEPTION 'Selected floor does not belong to the selected building.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NEW.space_id IS NOT NULL THEN
        SELECT organization_id, floor_id
        INTO v_space_org, v_space_floor
        FROM metadata.spaces
        WHERE id = NEW.space_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected space does not exist.'
                USING ERRCODE = '23503';
        END IF;

        IF v_space_org IS DISTINCT FROM NEW.organization_id
           OR v_space_floor IS DISTINCT FROM NEW.floor_id THEN
            RAISE EXCEPTION 'Selected space does not belong to the selected floor.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS assets_validate_physical_location
ON metadata.assets;

CREATE TRIGGER assets_validate_physical_location
BEFORE INSERT OR UPDATE OF
    organization_id,
    site_id,
    building_id,
    floor_id,
    space_id
ON metadata.assets
FOR EACH ROW
EXECUTE FUNCTION metadata.validate_asset_physical_location();

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

    SELECT coverage_status
    INTO v_coverage_status
    FROM analytics.v_asset_meter_coverage_configuration
    WHERE asset_id = v_asset_id;

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
        'commissioning_status',
            CASE WHEN v_lifecycle = 'ACTIVE' THEN 'ACTIVE' ELSE 'NOT_COMMISSIONED' END,
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

CREATE OR REPLACE FUNCTION admin.list_accessible_assets
(
    p_actor_portal_user_id BIGINT
)
RETURNS TABLE
(
    organization_id UUID,
    organization_code TEXT,
    organization_name TEXT,
    site_id UUID,
    site_code TEXT,
    site_name TEXT,
    asset_id UUID,
    asset_name TEXT,
    asset_type_id UUID,
    asset_type_name TEXT,
    parent_asset_id UUID,
    parent_asset_name TEXT,
    building_id UUID,
    building_name TEXT,
    floor_id UUID,
    floor_name TEXT,
    space_id UUID,
    space_name TEXT,
    lifecycle_status TEXT,
    metering_requirement TEXT,
    coverage_status TEXT
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
    SELECT
        asset.organization_id,
        organization.code,
        organization.name,
        asset.site_id,
        site.code,
        site.name,
        asset.id,
        asset.name,
        asset.asset_type_id,
        asset_type.name,
        asset.parent_asset_id,
        parent.name,
        asset.building_id,
        building.name,
        asset.floor_id,
        floor_record.name,
        asset.space_id,
        space_record.name,
        asset.lifecycle_status,
        asset.metering_requirement,
        coverage.coverage_status
    FROM metadata.assets asset
    JOIN metadata.organizations organization
      ON organization.id = asset.organization_id
    JOIN metadata.sites site
      ON site.id = asset.site_id
    LEFT JOIN metadata.asset_types asset_type
      ON asset_type.id = asset.asset_type_id
    LEFT JOIN metadata.assets parent
      ON parent.id = asset.parent_asset_id
    LEFT JOIN metadata.buildings building
      ON building.id = asset.building_id
    LEFT JOIN metadata.floors floor_record
      ON floor_record.id = asset.floor_id
    LEFT JOIN metadata.spaces space_record
      ON space_record.id = asset.space_id
    LEFT JOIN analytics.v_asset_meter_coverage_configuration coverage
      ON coverage.asset_id = asset.id
    WHERE admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        asset.site_id
    )
    ORDER BY organization.name, site.name, asset.name;
$function$;

COMMENT ON FUNCTION admin.create_asset(
    BIGINT, UUID, UUID, TEXT, UUID, TEXT, TEXT, UUID, UUID, UUID, UUID
) IS
'Creates one independent asset with optional physical placement and parent asset, and returns the shared entity result contract.';

COMMENT ON FUNCTION admin.list_accessible_assets(BIGINT) IS
'Lists assets in sites accessible to one active portal user.';

ALTER FUNCTION metadata.validate_asset_physical_location()
    OWNER TO ems_admin;
ALTER FUNCTION admin.create_asset(
    BIGINT, UUID, UUID, TEXT, UUID, TEXT, TEXT, UUID, UUID, UUID, UUID
) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_assets(BIGINT)
    OWNER TO ems_admin;

REVOKE ALL ON FUNCTION metadata.validate_asset_physical_location()
    FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.create_asset(
    BIGINT, UUID, UUID, TEXT, UUID, TEXT, TEXT, UUID, UUID, UUID, UUID
) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_assets(BIGINT)
    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.create_asset(
    BIGINT, UUID, UUID, TEXT, UUID, TEXT, TEXT, UUID, UUID, UUID, UUID
) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_assets(BIGINT)
    TO ems_app;
