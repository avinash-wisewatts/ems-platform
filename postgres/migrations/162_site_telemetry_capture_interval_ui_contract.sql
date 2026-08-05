BEGIN;

CREATE OR REPLACE FUNCTION admin.get_site_telemetry_capture_interval
(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_interval INTEGER;
BEGIN
    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        p_site_id
    ) THEN
        RAISE EXCEPTION 'Site is outside the actor access scope.'
            USING ERRCODE = '42501';
    END IF;

    SELECT p.capture_interval_seconds
    INTO v_interval
    FROM config.telemetry_capture_policies AS p
    WHERE p.is_enabled
      AND (p.site_id = p_site_id OR p.site_id IS NULL)
      AND clock_timestamp() >= p.effective_from
      AND (p.effective_to IS NULL OR clock_timestamp() < p.effective_to)
    ORDER BY
        (p.site_id IS NOT NULL) DESC,
        p.effective_from DESC,
        p.id DESC
    LIMIT 1;

    RETURN COALESCE(v_interval, 60);
END;
$$;

CREATE OR REPLACE FUNCTION admin.set_site_telemetry_capture_interval
(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID,
    p_capture_interval_seconds INTEGER,
    p_change_reason TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_policy_id BIGINT;
BEGIN
    IF NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,
        'site.manage'
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to manage sites.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        p_site_id
    ) THEN
        RAISE EXCEPTION 'Site is outside the actor access scope.'
            USING ERRCODE = '42501';
    END IF;

    IF p_capture_interval_seconds NOT IN (10, 30, 60, 300, 900) THEN
        RAISE EXCEPTION
            'Telemetry storage interval must be 10, 30, 60, 300, or 900 seconds.'
            USING ERRCODE = '22023';
    END IF;

    IF NULLIF(btrim(p_change_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Change reason is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT config.set_site_telemetry_capture_policy(
        p_site_id,
        p_capture_interval_seconds,
        clock_timestamp(),
        900
    )
    INTO v_policy_id;

    RETURN v_policy_id;
END;
$$;

ALTER FUNCTION admin.get_site_telemetry_capture_interval(BIGINT, UUID)
    OWNER TO ems_admin;
ALTER FUNCTION admin.set_site_telemetry_capture_interval(BIGINT, UUID, INTEGER, TEXT)
    OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.get_site_telemetry_capture_interval(BIGINT, UUID)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.set_site_telemetry_capture_interval(BIGINT, UUID, INTEGER, TEXT)
    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.get_site_telemetry_capture_interval(BIGINT, UUID)
    TO ems_app;
GRANT EXECUTE ON FUNCTION admin.set_site_telemetry_capture_interval(BIGINT, UUID, INTEGER, TEXT)
    TO ems_app;

COMMIT;
