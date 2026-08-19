BEGIN;

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
    v_late_arrival_tolerance_seconds INTEGER;
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

    SELECT p.late_arrival_tolerance_seconds
    INTO v_late_arrival_tolerance_seconds
    FROM config.telemetry_capture_policies p
    WHERE p.site_id = p_site_id
      AND p.is_enabled
      AND p.effective_from <= clock_timestamp()
      AND (
            p.effective_to IS NULL
            OR p.effective_to > clock_timestamp()
          )
    ORDER BY p.effective_from DESC, p.id DESC
    LIMIT 1;

    v_late_arrival_tolerance_seconds :=
        COALESCE(v_late_arrival_tolerance_seconds, 60);

    SELECT config.set_site_telemetry_capture_policy(
        p_site_id,
        p_capture_interval_seconds,
        clock_timestamp(),
        v_late_arrival_tolerance_seconds
    )
    INTO v_policy_id;

    RETURN v_policy_id;
END;
$$;

ALTER FUNCTION admin.set_site_telemetry_capture_interval(
    BIGINT,
    UUID,
    INTEGER,
    TEXT
) OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.set_site_telemetry_capture_interval(
    BIGINT,
    UUID,
    INTEGER,
    TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.set_site_telemetry_capture_interval(
    BIGINT,
    UUID,
    INTEGER,
    TEXT
) TO ems_app;

COMMIT;
