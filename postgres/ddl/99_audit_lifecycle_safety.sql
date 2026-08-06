-- Epic 12: generic audit events, shared lifecycle validation, and soft decommissioning.

CREATE TABLE IF NOT EXISTS admin.audit_events (
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL,
    organization_id UUID REFERENCES metadata.organizations(id),
    site_id UUID REFERENCES metadata.sites(id),
    actor_portal_user_id BIGINT REFERENCES admin.portal_users(portal_user_id),
    actor_role TEXT NOT NULL,
    action TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id UUID,
    previous_values JSONB NOT NULL DEFAULT '{}'::jsonb,
    new_values JSONB NOT NULL DEFAULT '{}'::jsonb,
    result TEXT NOT NULL,
    failure_reason TEXT,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT audit_events_action_not_blank CHECK (btrim(action) <> ''),
    CONSTRAINT audit_events_entity_type_not_blank CHECK (btrim(entity_type) <> ''),
    CONSTRAINT audit_events_actor_role_not_blank CHECK (btrim(actor_role) <> ''),
    CONSTRAINT audit_events_result_check CHECK (result IN ('SUCCEEDED','FAILED','REJECTED')),
    CONSTRAINT audit_events_previous_object_check CHECK (jsonb_typeof(previous_values) = 'object'),
    CONSTRAINT audit_events_new_object_check CHECK (jsonb_typeof(new_values) = 'object'),
    CONSTRAINT audit_events_failure_reason_check CHECK (
        (result = 'SUCCEEDED' AND failure_reason IS NULL)
        OR (result IN ('FAILED','REJECTED') AND nullif(btrim(failure_reason), '') IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_audit_events_org_time
    ON admin.audit_events(organization_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_site_time
    ON admin.audit_events(site_id, occurred_at DESC)
    WHERE site_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_events_entity_time
    ON admin.audit_events(entity_type, entity_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_transaction
    ON admin.audit_events(transaction_id);
CREATE INDEX IF NOT EXISTS idx_audit_events_actor_time
    ON admin.audit_events(actor_portal_user_id, occurred_at DESC);

COMMENT ON TABLE admin.audit_events IS
'Append-only tenant-scoped administration audit events. Historical onboarding audit tables remain intact for compatibility.';

CREATE OR REPLACE FUNCTION admin.redact_audit_json(p_value JSONB)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
SET search_path TO pg_catalog
AS $function$
SELECT CASE jsonb_typeof(p_value)
    WHEN 'object' THEN COALESCE((
        SELECT jsonb_object_agg(
            key,
            CASE
                WHEN lower(key) ~ '(password|passwd|secret|token|api[_-]?key|credential|private[_-]?key)'
                    THEN '"[REDACTED]"'::jsonb
                ELSE admin.redact_audit_json(value)
            END
        )
        FROM jsonb_each(p_value)
    ), '{}'::jsonb)
    WHEN 'array' THEN COALESCE((
        SELECT jsonb_agg(admin.redact_audit_json(value))
        FROM jsonb_array_elements(p_value)
    ), '[]'::jsonb)
    ELSE p_value
END;
$function$;

CREATE OR REPLACE FUNCTION admin.write_audit_event(
    p_transaction_id UUID,
    p_actor_portal_user_id BIGINT,
    p_action TEXT,
    p_entity_type TEXT,
    p_entity_id UUID,
    p_organization_id UUID,
    p_site_id UUID,
    p_previous_values JSONB DEFAULT '{}'::jsonb,
    p_new_values JSONB DEFAULT '{}'::jsonb,
    p_result TEXT DEFAULT 'SUCCEEDED',
    p_failure_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_event_id UUID := gen_random_uuid();
    v_role TEXT;
    v_result TEXT := upper(btrim(p_result));
BEGIN
    SELECT role_code INTO v_role
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Audit actor was not found.' USING ERRCODE='22023';
    END IF;
    IF nullif(btrim(p_action), '') IS NULL OR nullif(btrim(p_entity_type), '') IS NULL THEN
        RAISE EXCEPTION 'Audit action and entity type are required.' USING ERRCODE='22023';
    END IF;
    IF v_result NOT IN ('SUCCEEDED','FAILED','REJECTED') THEN
        RAISE EXCEPTION 'Audit result is invalid.' USING ERRCODE='22023';
    END IF;
    IF v_result <> 'SUCCEEDED' AND nullif(btrim(p_failure_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Failure reason is required for unsuccessful audit events.' USING ERRCODE='22023';
    END IF;

    INSERT INTO admin.audit_events(
        event_id, transaction_id, organization_id, site_id,
        actor_portal_user_id, actor_role, action, entity_type, entity_id,
        previous_values, new_values, result, failure_reason
    ) VALUES (
        v_event_id, COALESCE(p_transaction_id, gen_random_uuid()), p_organization_id, p_site_id,
        p_actor_portal_user_id, v_role, upper(btrim(p_action)), upper(btrim(p_entity_type)), p_entity_id,
        admin.redact_audit_json(COALESCE(p_previous_values, '{}'::jsonb)),
        admin.redact_audit_json(COALESCE(p_new_values, '{}'::jsonb)),
        v_result, nullif(btrim(p_failure_reason), '')
    );
    RETURN v_event_id;
END;
$function$;

CREATE OR REPLACE FUNCTION admin.list_accessible_audit_events(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID DEFAULT NULL,
    p_site_id UUID DEFAULT NULL,
    p_entity_type TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 200
)
RETURNS SETOF admin.audit_events
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
SELECT event_record.*
FROM admin.audit_events AS event_record
JOIN admin.portal_users AS actor
  ON actor.portal_user_id = p_actor_portal_user_id
 AND actor.is_active = TRUE
WHERE (p_organization_id IS NULL OR event_record.organization_id = p_organization_id)
  AND (p_site_id IS NULL OR event_record.site_id = p_site_id)
  AND (p_entity_type IS NULL OR event_record.entity_type = upper(btrim(p_entity_type)))
  AND (
      actor.role_code = 'PLATFORM_ADMIN'
      OR (
          event_record.site_id IS NOT NULL
          AND admin.portal_user_can_access_site(p_actor_portal_user_id, event_record.site_id)
      )
      OR (
          event_record.site_id IS NULL
          AND event_record.organization_id = actor.organization_id
      )
  )
ORDER BY event_record.occurred_at DESC
LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000);
$function$;

CREATE OR REPLACE FUNCTION admin.lifecycle_dependencies(
    p_entity_type TEXT,
    p_entity_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_type TEXT := upper(btrim(p_entity_type));
    v_dependencies JSONB := '[]'::jsonb;
BEGIN
    CASE v_type
    WHEN 'ORGANIZATION' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'dependency_type','SITE','entity_id',s.id,'name',s.name,'lifecycle_status',s.lifecycle_status
        ) ORDER BY s.name), '[]'::jsonb)
        INTO v_dependencies
        FROM metadata.sites s
        WHERE s.organization_id = p_entity_id
          AND s.lifecycle_status <> 'DECOMMISSIONED';
    WHEN 'SITE' THEN
        SELECT COALESCE(jsonb_agg(dependency ORDER BY dependency->>'dependency_type', dependency->>'name'), '[]'::jsonb)
        INTO v_dependencies
        FROM (
            SELECT jsonb_build_object('dependency_type','GATEWAY','entity_id',g.id,'name',g.name,'lifecycle_status',g.lifecycle_status) dependency
            FROM metadata.gateways g WHERE g.site_id=p_entity_id AND g.lifecycle_status <> 'DECOMMISSIONED'
            UNION ALL
            SELECT jsonb_build_object('dependency_type','ASSET','entity_id',a.id,'name',a.name,'lifecycle_status',a.lifecycle_status)
            FROM metadata.assets a WHERE a.site_id=p_entity_id AND a.lifecycle_status <> 'DECOMMISSIONED'
        ) d;
    WHEN 'ASSET' THEN
        SELECT COALESCE(jsonb_agg(dependency ORDER BY dependency->>'dependency_type', dependency->>'name'), '[]'::jsonb)
        INTO v_dependencies
        FROM (
            SELECT jsonb_build_object('dependency_type','CHILD_ASSET','entity_id',a.id,'name',a.name,'lifecycle_status',a.lifecycle_status) dependency
            FROM metadata.assets a WHERE a.parent_asset_id=p_entity_id AND a.lifecycle_status <> 'DECOMMISSIONED'
            UNION ALL
            SELECT jsonb_build_object('dependency_type','DEVICE_ASSIGNMENT','entity_id',ad.device_id,'name',d.name,'relationship_type',ad.relationship_type)
            FROM metadata.asset_devices ad JOIN metadata.devices d ON d.id=ad.device_id
            WHERE ad.asset_id=p_entity_id AND d.lifecycle_status <> 'DECOMMISSIONED'
        ) d;
    WHEN 'GATEWAY' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'dependency_type','DEVICE','entity_id',d.id,'name',d.name,'lifecycle_status',d.lifecycle_status
        ) ORDER BY d.name), '[]'::jsonb)
        INTO v_dependencies
        FROM metadata.devices d
        WHERE d.gateway_id=p_entity_id
          AND d.lifecycle_status NOT IN ('INACTIVE','DECOMMISSIONED');
    WHEN 'DEVICE' THEN
        SELECT COALESCE(jsonb_agg(dependency ORDER BY dependency->>'dependency_type'), '[]'::jsonb)
        INTO v_dependencies
        FROM (
            SELECT jsonb_build_object('dependency_type','ASSET_ASSIGNMENT','entity_id',ad.asset_id,'name',a.name,'relationship_type',ad.relationship_type) dependency
            FROM metadata.asset_devices ad JOIN metadata.assets a ON a.id=ad.asset_id
            WHERE ad.device_id=p_entity_id AND a.lifecycle_status <> 'DECOMMISSIONED'
            UNION ALL
            SELECT jsonb_build_object('dependency_type','SITE_ENERGY_ROLE','entity_id',r.site_id,'name',s.name,'relationship_type',r.meter_role)
            FROM config.site_energy_meter_roles r JOIN metadata.sites s ON s.id=r.site_id
            WHERE r.device_id=p_entity_id AND r.is_active=TRUE
        ) d;
    ELSE
        RAISE EXCEPTION 'Unsupported lifecycle entity type: %', p_entity_type USING ERRCODE='22023';
    END CASE;
    RETURN v_dependencies;
END;
$function$;

CREATE OR REPLACE FUNCTION admin.validate_lifecycle_transition(
    p_entity_type TEXT,
    p_entity_id UUID,
    p_current_status TEXT,
    p_new_status TEXT,
    p_allow_reactivation BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_type TEXT := upper(btrim(p_entity_type));
    v_current TEXT := upper(btrim(p_current_status));
    v_new TEXT := upper(btrim(p_new_status));
    v_allowed BOOLEAN := FALSE;
    v_dependencies JSONB := '[]'::jsonb;
BEGIN
    IF v_current = v_new THEN
        RETURN jsonb_build_object('allowed',false,'reason','NEW_STATUS_EQUALS_CURRENT','dependencies','[]'::jsonb);
    END IF;
    IF v_current = 'DECOMMISSIONED' THEN
        RETURN jsonb_build_object(
            'allowed',COALESCE(p_allow_reactivation,FALSE),
            'reason',CASE WHEN p_allow_reactivation THEN NULL ELSE 'REACTIVATION_REQUIRES_EXPLICIT_OVERRIDE' END,
            'dependencies','[]'::jsonb
        );
    END IF;

    v_allowed := CASE v_type
        WHEN 'ORGANIZATION' THEN (v_current,v_new) IN (('DRAFT','ACTIVE'),('DRAFT','DECOMMISSIONED'),('ACTIVE','SUSPENDED'),('ACTIVE','DECOMMISSIONED'),('SUSPENDED','ACTIVE'),('SUSPENDED','DECOMMISSIONED'))
        WHEN 'SITE' THEN (v_current,v_new) IN (('DRAFT','ACTIVE'),('DRAFT','DECOMMISSIONED'),('ACTIVE','INACTIVE'),('ACTIVE','DECOMMISSIONED'),('INACTIVE','ACTIVE'),('INACTIVE','DECOMMISSIONED'))
        WHEN 'ASSET' THEN (v_current,v_new) IN (('DRAFT','COMMISSIONING'),('DRAFT','INACTIVE'),('DRAFT','DECOMMISSIONED'),('COMMISSIONING','ACTIVE'),('COMMISSIONING','INACTIVE'),('COMMISSIONING','DECOMMISSIONED'),('ACTIVE','INACTIVE'),('ACTIVE','DECOMMISSIONED'),('INACTIVE','COMMISSIONING'),('INACTIVE','ACTIVE'),('INACTIVE','DECOMMISSIONED'))
        WHEN 'GATEWAY' THEN (v_current,v_new) IN (('REGISTERED','COMMISSIONING'),('REGISTERED','INACTIVE'),('REGISTERED','DECOMMISSIONED'),('COMMISSIONING','REGISTERED'),('COMMISSIONING','INACTIVE'),('COMMISSIONING','DECOMMISSIONED'),('INACTIVE','REGISTERED'),('INACTIVE','COMMISSIONING'),('INACTIVE','DECOMMISSIONED'))
        WHEN 'DEVICE' THEN (v_current,v_new) IN (('REGISTERED','INACTIVE'),('REGISTERED','DECOMMISSIONED'),('ACTIVE','INACTIVE'),('ACTIVE','DECOMMISSIONED'),('INACTIVE','REGISTERED'),('INACTIVE','DECOMMISSIONED'))
        ELSE FALSE
    END;

    IF NOT v_allowed THEN
        RETURN jsonb_build_object('allowed',false,'reason','UNSUPPORTED_TRANSITION','dependencies','[]'::jsonb);
    END IF;
    IF v_new='DECOMMISSIONED' THEN
        v_dependencies := admin.lifecycle_dependencies(v_type,p_entity_id);
        IF jsonb_array_length(v_dependencies)>0 THEN
            RETURN jsonb_build_object('allowed',false,'reason','ACTIVE_DEPENDENCIES','dependencies',v_dependencies);
        END IF;
    END IF;
    RETURN jsonb_build_object('allowed',true,'reason',NULL,'dependencies',v_dependencies);
END;
$function$;

CREATE OR REPLACE FUNCTION admin.transition_entity_lifecycle(
    p_actor_portal_user_id BIGINT,
    p_entity_type TEXT,
    p_entity_id UUID,
    p_new_status TEXT,
    p_change_reason TEXT,
    p_allow_reactivation BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_type TEXT := upper(btrim(p_entity_type));
    v_new TEXT := upper(btrim(p_new_status));
    v_current TEXT;
    v_org UUID;
    v_site UUID;
    v_role TEXT;
    v_permission TEXT;
    v_validation JSONB;
    v_transaction UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    IF nullif(btrim(p_change_reason),'') IS NULL THEN
        RAISE EXCEPTION 'Lifecycle change reason is required.' USING ERRCODE='22023';
    END IF;
    SELECT role_code INTO v_role FROM admin.portal_users
    WHERE portal_user_id=p_actor_portal_user_id AND is_active=TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active portal actor was not found.' USING ERRCODE='42501'; END IF;

    v_permission := CASE v_type
        WHEN 'ORGANIZATION' THEN 'organization.manage'
        WHEN 'SITE' THEN 'site.manage'
        WHEN 'ASSET' THEN 'asset.manage'
        WHEN 'GATEWAY' THEN 'gateway.manage'
        WHEN 'DEVICE' THEN 'device.manage'
        ELSE NULL END;
    IF v_permission IS NULL OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,v_permission) THEN
        RAISE EXCEPTION 'Portal actor is not authorized for this lifecycle operation.' USING ERRCODE='42501';
    END IF;

    CASE v_type
    WHEN 'ORGANIZATION' THEN
        SELECT lifecycle_status,id,NULL::uuid INTO v_current,v_org,v_site FROM metadata.organizations WHERE id=p_entity_id FOR UPDATE;
    WHEN 'SITE' THEN
        SELECT lifecycle_status,organization_id,id INTO v_current,v_org,v_site FROM metadata.sites WHERE id=p_entity_id FOR UPDATE;
    WHEN 'ASSET' THEN
        SELECT lifecycle_status,organization_id,site_id INTO v_current,v_org,v_site FROM metadata.assets WHERE id=p_entity_id FOR UPDATE;
    WHEN 'GATEWAY' THEN
        SELECT lifecycle_status,organization_id,site_id INTO v_current,v_org,v_site FROM metadata.gateways WHERE id=p_entity_id FOR UPDATE;
    WHEN 'DEVICE' THEN
        SELECT d.lifecycle_status,d.organization_id,g.site_id INTO v_current,v_org,v_site FROM metadata.devices d LEFT JOIN metadata.gateways g ON g.id=d.gateway_id WHERE d.id=p_entity_id FOR UPDATE OF d;
    ELSE
        RAISE EXCEPTION 'Unsupported lifecycle entity type: %',p_entity_type USING ERRCODE='22023';
    END CASE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Lifecycle entity was not found.' USING ERRCODE='22023'; END IF;

    IF v_role <> 'PLATFORM_ADMIN' THEN
        IF v_site IS NOT NULL AND NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_site) THEN
            RAISE EXCEPTION 'Portal actor cannot access the entity site.' USING ERRCODE='42501';
        ELSIF v_site IS NULL AND NOT EXISTS (
            SELECT 1 FROM admin.portal_users u WHERE u.portal_user_id=p_actor_portal_user_id AND u.organization_id=v_org
        ) THEN
            RAISE EXCEPTION 'Portal actor cannot access the entity organization.' USING ERRCODE='42501';
        END IF;
    END IF;
    IF p_allow_reactivation AND v_role <> 'PLATFORM_ADMIN' THEN
        RAISE EXCEPTION 'Only a platform administrator may explicitly reactivate a decommissioned entity.' USING ERRCODE='42501';
    END IF;

    v_validation := admin.validate_lifecycle_transition(v_type,p_entity_id,v_current,v_new,p_allow_reactivation);
    IF NOT (v_validation->>'allowed')::boolean THEN
        PERFORM admin.write_audit_event(
            v_transaction,
            p_actor_portal_user_id,
            'LIFECYCLE_TRANSITION',
            v_type,
            p_entity_id,
            v_org,
            v_site,
            jsonb_build_object('lifecycle_status', v_current),
            jsonb_build_object(
                'lifecycle_status', v_new,
                'change_reason', btrim(p_change_reason)
            ),
            'REJECTED',
            v_validation->>'reason'
        );

        -- Do not raise here: an exception would roll back the audit event.
        RETURN jsonb_build_object(
            'success', false,
            'entity_type', v_type,
            'entity_id', p_entity_id,
            'organization_id', v_org,
            'site_id', v_site,
            'previous_lifecycle_status', v_current,
            'requested_lifecycle_status', v_new,
            'failure_reason', v_validation->>'reason',
            'dependencies', v_validation->'dependencies',
            'audit_transaction_id', v_transaction
        );
    END IF;

    CASE v_type
    WHEN 'ORGANIZATION' THEN UPDATE metadata.organizations SET lifecycle_status=v_new,is_active=(v_new<>'DECOMMISSIONED'),updated_at=now() WHERE id=p_entity_id;
    WHEN 'SITE' THEN UPDATE metadata.sites SET lifecycle_status=v_new,is_active=(v_new NOT IN ('INACTIVE','DECOMMISSIONED')),updated_at=now() WHERE id=p_entity_id;
    WHEN 'ASSET' THEN UPDATE metadata.assets SET lifecycle_status=v_new,status=lower(v_new),updated_at=now() WHERE id=p_entity_id;
    WHEN 'GATEWAY' THEN UPDATE metadata.gateways SET lifecycle_status=v_new WHERE id=p_entity_id;
    WHEN 'DEVICE' THEN UPDATE metadata.devices SET lifecycle_status=v_new,updated_at=now() WHERE id=p_entity_id;
    END CASE;

    PERFORM admin.write_audit_event(v_transaction,p_actor_portal_user_id,'LIFECYCLE_TRANSITION',v_type,p_entity_id,v_org,v_site,
        jsonb_build_object('lifecycle_status',v_current),
        jsonb_build_object('lifecycle_status',v_new,'change_reason',btrim(p_change_reason)),'SUCCEEDED',NULL);
    v_result := jsonb_build_object('success',true,'entity_type',v_type,'entity_id',p_entity_id,
        'organization_id',v_org,'site_id',v_site,'previous_lifecycle_status',v_current,
        'lifecycle_status',v_new,'dependencies',v_validation->'dependencies','audit_transaction_id',v_transaction);
    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION metadata.reject_decommissioned_asset_device_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, metadata
AS $function$
BEGIN
    IF EXISTS (SELECT 1 FROM metadata.assets a WHERE a.id=NEW.asset_id AND a.lifecycle_status='DECOMMISSIONED') THEN
        RAISE EXCEPTION 'New assignments to a decommissioned asset are not permitted.' USING ERRCODE='23514';
    END IF;
    IF EXISTS (SELECT 1 FROM metadata.devices d WHERE d.id=NEW.device_id AND d.lifecycle_status='DECOMMISSIONED') THEN
        RAISE EXCEPTION 'New assignments to a decommissioned device are not permitted.' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_reject_decommissioned_asset_device_assignment ON metadata.asset_devices;
CREATE TRIGGER trg_reject_decommissioned_asset_device_assignment
BEFORE INSERT OR UPDATE OF asset_id,device_id ON metadata.asset_devices
FOR EACH ROW EXECUTE FUNCTION metadata.reject_decommissioned_asset_device_assignment();

CREATE OR REPLACE FUNCTION metadata.reject_decommissioned_site_energy_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, metadata
AS $function$
BEGIN
    IF EXISTS (SELECT 1 FROM metadata.sites s WHERE s.id=NEW.site_id AND s.lifecycle_status='DECOMMISSIONED') THEN
        RAISE EXCEPTION 'New energy roles on a decommissioned site are not permitted.' USING ERRCODE='23514';
    END IF;
    IF EXISTS (SELECT 1 FROM metadata.devices d WHERE d.id=NEW.device_id AND d.lifecycle_status='DECOMMISSIONED') THEN
        RAISE EXCEPTION 'New energy roles for a decommissioned device are not permitted.' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_reject_decommissioned_site_energy_role ON config.site_energy_meter_roles;
CREATE TRIGGER trg_reject_decommissioned_site_energy_role
BEFORE INSERT OR UPDATE OF site_id,device_id ON config.site_energy_meter_roles
FOR EACH ROW EXECUTE FUNCTION metadata.reject_decommissioned_site_energy_role();

ALTER TABLE admin.audit_events OWNER TO ems_admin;
ALTER FUNCTION admin.redact_audit_json(JSONB) OWNER TO ems_admin;
ALTER FUNCTION admin.write_audit_event(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,JSONB,JSONB,TEXT,TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_audit_events(BIGINT,UUID,UUID,TEXT,INTEGER) OWNER TO ems_admin;
ALTER FUNCTION admin.lifecycle_dependencies(TEXT,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.validate_lifecycle_transition(TEXT,UUID,TEXT,TEXT,BOOLEAN) OWNER TO ems_admin;
ALTER FUNCTION admin.transition_entity_lifecycle(BIGINT,TEXT,UUID,TEXT,TEXT,BOOLEAN) OWNER TO ems_admin;
ALTER FUNCTION metadata.reject_decommissioned_asset_device_assignment() OWNER TO ems_admin;
ALTER FUNCTION metadata.reject_decommissioned_site_energy_role() OWNER TO ems_admin;

REVOKE ALL ON admin.audit_events FROM PUBLIC, ems_app;
REVOKE ALL ON FUNCTION admin.redact_audit_json(JSONB) FROM PUBLIC, ems_app;
REVOKE ALL ON FUNCTION admin.write_audit_event(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,JSONB,JSONB,TEXT,TEXT) FROM PUBLIC, ems_app;
REVOKE ALL ON FUNCTION admin.list_accessible_audit_events(BIGINT,UUID,UUID,TEXT,INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.lifecycle_dependencies(TEXT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.validate_lifecycle_transition(TEXT,UUID,TEXT,TEXT,BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.transition_entity_lifecycle(BIGINT,TEXT,UUID,TEXT,TEXT,BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION metadata.reject_decommissioned_asset_device_assignment() FROM PUBLIC;
REVOKE ALL ON FUNCTION metadata.reject_decommissioned_site_energy_role() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.list_accessible_audit_events(BIGINT,UUID,UUID,TEXT,INTEGER) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.lifecycle_dependencies(TEXT,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.validate_lifecycle_transition(TEXT,UUID,TEXT,TEXT,BOOLEAN) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.transition_entity_lifecycle(BIGINT,TEXT,UUID,TEXT,TEXT,BOOLEAN) TO ems_app;
