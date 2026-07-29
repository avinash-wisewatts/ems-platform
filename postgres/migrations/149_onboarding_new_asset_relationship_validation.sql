-- Migration 149
-- Validate existing-device relationships for CREATE_NEW assets before Review.
--
-- The migration runner owns the transaction.

CREATE OR REPLACE FUNCTION admin.validate_onboarding_asset_relationship(
    p_actor_portal_user_id BIGINT,
    p_asset_id UUID,
    p_relationship_type TEXT,
    p_device_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_relationship_type TEXT :=
        upper(btrim(coalesce(p_relationship_type, '')));
    v_site_id UUID;
    v_primary_device_id UUID;
    v_primary_device_name TEXT;
BEGIN
    IF v_relationship_type = '' THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'RELATIONSHIP_REQUIRED',
            'message', 'Select a relationship type.'
        );
    END IF;

    --------------------------------------------------------------------------
    -- Resolve the scope from either the existing Asset or existing Device.
    --------------------------------------------------------------------------

    IF p_asset_id IS NOT NULL THEN
        SELECT a.site_id
          INTO v_site_id
          FROM metadata.assets a
         WHERE a.id = p_asset_id;

        IF v_site_id IS NULL THEN
            RETURN jsonb_build_object(
                'valid', false,
                'code', 'ASSET_NOT_ACCESSIBLE',
                'message',
                    'The selected asset is not available in your current scope.'
            );
        END IF;

    ELSIF p_device_id IS NOT NULL THEN
        SELECT g.site_id
          INTO v_site_id
          FROM metadata.devices d
          JOIN metadata.gateways g
            ON g.id = d.gateway_id
         WHERE d.id = p_device_id;

        IF v_site_id IS NULL THEN
            RETURN jsonb_build_object(
                'valid', false,
                'code', 'DEVICE_NOT_ACCESSIBLE',
                'message',
                    'The selected device is not available in your current scope.'
            );
        END IF;

    ELSE
        -- CREATE_NEW Asset with CREATE_NEW Device has no existing assignment
        -- state to validate at this stage.
        RETURN jsonb_build_object('valid', true);
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        v_site_id
    ) THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'RELATIONSHIP_SCOPE_DENIED',
            'message',
                'The selected asset or device is not available in your current scope.'
        );
    END IF;

    --------------------------------------------------------------------------
    -- Reject an exact duplicate relationship for existing Asset and Device.
    --------------------------------------------------------------------------

    IF p_asset_id IS NOT NULL
       AND p_device_id IS NOT NULL
       AND EXISTS (
            SELECT 1
              FROM metadata.asset_devices ad
             WHERE ad.asset_id = p_asset_id
               AND ad.device_id = p_device_id
               AND ad.relationship_type = v_relationship_type
       )
    THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'RELATIONSHIP_ALREADY_EXISTS',
            'message',
                'The selected device already has this relationship '
                'with the selected asset.'
        );
    END IF;

    IF v_relationship_type <> 'PRIMARY_METER' THEN
        RETURN jsonb_build_object('valid', true);
    END IF;

    --------------------------------------------------------------------------
    -- Existing Asset: ensure it does not already have another primary meter.
    --------------------------------------------------------------------------

    IF p_asset_id IS NOT NULL THEN
        SELECT ad.device_id, d.name
          INTO v_primary_device_id, v_primary_device_name
          FROM metadata.asset_devices ad
          JOIN metadata.devices d
            ON d.id = ad.device_id
         WHERE ad.asset_id = p_asset_id
           AND ad.relationship_type = 'PRIMARY_METER'
         ORDER BY ad.created_at, ad.id
         LIMIT 1;

        IF v_primary_device_id IS NOT NULL
           AND (
                p_device_id IS NULL
                OR v_primary_device_id <> p_device_id
           )
        THEN
            RETURN jsonb_build_object(
                'valid', false,
                'code', 'PRIMARY_METER_EXISTS',
                'message',
                    'This asset already has a primary meter. '
                    'Choose another relationship type.',
                'current_device_id', v_primary_device_id,
                'current_device_name', v_primary_device_name
            );
        END IF;
    END IF;

    --------------------------------------------------------------------------
    -- Existing Device: ensure it is not already primary meter elsewhere.
    --
    -- For CREATE_NEW Asset, p_asset_id is NULL, so any existing primary-meter
    -- assignment is a conflict.
    --------------------------------------------------------------------------

    IF p_device_id IS NOT NULL
       AND EXISTS (
            SELECT 1
              FROM metadata.asset_devices ad
             WHERE ad.device_id = p_device_id
               AND ad.relationship_type = 'PRIMARY_METER'
               AND (
                    p_asset_id IS NULL
                    OR ad.asset_id <> p_asset_id
               )
       )
    THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'DEVICE_PRIMARY_METER_ASSIGNED',
            'message',
                'This device is already the primary meter for another asset.'
        );
    END IF;

    RETURN jsonb_build_object('valid', true);
END;
$$;

ALTER FUNCTION admin.validate_onboarding_asset_relationship(
    BIGINT,
    UUID,
    TEXT,
    UUID
)
OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.validate_onboarding_asset_relationship(
    BIGINT,
    UUID,
    TEXT,
    UUID
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.validate_onboarding_asset_relationship(
    BIGINT,
    UUID,
    TEXT,
    UUID
)
TO ems_app;
