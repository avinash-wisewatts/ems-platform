-- Story 2.4: idempotent, audited Grafana tenant reconciliation.

CREATE OR REPLACE FUNCTION admin.get_grafana_reconciliation_context(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_role TEXT;
    v_result JSONB;
BEGIN
    SELECT role_code INTO v_role
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active;

    IF v_role IS DISTINCT FROM 'PLATFORM_ADMIN' THEN
        RAISE EXCEPTION 'Only a platform administrator may reconcile Grafana tenants.'
            USING ERRCODE = '42501';
    END IF;

    SELECT jsonb_build_object(
        'organization_id', o.id,
        'organization_code', o.code,
        'organization_name', o.name,
        'lifecycle_status', o.lifecycle_status,
        'mapped_grafana_org_id', gom.grafana_org_id,
        'provisioning_grafana_org_id', gp.grafana_org_id,
        'provisioning_status', coalesce(gp.provisioning_status, 'NOT_STARTED'),
        'database_mapping_mismatch', (
            gom.grafana_org_id IS NOT NULL
            AND gp.grafana_org_id IS DISTINCT FROM gom.grafana_org_id
        )
    )
    INTO v_result
    FROM metadata.organizations o
    LEFT JOIN metadata.grafana_organization_map gom
      ON gom.organization_id = o.id AND gom.is_active
    LEFT JOIN admin.grafana_organization_provisioning gp
      ON gp.organization_id = o.id
    WHERE o.id = p_organization_id;

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'EMS organization % does not exist.', p_organization_id
            USING ERRCODE = '23503';
    END IF;

    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION admin.apply_grafana_reconciliation_mapping(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID,
    p_grafana_org_id BIGINT,
    p_repair_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_role TEXT;
    v_existing_grafana_org_id BIGINT;
    v_owner_organization_id UUID;
    v_org_name TEXT;
    v_transaction_id UUID := gen_random_uuid();
BEGIN
    IF p_grafana_org_id IS NULL OR p_grafana_org_id <= 0 THEN
        RAISE EXCEPTION 'Grafana organization ID must be a positive integer.'
            USING ERRCODE = '22023';
    END IF;

    IF nullif(btrim(p_repair_reason), '') IS NULL THEN
        RAISE EXCEPTION 'A reconciliation repair reason is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT role_code INTO v_role
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active;

    IF v_role IS DISTINCT FROM 'PLATFORM_ADMIN' THEN
        RAISE EXCEPTION 'Only a platform administrator may reconcile Grafana tenants.'
            USING ERRCODE = '42501';
    END IF;

    SELECT name INTO v_org_name
    FROM metadata.organizations
    WHERE id = p_organization_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMS organization % does not exist.', p_organization_id
            USING ERRCODE = '23503';
    END IF;

    SELECT grafana_org_id INTO v_existing_grafana_org_id
    FROM metadata.grafana_organization_map
    WHERE organization_id = p_organization_id
      AND is_active;

    IF v_existing_grafana_org_id IS NOT NULL
       AND v_existing_grafana_org_id <> p_grafana_org_id THEN
        RAISE EXCEPTION
            'Automatic Grafana tenant reassignment is prohibited: EMS organization % is already mapped to Grafana org %.',
            p_organization_id, v_existing_grafana_org_id
            USING ERRCODE = '23505';
    END IF;

    SELECT organization_id INTO v_owner_organization_id
    FROM metadata.grafana_organization_map
    WHERE grafana_org_id = p_grafana_org_id
      AND is_active;

    IF v_owner_organization_id IS NOT NULL
       AND v_owner_organization_id <> p_organization_id THEN
        RAISE EXCEPTION
            'Automatic cross-tenant reassignment is prohibited: Grafana org % belongs to EMS organization %.',
            p_grafana_org_id, v_owner_organization_id
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO metadata.grafana_organization_map(
        grafana_org_id, organization_id, is_active
    ) VALUES (
        p_grafana_org_id, p_organization_id, TRUE
    )
    ON CONFLICT (grafana_org_id) DO UPDATE SET
        is_active = TRUE,
        updated_at = clock_timestamp()
    WHERE metadata.grafana_organization_map.organization_id = EXCLUDED.organization_id;

    INSERT INTO admin.grafana_organization_provisioning(
        organization_id, provisioning_status, grafana_org_id,
        attempt_count, last_attempt_at, provisioned_at, last_error
    ) VALUES (
        p_organization_id, 'PROVISIONED', p_grafana_org_id,
        1, clock_timestamp(), clock_timestamp(), NULL
    )
    ON CONFLICT (organization_id) DO UPDATE SET
        provisioning_status = 'PROVISIONED',
        grafana_org_id = EXCLUDED.grafana_org_id,
        provisioned_at = clock_timestamp(),
        last_error = NULL,
        updated_at = clock_timestamp();

    PERFORM admin.write_audit_event(
        v_transaction_id,
        p_actor_portal_user_id,
        'RECONCILE_GRAFANA_TENANT',
        'ORGANIZATION',
        p_organization_id,
        p_organization_id,
        NULL,
        jsonb_build_object('grafana_org_id', v_existing_grafana_org_id),
        jsonb_build_object(
            'grafana_org_id', p_grafana_org_id,
            'organization_name', v_org_name,
            'repair_reason', btrim(p_repair_reason)
        ),
        'SUCCEEDED',
        NULL
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'organization_id', p_organization_id,
        'organization_name', v_org_name,
        'grafana_org_id', p_grafana_org_id,
        'reconciliation_status', 'REPAIRED',
        'audit_transaction_id', v_transaction_id
    );
END;
$function$;

ALTER FUNCTION admin.get_grafana_reconciliation_context(BIGINT, UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.apply_grafana_reconciliation_mapping(BIGINT, UUID, BIGINT, TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_grafana_reconciliation_context(BIGINT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.apply_grafana_reconciliation_mapping(BIGINT, UUID, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_grafana_reconciliation_context(BIGINT, UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.apply_grafana_reconciliation_mapping(BIGINT, UUID, BIGINT, TEXT) TO ems_app;
