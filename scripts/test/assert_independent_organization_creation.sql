\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
    v_result JSONB;
    v_organization_id UUID;
BEGIN
    v_result := admin.create_organization
    (
        'Story 2.1 Draft Tenant',
        'story_2_1_draft',
        'Asia/Kolkata',
        'DRAFT',
        'integration-test@example.com'
    );

    v_organization_id := (v_result ->> 'entity_id')::UUID;

    IF v_result ->> 'success' <> 'true'
       OR v_result ->> 'entity_type' <> 'ORGANIZATION'
       OR v_result ->> 'organization_code' <> 'STORY_2_1_DRAFT'
       OR v_result ->> 'lifecycle_status' <> 'DRAFT'
       OR v_result ->> 'timezone' <> 'Asia/Kolkata'
       OR NULLIF(v_result ->> 'audit_transaction_id', '') IS NULL
    THEN
        RAISE EXCEPTION 'Independent organization result contract is invalid: %', v_result;
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.organizations
        WHERE id = v_organization_id
          AND lifecycle_status = 'DRAFT'
          AND is_active = FALSE
          AND timezone = 'Asia/Kolkata'
    ) THEN
        RAISE EXCEPTION 'Draft organization was not persisted correctly.';
    END IF;

    IF EXISTS
    (
        SELECT 1 FROM metadata.sites WHERE organization_id = v_organization_id
    ) OR EXISTS
    (
        SELECT 1 FROM metadata.assets WHERE organization_id = v_organization_id
    ) OR EXISTS
    (
        SELECT 1 FROM metadata.gateways WHERE organization_id = v_organization_id
    ) OR EXISTS
    (
        SELECT 1 FROM metadata.devices WHERE organization_id = v_organization_id
    ) THEN
        RAISE EXCEPTION 'Independent organization creation produced downstream entities.';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM admin.onboarding_audit
        WHERE id = (v_result ->> 'audit_transaction_id')::UUID
          AND requested_by = 'integration-test@example.com'
          AND request_payload ->> 'operation' = 'CREATE_ORGANIZATION'
          AND result_payload ->> 'entity_id' = v_organization_id::TEXT
    ) THEN
        RAISE EXCEPTION 'Organization creation audit record is missing.';
    END IF;

    BEGIN
        PERFORM admin.create_organization
        (
            'Duplicate Draft Tenant',
            'STORY_2_1_DRAFT',
            'UTC',
            'DRAFT',
            'integration-test@example.com'
        );
        RAISE EXCEPTION 'Duplicate organization code was accepted.';
    EXCEPTION
        WHEN unique_violation THEN
            NULL;
    END;

    BEGIN
        PERFORM admin.create_organization
        (
            'Invalid Code Tenant',
            'invalid-code',
            'UTC',
            'DRAFT',
            'integration-test@example.com'
        );
        RAISE EXCEPTION 'Invalid organization code was accepted.';
    EXCEPTION
        WHEN invalid_parameter_value THEN
            NULL;
    END;
END;
$$;

ROLLBACK;

SELECT 'Independent organization creation assertions passed.' AS result;
