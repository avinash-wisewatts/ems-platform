-- Epic 10 Story 10.3: controlled gateway commissioning.

ALTER TABLE metadata.gateways
    DROP CONSTRAINT IF EXISTS gateways_lifecycle_status_chk;
ALTER TABLE metadata.gateways
    ADD CONSTRAINT gateways_lifecycle_status_chk
    CHECK (lifecycle_status IN ('REGISTERED','COMMISSIONING','ACTIVE','INACTIVE','DECOMMISSIONED'));

-- Stories 10.1-10.2: declarative commissioning readiness and asset commissioning.

CREATE OR REPLACE VIEW analytics.v_commissioning_readiness
WITH (security_barrier = TRUE)
AS
WITH asset_readiness AS (
    SELECT
        'ASSET'::text AS entity_type,
        a.id AS entity_id,
        a.organization_id,
        a.site_id,
        a.name AS entity_name,
        a.lifecycle_status,
        CASE
            WHEN a.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN a.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN a.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN c.coverage_status IN ('MISSING_DIRECT_METER', 'UNKNOWN_POLICY') THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            a.lifecycle_status <> 'DECOMMISSIONED'
            AND (
                a.lifecycle_status = 'ACTIVE'
                OR a.metering_requirement IN ('NOT_REQUIRED', 'DESCENDANT_COVERAGE_ALLOWED')
                OR (
                    a.metering_requirement = 'DIRECT_METER_REQUIRED'
                    AND c.coverage_status = 'CONFIGURED'
                )
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN a.lifecycle_status = 'DECOMMISSIONED' THEN 'ASSET_DECOMMISSIONED' END,
            CASE WHEN a.metering_requirement IS NULL THEN 'METERING_POLICY_MISSING' END,
            CASE
                WHEN a.metering_requirement = 'DIRECT_METER_REQUIRED'
                 AND c.coverage_status IS DISTINCT FROM 'CONFIGURED'
                THEN 'QUALIFYING_PRIMARY_METER_REQUIRED'
            END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY_REMOVE(ARRAY[
            CASE
                WHEN a.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
                 AND c.coverage_status IN ('NO_REQUIRED_DESCENDANTS', 'PARTIALLY_CONFIGURED', 'MISSING_DESCENDANT_COVERAGE')
                THEN c.coverage_status
            END
        ], NULL)::text[] AS warning_reason_codes
    FROM metadata.assets a
    LEFT JOIN analytics.v_asset_meter_coverage_configuration c
      ON c.asset_id = a.id
),
gateway_last_seen AS (
    SELECT
        ds.gateway_id,
        max(coalesce(ds.last_successful_communication, ds.source_timestamp, ds.received_at)) AS last_seen_at
    FROM telemetry.device_status ds
    WHERE ds.gateway_id IS NOT NULL
    GROUP BY ds.gateway_id
),
gateway_readiness AS (
    SELECT
        'GATEWAY'::text AS entity_type,
        g.id AS entity_id,
        g.organization_id,
        g.site_id,
        g.name AS entity_name,
        g.lifecycle_status,
        CASE
            WHEN g.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN g.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN g.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN nullif(btrim(g.external_id), '') IS NULL OR g.gateway_model_id IS NULL THEN 'BLOCKED'
            WHEN gls.last_seen_at IS NULL THEN 'BLOCKED'
            WHEN gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            g.lifecycle_status = 'ACTIVE'
            OR (
                g.lifecycle_status <> 'DECOMMISSIONED'
                AND nullif(btrim(g.external_id), '') IS NOT NULL
                AND g.gateway_model_id IS NOT NULL
                AND gls.last_seen_at >= now() - make_interval(secs => gcp.online_threshold_seconds)
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN g.lifecycle_status = 'DECOMMISSIONED' THEN 'GATEWAY_DECOMMISSIONED' END,
            CASE WHEN nullif(btrim(g.external_id), '') IS NULL THEN 'GATEWAY_IDENTITY_MISSING' END,
            CASE WHEN g.gateway_model_id IS NULL THEN 'GATEWAY_MODEL_MISSING' END,
            CASE WHEN g.lifecycle_status <> 'ACTIVE' AND gls.last_seen_at IS NULL THEN 'GATEWAY_NEVER_SEEN' END,
            CASE WHEN g.lifecycle_status <> 'ACTIVE' AND gls.last_seen_at IS NOT NULL AND gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'GATEWAY_CONNECTIVITY_OFFLINE' END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN g.lifecycle_status = 'ACTIVE' AND gls.last_seen_at IS NULL THEN 'GATEWAY_CURRENTLY_NEVER_SEEN' END,
            CASE WHEN g.lifecycle_status = 'ACTIVE' AND gls.last_seen_at IS NOT NULL AND gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'GATEWAY_CURRENTLY_OFFLINE' END
        ], NULL)::text[] AS warning_reason_codes
    FROM metadata.gateways g
    CROSS JOIN config.gateway_connectivity_policy gcp
    LEFT JOIN gateway_last_seen gls ON gls.gateway_id = g.id
),
device_readiness AS (
    SELECT
        'DEVICE'::text AS entity_type,
        d.id AS entity_id,
        d.organization_id,
        g.site_id,
        d.name AS entity_name,
        d.lifecycle_status,
        CASE
            WHEN d.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN d.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN d.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN d.gateway_id IS NULL OR d.device_model_id IS NULL OR d.profile_id IS NULL THEN 'BLOCKED'
            WHEN NOT EXISTS (
                SELECT 1
                FROM config.device_profile_categories dpc
                JOIN metadata.device_models dm ON dm.id = d.device_model_id
                WHERE dpc.profile_id = d.profile_id
                  AND dpc.device_category_id = dm.device_category_id
            ) THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            d.lifecycle_status <> 'DECOMMISSIONED'
            AND d.gateway_id IS NOT NULL
            AND d.device_model_id IS NOT NULL
            AND d.profile_id IS NOT NULL
            AND EXISTS (
                SELECT 1
                FROM config.device_profile_categories dpc
                JOIN metadata.device_models dm ON dm.id = d.device_model_id
                WHERE dpc.profile_id = d.profile_id
                  AND dpc.device_category_id = dm.device_category_id
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN d.lifecycle_status = 'DECOMMISSIONED' THEN 'DEVICE_DECOMMISSIONED' END,
            CASE WHEN d.gateway_id IS NULL THEN 'GATEWAY_REQUIRED' END,
            CASE WHEN d.device_model_id IS NULL THEN 'DEVICE_MODEL_REQUIRED' END,
            CASE WHEN d.profile_id IS NULL THEN 'DEVICE_PROFILE_REQUIRED' END,
            CASE
                WHEN d.device_model_id IS NOT NULL
                 AND d.profile_id IS NOT NULL
                 AND NOT EXISTS (
                    SELECT 1
                    FROM config.device_profile_categories dpc
                    JOIN metadata.device_models dm ON dm.id = d.device_model_id
                    WHERE dpc.profile_id = d.profile_id
                      AND dpc.device_category_id = dm.device_category_id
                 )
                THEN 'PROFILE_CATEGORY_INCOMPATIBLE'
            END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY[]::text[] AS warning_reason_codes
    FROM metadata.devices d
    LEFT JOIN metadata.gateways g ON g.id = d.gateway_id
)
SELECT * FROM asset_readiness
UNION ALL
SELECT * FROM gateway_readiness
UNION ALL
SELECT * FROM device_readiness;


COMMENT ON VIEW analytics.v_commissioning_readiness IS
'Declarative tenant-scoped readiness for assets, gateways, and devices. Gateway commissioning requires valid identity/model and currently online connectivity, but never requires devices.';

CREATE OR REPLACE FUNCTION admin.commission_gateway(
    p_actor_portal_user_id BIGINT,
    p_gateway_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
DECLARE
    v_actor_username TEXT;
    v_site_id UUID;
    v_old_lifecycle TEXT;
    v_readiness BOOLEAN;
    v_blockers TEXT[];
    v_warnings TEXT[];
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT username INTO v_actor_username
    FROM admin.portal_users
    WHERE portal_user_id=p_actor_portal_user_id AND is_active=TRUE;
    IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,'gateway.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to commission gateways.' USING ERRCODE='42501';
    END IF;

    SELECT site_id,lifecycle_status INTO v_site_id,v_old_lifecycle
    FROM metadata.gateways WHERE id=p_gateway_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Gateway was not found.' USING ERRCODE='22023'; END IF;
    IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_site_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access the selected gateway.' USING ERRCODE='42501';
    END IF;
    IF v_old_lifecycle='DECOMMISSIONED' THEN
        RAISE EXCEPTION 'A decommissioned gateway cannot be commissioned.' USING ERRCODE='23514';
    END IF;

    SELECT is_ready,blocking_reason_codes,warning_reason_codes
    INTO v_readiness,v_blockers,v_warnings
    FROM analytics.v_commissioning_readiness
    WHERE entity_type='GATEWAY' AND entity_id=p_gateway_id;
    IF NOT FOUND OR NOT coalesce(v_readiness,FALSE) THEN
        RAISE EXCEPTION 'Gateway commissioning is blocked: %',
            array_to_string(coalesce(v_blockers,ARRAY['READINESS_UNAVAILABLE']::text[]),', ')
            USING ERRCODE='23514';
    END IF;

    UPDATE metadata.gateways SET lifecycle_status='ACTIVE' WHERE id=p_gateway_id;

    v_result:=jsonb_build_object(
        'success',TRUE,'entity_type','GATEWAY','entity_id',p_gateway_id,
        'gateway_id',p_gateway_id,'lifecycle_status','ACTIVE',
        'commissioning_status','COMMISSIONED',
        'validation_warnings',to_jsonb(coalesce(v_warnings,ARRAY[]::text[])),
        'blocking_conditions','[]'::jsonb,'audit_transaction_id',v_audit_id
    );
    INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload)
    VALUES(v_audit_id,v_actor_username,jsonb_build_object(
        'operation','COMMISSION_GATEWAY','gateway_id',p_gateway_id,
        'previous_lifecycle_status',v_old_lifecycle,
        'readiness_source','analytics.v_commissioning_readiness',
        'devices_required',FALSE
    ),v_result);
    RETURN v_result;
END;
$function$;

ALTER VIEW analytics.v_commissioning_readiness OWNER TO ems_admin;
ALTER FUNCTION admin.commission_gateway(BIGINT,UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.commission_gateway(BIGINT,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.commission_gateway(BIGINT,UUID) TO ems_app;
