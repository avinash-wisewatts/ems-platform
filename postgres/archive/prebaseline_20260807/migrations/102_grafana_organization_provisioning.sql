-- Story 2.2: automatic Grafana organization provisioning state.

CREATE TABLE IF NOT EXISTS admin.grafana_organization_provisioning
(
    organization_id UUID PRIMARY KEY,

    status_domain TEXT NOT NULL
        DEFAULT 'GRAFANA_PROVISIONING_STATUS',

    provisioning_status TEXT NOT NULL
        DEFAULT 'NOT_STARTED',

    grafana_org_id BIGINT,

    attempt_count INTEGER NOT NULL DEFAULT 0,

    last_attempt_at TIMESTAMPTZ,

    provisioned_at TIMESTAMPTZ,

    last_error TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT grafana_org_provisioning_organization_fk
        FOREIGN KEY (organization_id)
        REFERENCES metadata.organizations(id)
        ON DELETE RESTRICT,

    CONSTRAINT grafana_org_provisioning_mapping_fk
        FOREIGN KEY (grafana_org_id)
        REFERENCES metadata.grafana_organization_map(grafana_org_id)
        ON DELETE RESTRICT,

    CONSTRAINT grafana_org_provisioning_status_fk
        FOREIGN KEY (status_domain, provisioning_status)
        REFERENCES config.status_definitions(status_domain, code)
        ON DELETE RESTRICT,

    CONSTRAINT grafana_org_provisioning_status_domain_chk
        CHECK (
            status_domain = 'GRAFANA_PROVISIONING_STATUS'
        ),

    CONSTRAINT grafana_org_provisioning_attempt_count_chk
        CHECK (attempt_count >= 0),

    CONSTRAINT grafana_org_provisioning_positive_org_id_chk
        CHECK (
            grafana_org_id IS NULL
            OR grafana_org_id > 0
        ),

    CONSTRAINT grafana_org_provisioning_error_state_chk
        CHECK (
            provisioning_status = 'FAILED'
            OR last_error IS NULL
        ),

    CONSTRAINT grafana_org_provisioning_success_state_chk
        CHECK (
            provisioning_status <> 'PROVISIONED'
            OR (
                grafana_org_id IS NOT NULL
                AND provisioned_at IS NOT NULL
            )
        )
);

COMMENT ON TABLE admin.grafana_organization_provisioning IS
'Tracks Grafana provisioning attempts and outcomes for each EMS organization.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.organization_id IS
'EMS organization being provisioned in Grafana.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.provisioning_status IS
'Controlled GRAFANA_PROVISIONING_STATUS code.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.grafana_org_id IS
'Mapped Grafana organization ID after successful provisioning.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.attempt_count IS
'Number of provisioning attempts started for this organization.';

COMMENT ON COLUMN
    admin.grafana_organization_provisioning.last_error IS
'Most recent provisioning failure message, retained only for FAILED status.';


-- Backfill successful state for existing one-to-one mappings.
INSERT INTO admin.grafana_organization_provisioning
(
    organization_id,
    provisioning_status,
    grafana_org_id,
    attempt_count,
    last_attempt_at,
    provisioned_at,
    last_error
)
SELECT
    mapping.organization_id,
    'PROVISIONED',
    mapping.grafana_org_id,
    1,
    mapping.updated_at,
    mapping.updated_at,
    NULL
FROM metadata.grafana_organization_map mapping
ON CONFLICT (organization_id)
DO UPDATE SET
    provisioning_status = 'PROVISIONED',
    grafana_org_id = EXCLUDED.grafana_org_id,
    attempt_count = GREATEST(
        admin.grafana_organization_provisioning.attempt_count,
        EXCLUDED.attempt_count
    ),
    last_attempt_at = COALESCE(
        admin.grafana_organization_provisioning.last_attempt_at,
        EXCLUDED.last_attempt_at
    ),
    provisioned_at = COALESCE(
        admin.grafana_organization_provisioning.provisioned_at,
        EXCLUDED.provisioned_at
    ),
    last_error = NULL,
    updated_at = now();


CREATE OR REPLACE FUNCTION admin.get_grafana_provisioning
(
    p_organization_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object
    (
        'organization_id', provisioning.organization_id,
        'provisioning_status', provisioning.provisioning_status,
        'grafana_org_id', provisioning.grafana_org_id,
        'attempt_count', provisioning.attempt_count,
        'last_attempt_at', provisioning.last_attempt_at,
        'provisioned_at', provisioning.provisioned_at,
        'last_error', provisioning.last_error
    )
    INTO v_result
    FROM admin.grafana_organization_provisioning provisioning
    WHERE provisioning.organization_id = p_organization_id;

    RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION admin.mark_grafana_provisioning_pending
(
    p_organization_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_result JSONB;
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.organizations organization_record
        WHERE organization_record.id = p_organization_id
    ) THEN
        RAISE EXCEPTION
            'EMS organization % does not exist.',
            p_organization_id
            USING ERRCODE = '23503';
    END IF;

    INSERT INTO admin.grafana_organization_provisioning
    (
        organization_id,
        provisioning_status,
        grafana_org_id,
        attempt_count,
        last_attempt_at,
        provisioned_at,
        last_error
    )
    VALUES
    (
        p_organization_id,
        'PENDING',
        NULL,
        1,
        clock_timestamp(),
        NULL,
        NULL
    )
    ON CONFLICT (organization_id)
    DO UPDATE SET
        provisioning_status = 'PENDING',
        attempt_count =
            admin.grafana_organization_provisioning.attempt_count + 1,
        last_attempt_at = clock_timestamp(),
        last_error = NULL,
        updated_at = clock_timestamp();

    SELECT admin.get_grafana_provisioning(
        p_organization_id
    )
    INTO v_result;

    RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION admin.mark_grafana_provisioning_failed
(
    p_organization_id UUID,
    p_error TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_error TEXT := NULLIF(btrim(p_error), '');
    v_result JSONB;
BEGIN
    IF v_error IS NULL THEN
        v_error := 'Grafana provisioning failed.';
    END IF;

    IF length(v_error) > 4000 THEN
        v_error := left(v_error, 4000);
    END IF;

    INSERT INTO admin.grafana_organization_provisioning
    (
        organization_id,
        provisioning_status,
        grafana_org_id,
        attempt_count,
        last_attempt_at,
        provisioned_at,
        last_error
    )
    VALUES
    (
        p_organization_id,
        'FAILED',
        NULL,
        1,
        clock_timestamp(),
        NULL,
        v_error
    )
    ON CONFLICT (organization_id)
    DO UPDATE SET
        provisioning_status = 'FAILED',
        last_error = v_error,
        updated_at = clock_timestamp();

    SELECT admin.get_grafana_provisioning(
        p_organization_id
    )
    INTO v_result;

    RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION admin.mark_grafana_provisioning_complete
(
    p_organization_id UUID,
    p_grafana_org_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS $$
DECLARE
    v_existing_grafana_org_id BIGINT;
    v_existing_organization_id UUID;
    v_result JSONB;
BEGIN
    IF p_grafana_org_id IS NULL OR p_grafana_org_id <= 0 THEN
        RAISE EXCEPTION
            'Grafana organization ID must be a positive integer.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.organizations organization_record
        WHERE organization_record.id = p_organization_id
    ) THEN
        RAISE EXCEPTION
            'EMS organization % does not exist.',
            p_organization_id
            USING ERRCODE = '23503';
    END IF;

    SELECT mapping.grafana_org_id
    INTO v_existing_grafana_org_id
    FROM metadata.grafana_organization_map mapping
    WHERE mapping.organization_id = p_organization_id;

    IF v_existing_grafana_org_id IS NOT NULL
       AND v_existing_grafana_org_id <> p_grafana_org_id
    THEN
        RAISE EXCEPTION
            'EMS organization % is already mapped to Grafana org %.',
            p_organization_id,
            v_existing_grafana_org_id
            USING ERRCODE = '23505';
    END IF;

    SELECT mapping.organization_id
    INTO v_existing_organization_id
    FROM metadata.grafana_organization_map mapping
    WHERE mapping.grafana_org_id = p_grafana_org_id;

    IF v_existing_organization_id IS NOT NULL
       AND v_existing_organization_id <> p_organization_id
    THEN
        RAISE EXCEPTION
            'Grafana org % is already mapped to EMS organization %.',
            p_grafana_org_id,
            v_existing_organization_id
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO metadata.grafana_organization_map
    (
        grafana_org_id,
        organization_id,
        is_active
    )
    VALUES
    (
        p_grafana_org_id,
        p_organization_id,
        TRUE
    )
    ON CONFLICT (grafana_org_id)
    DO UPDATE SET
        organization_id = EXCLUDED.organization_id,
        is_active = TRUE,
        updated_at = clock_timestamp();

    INSERT INTO admin.grafana_organization_provisioning
    (
        organization_id,
        provisioning_status,
        grafana_org_id,
        attempt_count,
        last_attempt_at,
        provisioned_at,
        last_error
    )
    VALUES
    (
        p_organization_id,
        'PROVISIONED',
        p_grafana_org_id,
        1,
        clock_timestamp(),
        clock_timestamp(),
        NULL
    )
    ON CONFLICT (organization_id)
    DO UPDATE SET
        provisioning_status = 'PROVISIONED',
        grafana_org_id = EXCLUDED.grafana_org_id,
        provisioned_at = clock_timestamp(),
        last_error = NULL,
        updated_at = clock_timestamp();

    SELECT admin.get_grafana_provisioning(
        p_organization_id
    )
    INTO v_result;

    RETURN v_result;
END;
$$;


ALTER TABLE admin.grafana_organization_provisioning
    OWNER TO ems_admin;

ALTER FUNCTION admin.get_grafana_provisioning(UUID)
    OWNER TO ems_admin;

ALTER FUNCTION admin.mark_grafana_provisioning_pending(UUID)
    OWNER TO ems_admin;

ALTER FUNCTION admin.mark_grafana_provisioning_failed(UUID, TEXT)
    OWNER TO ems_admin;

ALTER FUNCTION admin.mark_grafana_provisioning_complete(UUID, BIGINT)
    OWNER TO ems_admin;


REVOKE ALL
    ON TABLE admin.grafana_organization_provisioning
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.get_grafana_provisioning(UUID)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.mark_grafana_provisioning_pending(UUID)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.mark_grafana_provisioning_failed(UUID, TEXT)
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.mark_grafana_provisioning_complete(UUID, BIGINT)
    FROM PUBLIC;


GRANT EXECUTE
    ON FUNCTION admin.get_grafana_provisioning(UUID)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.mark_grafana_provisioning_pending(UUID)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.mark_grafana_provisioning_failed(UUID, TEXT)
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.mark_grafana_provisioning_complete(UUID, BIGINT)
    TO ems_app;
