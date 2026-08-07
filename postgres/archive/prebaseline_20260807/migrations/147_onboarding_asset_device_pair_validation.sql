-- Migration 147
-- Reject an Asset-Device pair that is already linked under any relationship.
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
    v_relationship_type TEXT := upper(btrim(coalesce(p_relationship_type, '')));
    v_site_id UUID;
    v_primary_device_id UUID;
    v_primary_device_name TEXT;
BEGIN
    SELECT a.site_id
      INTO v_site_id
      FROM metadata.assets a
     WHERE a.id = p_asset_id;

    IF v_site_id IS NULL
       OR NOT admin.portal_user_can_access_site(
            p_actor_portal_user_id,
            v_site_id
       ) THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'ASSET_NOT_ACCESSIBLE',
            'message', 'The selected asset is not available in your current scope.'
        );
    END IF;

    IF v_relationship_type = '' THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'RELATIONSHIP_REQUIRED',
            'message', 'Select a relationship type.'
        );
    END IF;

    IF p_device_id IS NOT NULL AND EXISTS (
        SELECT 1
          FROM metadata.asset_devices ad
         WHERE ad.asset_id = p_asset_id
           AND ad.device_id = p_device_id
    ) THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'ASSET_DEVICE_ALREADY_LINKED',
            'message',
                'The selected device is already assigned to the '
                'selected asset. Choose another device or asset.'
        );
    END IF;

    IF v_relationship_type <> 'PRIMARY_METER' THEN
        RETURN jsonb_build_object('valid', true);
    END IF;

    SELECT ad.device_id, d.name
      INTO v_primary_device_id, v_primary_device_name
      FROM metadata.asset_devices ad
      JOIN metadata.devices d ON d.id = ad.device_id
     WHERE ad.asset_id = p_asset_id
       AND ad.relationship_type = 'PRIMARY_METER'
     ORDER BY ad.created_at, ad.id
     LIMIT 1;

    IF v_primary_device_id IS NOT NULL
       AND (p_device_id IS NULL OR v_primary_device_id <> p_device_id) THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'PRIMARY_METER_EXISTS',
            'message', 'This asset already has a primary meter. Choose another relationship type.',
            'current_device_id', v_primary_device_id,
            'current_device_name', v_primary_device_name
        );
    END IF;

    IF p_device_id IS NOT NULL AND EXISTS (
        SELECT 1
          FROM metadata.asset_devices ad
         WHERE ad.device_id = p_device_id
           AND ad.relationship_type = 'PRIMARY_METER'
           AND ad.asset_id <> p_asset_id
    ) THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', 'DEVICE_PRIMARY_METER_ASSIGNED',
            'message', 'This device is already the primary meter for another asset.'
        );
    END IF;

    RETURN jsonb_build_object('valid', true);
END;
$$;

ALTER FUNCTION admin.validate_onboarding_asset_relationship(BIGINT, UUID, TEXT, UUID)
    OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.validate_onboarding_asset_relationship(BIGINT, UUID, TEXT, UUID)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.validate_onboarding_asset_relationship(BIGINT, UUID, TEXT, UUID)
    TO ems_app;
