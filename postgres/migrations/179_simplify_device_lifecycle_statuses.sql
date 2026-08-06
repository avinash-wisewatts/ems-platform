-- Simplify the device lifecycle model.
-- Commissioning readiness/status and asset assignment are separate concerns;
-- they must not be encoded as device lifecycle states.

-- Preserve every device while collapsing obsolete pre-operational states into
-- the single canonical pre-commissioning state.
UPDATE metadata.devices
SET lifecycle_status = 'REGISTERED',
    updated_at = now()
WHERE lifecycle_status IN ('DISCOVERED', 'UNASSIGNED', 'COMMISSIONING');

ALTER TABLE metadata.devices
    DROP CONSTRAINT IF EXISTS devices_lifecycle_status_chk;

ALTER TABLE metadata.devices
    ADD CONSTRAINT devices_lifecycle_status_chk
    CHECK (lifecycle_status IN (
        'REGISTERED', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED'
    ));

-- Fail clearly at the database boundary for every write path, including older
-- service functions and direct SQL. ACTIVE remains governed separately by the
-- controlled commissioning trigger.
CREATE OR REPLACE FUNCTION metadata.reject_obsolete_device_lifecycle_status()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.lifecycle_status NOT IN (
        'REGISTERED', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED'
    ) THEN
        RAISE EXCEPTION
            'Select Registered, Inactive, or Decommissioned. Use Commission device to activate a device.'
            USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_reject_obsolete_device_lifecycle_status
    ON metadata.devices;

CREATE TRIGGER trg_reject_obsolete_device_lifecycle_status
BEFORE INSERT OR UPDATE OF lifecycle_status
ON metadata.devices
FOR EACH ROW
EXECUTE FUNCTION metadata.reject_obsolete_device_lifecycle_status();

ALTER FUNCTION metadata.reject_obsolete_device_lifecycle_status()
    OWNER TO ems_admin;
REVOKE ALL ON FUNCTION metadata.reject_obsolete_device_lifecycle_status()
    FROM PUBLIC;

-- Keep the canonical status catalog aligned with the enforced model.
DO $block$
BEGIN
    IF to_regclass('config.status_definitions') IS NOT NULL THEN
        DELETE FROM config.status_definitions
        WHERE status_domain = 'DEVICE_LIFECYCLE';

        INSERT INTO config.status_definitions
            (status_domain, code, label, description, sort_order)
        VALUES
            ('DEVICE_LIFECYCLE', 'REGISTERED', 'Registered',
             'Device identity and core metadata are saved, but commissioning is not complete.', 10),
            ('DEVICE_LIFECYCLE', 'ACTIVE', 'Active',
             'Device has been commissioned and is approved for operational use.', 20),
            ('DEVICE_LIFECYCLE', 'INACTIVE', 'Inactive',
             'Device is temporarily removed from operational use while history is retained.', 30),
            ('DEVICE_LIFECYCLE', 'DECOMMISSIONED', 'Decommissioned',
             'Device has been permanently retired while history is retained.', 40);
    END IF;
END;
$block$;

-- Align the shared lifecycle transition validator when the full administration
-- subsystem exists. ACTIVE is still excluded here because commissioning owns
-- that transition.
DO $block$
BEGIN
    IF to_regprocedure(
        'admin.validate_lifecycle_transition(text,uuid,text,text,boolean)'
    ) IS NOT NULL THEN
        EXECUTE $sql$
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
                WHEN 'DEVICE' THEN (v_current,v_new) IN (
                    ('REGISTERED','INACTIVE'),
                    ('REGISTERED','DECOMMISSIONED'),
                    ('ACTIVE','INACTIVE'),
                    ('ACTIVE','DECOMMISSIONED'),
                    ('INACTIVE','REGISTERED'),
                    ('INACTIVE','DECOMMISSIONED')
                )
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
        $sql$;

        ALTER FUNCTION admin.validate_lifecycle_transition(
            TEXT, UUID, TEXT, TEXT, BOOLEAN
        ) OWNER TO ems_admin;
        REVOKE ALL ON FUNCTION admin.validate_lifecycle_transition(
            TEXT, UUID, TEXT, TEXT, BOOLEAN
        ) FROM PUBLIC;
        IF to_regrole('ems_app') IS NOT NULL THEN
            GRANT EXECUTE ON FUNCTION admin.validate_lifecycle_transition(
                TEXT, UUID, TEXT, TEXT, BOOLEAN
            ) TO ems_app;
        END IF;
    END IF;
END;
$block$;
