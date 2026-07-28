-- ============================================================================
-- File: 76_01_independent_organization_contract.sql
-- Purpose: Controlled independent EMS organization creation.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.create_organization
(
    p_name TEXT,
    p_code TEXT,
    p_timezone TEXT,
    p_lifecycle_status TEXT,
    p_requested_by TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_name TEXT := btrim(p_name);
    v_code TEXT := upper(btrim(p_code));
    v_timezone TEXT := btrim(p_timezone);
    v_status TEXT := upper(btrim(p_lifecycle_status));
    v_requested_by TEXT := COALESCE(NULLIF(btrim(p_requested_by), ''), current_user);
    v_organization_id UUID;
    v_audit_id UUID := gen_random_uuid();
    v_request JSONB;
    v_result JSONB;
BEGIN
    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'Organization name is required.' USING ERRCODE = '22023';
    END IF;

    IF length(v_name) > 200 THEN
        RAISE EXCEPTION 'Organization name must not exceed 200 characters.' USING ERRCODE = '22023';
    END IF;

    IF v_code IS NULL OR v_code = '' THEN
        RAISE EXCEPTION 'Organization code is required.' USING ERRCODE = '22023';
    END IF;

    IF length(v_code) > 100 OR v_code !~ '^[A-Z0-9_]+$' THEN
        RAISE EXCEPTION 'Organization code may contain only A-Z, 0-9, and underscore.' USING ERRCODE = '22023';
    END IF;

    IF v_timezone IS NULL OR v_timezone = '' OR NOT EXISTS
    (
        SELECT 1
        FROM pg_timezone_names
        WHERE name = v_timezone
    ) THEN
        RAISE EXCEPTION 'Select a valid IANA timezone.' USING ERRCODE = '22023';
    END IF;

    IF v_status NOT IN ('DRAFT', 'ACTIVE', 'SUSPENDED', 'DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid organization lifecycle status.' USING ERRCODE = '22023';
    END IF;

    BEGIN
        INSERT INTO metadata.organizations
        (
            name,
            code,
            timezone,
            is_active,
            lifecycle_status
        )
        VALUES
        (
            v_name,
            v_code,
            v_timezone,
            v_status = 'ACTIVE',
            v_status
        )
        RETURNING id INTO v_organization_id;
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION 'Organization code % already exists.', v_code
                USING ERRCODE = '23505';
    END;

    v_request := jsonb_build_object
    (
        'operation', 'CREATE_ORGANIZATION',
        'name', v_name,
        'code', v_code,
        'timezone', v_timezone,
        'lifecycle_status', v_status
    );

    v_result := jsonb_build_object
    (
        'success', TRUE,
        'entity_type', 'ORGANIZATION',
        'entity_id', v_organization_id,
        'lifecycle_status', v_status,
        'commissioning_status', NULL,
        'validation_warnings', '[]'::jsonb,
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id,
        'organization_id', v_organization_id,
        'organization_code', v_code,
        'organization_name', v_name,
        'timezone', v_timezone
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
        v_requested_by,
        v_request,
        v_result
    );

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION admin.create_organization(TEXT, TEXT, TEXT, TEXT, TEXT) IS
'Creates one EMS organization independently of sites and downstream entities, returning the shared entity result contract and an audit transaction ID.';

ALTER FUNCTION admin.create_organization(TEXT, TEXT, TEXT, TEXT, TEXT)
    OWNER TO ems_admin;

REVOKE ALL
    ON FUNCTION admin.create_organization(TEXT, TEXT, TEXT, TEXT, TEXT)
    FROM PUBLIC;

GRANT EXECUTE
    ON FUNCTION admin.create_organization(TEXT, TEXT, TEXT, TEXT, TEXT)
    TO ems_app;
