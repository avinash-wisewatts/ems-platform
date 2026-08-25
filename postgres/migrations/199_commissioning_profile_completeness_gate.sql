-- ============================================================================
-- Migration 199
-- Close the tenant commissioning semantic-validation gap
--
-- Architecture finding (2026-08-25 investigation): device commissioning does
-- NOT go through admin.transition_entity_lifecycle/admin.validate_lifecycle_
-- transition at all -- that generic dispatcher's DEVICE transition table has
-- no path into ACTIVE. The narrow, dedicated entry point is
-- admin.commission_device(actor, device_id), which already delegates
-- readiness to analytics.v_commissioning_readiness.
--
-- Second finding, made while writing this migration's own regression test
-- (Phase 5, Test B): config.profile_field_mapping.is_required cannot serve
-- as the "which raw fields are required" contract for a runtime commission-
-- ing gate, even though it already drives analytics.v_commissioning_
-- readiness's telemetry-proof check. The reason is structural, not a data
-- problem: logical_point_id on config.profile_field_mapping is NOT NULL,
-- so a row's existence on that table IS the mapping -- there is no way to
-- represent "field X is required but has no mapping row yet." A gate that
-- derives its required-field list by querying is_required = TRUE on that
-- same table is therefore circular: a field whose mapping row was never
-- created at all (the exact 2026-08-20 failure shape -- raw fields never
-- wired to any logical point) can never appear in a list derived that way,
-- so the gate would silently pass in precisely the scenario it exists to
-- catch. Proven directly: scripts/test/assert_commissioning_semantic_gate.sql
-- Test B, run against an earlier draft of this migration that took that
-- derivation shortcut, failed to raise.
--
-- Per the task's Phase 3 instruction -- do not hardcode a field list in the
-- lifecycle function; reuse an existing canonical source; only add a new
-- config.device_profile_required_fields table if nothing existing
-- qualifies -- this migration adds exactly that table. It is the smallest
-- structure that can express "required," independent of whether a mapping
-- currently exists, and it introduces no new seed/reseed mechanism: it is
-- populated once, here, for the one profile already known to need it.
--
-- This migration:
--   1. Creates config.device_profile_required_fields(profile_id,
--      raw_field_name) -- a durable declaration of a profile's raw-field
--      contract, independent of config.profile_field_mapping.
--   2. Seeds it with the 58 raw fields that constitute
--      ENERGY_METER_ENISCOPE_V1's real commissioning contract (the same
--      list migration 198 already validates for profile-mapping
--      completeness), and, as before, also sets
--      config.profile_field_mapping.is_required = TRUE on those same 58
--      rows -- this activates the pre-existing, previously-inert
--      telemetry-proof check inside analytics.v_commissioning_readiness
--      (a genuinely separate, complementary signal: "this device has
--      proven the mapped field end to end", not "the field is mapped at
--      all"). Verified beforehand (this session, live) that all 22
--      Meenaxy devices, on both staging and production, already have
--      validated telemetry for all 58 fields, so this does not
--      retroactively block anything already ACTIVE (the readiness view's
--      is_ready expression already short-circuits to TRUE for any device
--      whose lifecycle_status is already 'ACTIVE', regardless of this
--      flag).
--   3. Adds one explicit call to config.assert_profile_field_mapping_complete
--      inside admin.commission_device, using the device's own profile_id to
--      resolve profile_code and the required raw-field list from the new
--      config.device_profile_required_fields table -- no profile is
--      special-cased, so this applies identically to any future device
--      profile without further code changes, and it is a genuine no-op for
--      any profile with no rows in the new table, exactly preserving
--      existing behavior for ENVIRONMENT_SENSOR_AIRSENSE_V1 and any other
--      profile this migration does not seed.
--
-- Together these give two independent, complementary layers ahead of the
-- existing UPDATE ... SET lifecycle_status = 'ACTIVE':
--   - the (now-active) telemetry.device_point_state check: this specific
--     device has proven the field end to end;
--   - the new assert_profile_field_mapping_complete call, driven by the new
--     durable required-fields table: the profile itself is not missing a
--     mapping row at all -- catching the exact Aug-20 failure mode even
--     before any telemetry has arrived for a brand-new device, and even if
--     the mapping row was never created (not merely left unrequired).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. New durable "required raw fields" contract, independent of whether a
--    config.profile_field_mapping row currently exists for that field.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.device_profile_required_fields (
    profile_id      UUID NOT NULL REFERENCES config.device_profiles(id) ON DELETE CASCADE,
    raw_field_name  TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (profile_id, raw_field_name)
);

COMMENT ON TABLE config.device_profile_required_fields IS
'Durable declaration of which raw field names a device profile requires to be considered semantically complete for commissioning, independent of whether config.profile_field_mapping currently has a row for that field (a missing mapping row IS the failure this table lets the commissioning gate detect). Read by admin.commission_device via config.assert_profile_field_mapping_complete.';

ALTER TABLE config.device_profile_required_fields OWNER TO ems_admin;
REVOKE ALL ON config.device_profile_required_fields FROM PUBLIC;
GRANT SELECT ON config.device_profile_required_fields TO ems_admin, ems_app;
GRANT INSERT, UPDATE, DELETE ON config.device_profile_required_fields TO ems_admin;

-- ----------------------------------------------------------------------------
-- 2. Seed the Eniscope contract and activate the existing telemetry-proof
--    gate for the same 58 fields.
-- ----------------------------------------------------------------------------

INSERT INTO config.device_profile_required_fields (profile_id, raw_field_name)
SELECT dp.id, f.raw_field_name
FROM config.device_profiles dp
CROSS JOIN (
    VALUES
        ('A1'),('A2'),('A3'),
        ('AE'),('AE1'),('AE2'),('AE3'),
        ('C'),
        ('D'),('D1'),('D2'),('D3'),
        ('E'),('E1'),('E2'),('E3'),
        ('Ex'),('Ex1'),('Ex2'),('Ex3'),
        ('F'),
        ('I'),('I1'),('I2'),('I3'),('In'),
        ('P'),('P1'),('P2'),('P3'),
        ('PF'),('PF1'),('PF2'),('PF3'),
        ('Q'),('Q1'),('Q2'),('Q3'),
        ('RE'),('RE1'),('RE2'),('RE3'),
        ('REx'),('REx1'),('REx2'),('REx3'),
        ('S'),('S1'),('S2'),('S3'),
        ('U'),('U1'),('U2'),('U3'),
        ('V'),('V1'),('V2'),('V3')
) AS f(raw_field_name)
WHERE dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
ON CONFLICT (profile_id, raw_field_name) DO NOTHING;

UPDATE config.profile_field_mapping pfm
SET is_required = TRUE
FROM config.device_profiles dp
WHERE dp.id = pfm.profile_id
  AND dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
  AND pfm.raw_field_name IN (
        SELECT raw_field_name
        FROM config.device_profile_required_fields drf
        WHERE drf.profile_id = dp.id
      );

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM config.device_profiles
        WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'
    ) THEN
        -- Reuses migration 198's own guard as this migration's postcondition,
        -- sourcing the required-field list from the new durable table so it
        -- cannot drift from what was just seeded above.
        PERFORM config.assert_profile_field_mapping_complete(
            'ENERGY_METER_ENISCOPE_V1',
            (
                SELECT array_agg(drf.raw_field_name ORDER BY drf.raw_field_name)
                FROM config.device_profile_required_fields drf
                JOIN config.device_profiles dp ON dp.id = drf.profile_id
                WHERE dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
            )
        );
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 3. Wire the profile-completeness guard into admin.commission_device(),
--    ahead of the existing analytics.v_commissioning_readiness check and
--    the ACTIVE transition. Everything else in the function is unchanged.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.commission_device(p_actor_portal_user_id bigint, p_device_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata', 'analytics'
AS $function$
DECLARE
    v_actor_username TEXT;
    v_site_id UUID;
    v_old_lifecycle TEXT;
    v_readiness BOOLEAN;
    v_blockers TEXT[];
    v_warnings TEXT[];
    v_policy TEXT;
    v_profile_id UUID;
    v_profile_code TEXT;
    v_required_raw_fields TEXT[];
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT username
    INTO v_actor_username
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active = TRUE;

    IF NOT FOUND
       OR NOT admin.portal_user_has_permission(
           p_actor_portal_user_id,
           'device.manage'
       )
    THEN
        RAISE EXCEPTION 'Portal actor is not authorized to commission devices.'
            USING ERRCODE = '42501';
    END IF;

    SELECT g.site_id, d.lifecycle_status, d.operational_policy, d.profile_id
    INTO v_site_id, v_old_lifecycle, v_policy, v_profile_id
    FROM metadata.devices d
    JOIN metadata.gateways g ON g.id = d.gateway_id
    WHERE d.id = p_device_id
    FOR UPDATE OF d;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Device was not found.' USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        v_site_id
    ) THEN
        RAISE EXCEPTION 'Portal actor cannot access the selected device.'
            USING ERRCODE = '42501';
    END IF;

    IF v_old_lifecycle = 'ACTIVE' THEN
        RAISE EXCEPTION 'The device is already commissioned.'
            USING ERRCODE = '23514';
    END IF;

    IF v_old_lifecycle = 'DECOMMISSIONED' THEN
        RAISE EXCEPTION 'A decommissioned device cannot be commissioned.'
            USING ERRCODE = '23514';
    END IF;

    -- --------------------------------------------------------------------
    -- Semantic-configuration completeness gate (2026-08-25 hardening).
    --
    -- Independent of and ahead of the telemetry-proof readiness check
    -- below: this catches an incompletely mapped device PROFILE itself
    -- (the exact 2026-08-20 failure mode -- raw fields never wired to any
    -- logical point at all) even for a brand-new device that has not yet
    -- received any telemetry. The required-field list comes from the
    -- durable config.device_profile_required_fields table, NOT from
    -- config.profile_field_mapping.is_required -- deriving it from the
    -- mapping table itself would be circular, since a field whose mapping
    -- row was never created could never appear in such a derived list
    -- (logical_point_id is NOT NULL on that table, so a row's existence IS
    -- the mapping). Vacuously passes (no-op) for any profile with no rows
    -- in config.device_profile_required_fields, so existing, unseeded
    -- profiles (e.g. ENVIRONMENT_SENSOR_AIRSENSE_V1) are entirely
    -- unaffected.
    -- --------------------------------------------------------------------

    IF v_profile_id IS NOT NULL THEN
        SELECT dp.profile_code
        INTO v_profile_code
        FROM config.device_profiles dp
        WHERE dp.id = v_profile_id;

        SELECT array_agg(drf.raw_field_name ORDER BY drf.raw_field_name)
        INTO v_required_raw_fields
        FROM config.device_profile_required_fields drf
        WHERE drf.profile_id = v_profile_id;

        IF v_profile_code IS NOT NULL AND v_required_raw_fields IS NOT NULL THEN
            BEGIN
                PERFORM config.assert_profile_field_mapping_complete(
                    v_profile_code,
                    v_required_raw_fields
                );
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE EXCEPTION
                        'Device commissioning is blocked: device % profile % has an incomplete semantic configuration -- %',
                        p_device_id, v_profile_code, SQLERRM
                        USING ERRCODE = '23514';
            END;
        END IF;
    END IF;

    SELECT is_ready, blocking_reason_codes, warning_reason_codes
    INTO v_readiness, v_blockers, v_warnings
    FROM analytics.v_commissioning_readiness
    WHERE entity_type = 'DEVICE'
      AND entity_id = p_device_id;

    IF NOT FOUND OR NOT COALESCE(v_readiness, FALSE) THEN
        RAISE EXCEPTION 'Device commissioning is blocked: %',
            array_to_string(
                COALESCE(
                    v_blockers,
                    ARRAY['READINESS_UNAVAILABLE']::TEXT[]
                ),
                ', '
            )
            USING ERRCODE = '23514';
    END IF;

    PERFORM set_config(
        'ems.controlled_device_commissioning_id',
        p_device_id::text,
        TRUE
    );

    UPDATE metadata.devices
    SET lifecycle_status = 'ACTIVE',
        updated_at = now()
    WHERE id = p_device_id;

    PERFORM set_config(
        'ems.controlled_device_commissioning_id',
        '',
        TRUE
    );

    v_result := jsonb_build_object(
        'success', TRUE,
        'entity_type', 'DEVICE',
        'entity_id', p_device_id,
        'device_id', p_device_id,
        'lifecycle_status', 'ACTIVE',
        'commissioning_status', 'COMMISSIONED',
        'validation_warnings',
            to_jsonb(COALESCE(v_warnings, ARRAY[]::TEXT[])),
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit(
        id,
        requested_by,
        request_payload,
        result_payload
    )
    VALUES (
        v_audit_id,
        v_actor_username,
        jsonb_build_object(
            'operation', 'COMMISSION_DEVICE',
            'device_id', p_device_id,
            'previous_lifecycle_status', v_old_lifecycle,
            'operational_policy', v_policy,
            'readiness_source', 'analytics.v_commissioning_readiness'
        ),
        v_result
    );

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION admin.commission_device(bigint, uuid) IS
'Commissions one device (transitions it to ACTIVE) after verifying: actor authorization, current lifecycle state, semantic profile-mapping completeness (config.assert_profile_field_mapping_complete against the device''s own profile, using config.device_profile_required_fields as the required-field source), and telemetry-proven readiness (analytics.v_commissioning_readiness). Writes an admin.onboarding_audit row either way is not this function''s job -- callers rely on the raised exception for failure.';

ALTER FUNCTION admin.commission_device(bigint, uuid) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.commission_device(bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.commission_device(bigint, uuid) TO ems_app;
