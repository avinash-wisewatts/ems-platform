-- ============================================================================
-- Migration 198
-- Guard against silent partial reference-data seeding / restore
--
-- Root cause this closes (see docs/platform-manual/25-change-history.md,
-- 2026-08-25 staging-parity investigation): a raw pg_restore of a
-- production snapshot onto an already-differently-seeded staging database
-- silently produced an incomplete config.profile_field_mapping (8 of 58
-- raw fields missing entirely) and incomplete config.energy_register_
-- semantics (2 of 20 rows missing), because pg_restore continues past
-- per-row unique/foreign-key conflicts by default, and every existing
-- reference-data seed in this repository uses "ON CONFLICT DO NOTHING"
-- with no verification that the intended end state was actually reached.
-- No error was raised anywhere in that chain.
--
-- This migration does not change any tenant configuration data. It adds
-- two general-purpose, reusable assertion functions and immediately
-- exercises them against the one profile known to have been affected
-- (ENERGY_METER_ENISCOPE_V1). If the target database's reference data is
-- incomplete, this migration FAILS LOUDLY (transactional migrations roll
-- back on error) instead of silently deploying on top of a broken tenant
-- configuration.
--
-- These functions are intentionally reusable so that:
--   - a future migration/seed for a new device profile can call them at
--     its own end as a self-check (mirroring the pattern migration 174
--     already established for its own patches), and
--   - the application's onboarding/commissioning flow can call them
--     before marking a tenant "commissioned" (see Phase 9 of the
--     2026-08-25 hardening work).
-- ============================================================================


CREATE OR REPLACE FUNCTION config.assert_profile_field_mapping_complete(
    p_profile_code TEXT,
    p_required_raw_fields TEXT[]
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_profile_id UUID;
    v_missing TEXT[];
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = p_profile_code;

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION
            'assert_profile_field_mapping_complete: device profile % does not exist',
            p_profile_code;
    END IF;

    SELECT array_agg(rf ORDER BY rf)
    INTO v_missing
    FROM unnest(p_required_raw_fields) AS rf
    WHERE NOT EXISTS (
        SELECT 1
        FROM config.profile_field_mapping pfm
        WHERE pfm.profile_id = v_profile_id
          AND pfm.raw_field_name = rf
    );

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            'config.profile_field_mapping is incomplete for profile %: missing raw field(s) %. '
            'This is exactly the failure mode a partial reference-data restore/reseed produces '
            'silently -- fix the mapping before proceeding, do not weaken this check.',
            p_profile_code, v_missing;
    END IF;
END;
$function$;

COMMENT ON FUNCTION config.assert_profile_field_mapping_complete(TEXT, TEXT[]) IS
'Raises loudly if any of the given raw field names has no config.profile_field_mapping row for the named device profile. Pure verification -- never modifies data. Callable from future reference-data migrations and from onboarding/commissioning validation.';

ALTER FUNCTION config.assert_profile_field_mapping_complete(TEXT, TEXT[]) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION config.assert_profile_field_mapping_complete(TEXT, TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.assert_profile_field_mapping_complete(TEXT, TEXT[]) TO ems_admin, ems_app;


CREATE OR REPLACE FUNCTION config.assert_energy_register_semantics_complete(
    p_profile_code TEXT,
    p_required_logical_points TEXT[]
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_profile_id UUID;
    v_missing TEXT[];
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = p_profile_code;

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION
            'assert_energy_register_semantics_complete: device profile % does not exist',
            p_profile_code;
    END IF;

    SELECT array_agg(lp_name ORDER BY lp_name)
    INTO v_missing
    FROM unnest(p_required_logical_points) AS lp_name
    WHERE NOT EXISTS (
        SELECT 1
        FROM config.energy_register_semantics ers
        JOIN metadata.logical_points lp ON lp.id = ers.logical_point_id
        WHERE ers.profile_id = v_profile_id
          AND lp.name = lp_name
    );

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            'config.energy_register_semantics is incomplete for profile %: missing logical point(s) %. '
            'Do not weaken this check -- fix the register semantics instead.',
            p_profile_code, v_missing;
    END IF;
END;
$function$;

COMMENT ON FUNCTION config.assert_energy_register_semantics_complete(TEXT, TEXT[]) IS
'Raises loudly if any of the given canonical logical-point names has no config.energy_register_semantics row for the named device profile. Pure verification -- never modifies data.';

ALTER FUNCTION config.assert_energy_register_semantics_complete(TEXT, TEXT[]) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION config.assert_energy_register_semantics_complete(TEXT, TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.assert_energy_register_semantics_complete(TEXT, TEXT[]) TO ems_admin, ems_app;


-- ----------------------------------------------------------------------------
-- Exercise both guards immediately against ENERGY_METER_ENISCOPE_V1 -- the
-- profile actually found incomplete on staging. If this profile does not
-- exist on the target database at all, that is a different, pre-existing
-- condition this migration does not create an opinion about, so the checks
-- below are skipped rather than failing a database that legitimately never
-- had this profile provisioned.
-- ----------------------------------------------------------------------------

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM config.device_profiles
        WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'
    ) THEN
        PERFORM config.assert_profile_field_mapping_complete(
            'ENERGY_METER_ENISCOPE_V1',
            ARRAY[
                'A1','A2','A3',
                'AE','AE1','AE2','AE3',
                'C',
                'D','D1','D2','D3',
                'E','E1','E2','E3',
                'Ex','Ex1','Ex2','Ex3',
                'F',
                'I','I1','I2','I3','In',
                'P','P1','P2','P3',
                'PF','PF1','PF2','PF3',
                'Q','Q1','Q2','Q3',
                'RE','RE1','RE2','RE3',
                'REx','REx1','REx2','REx3',
                'S','S1','S2','S3',
                'U','U1','U2','U3',
                'V','V1','V2','V3'
            ]
        );

        PERFORM config.assert_energy_register_semantics_complete(
            'ENERGY_METER_ENISCOPE_V1',
            ARRAY[
                'APPARENT_ENERGY_L1','APPARENT_ENERGY_L2','APPARENT_ENERGY_L3','APPARENT_ENERGY_TOTAL',
                'ENERGY_EXPORT_L1','ENERGY_EXPORT_L2','ENERGY_EXPORT_L3','ENERGY_EXPORT_TOTAL',
                'ENERGY_IMPORT_L1','ENERGY_IMPORT_L2','ENERGY_IMPORT_L3','ENERGY_IMPORT_TOTAL',
                'ENERGY_REACTIVE_EXPORT_L1','ENERGY_REACTIVE_EXPORT_L2','ENERGY_REACTIVE_EXPORT_L3','ENERGY_REACTIVE_EXPORT_TOTAL',
                'REACTIVE_ENERGY_L1','REACTIVE_ENERGY_L2','REACTIVE_ENERGY_L3','REACTIVE_ENERGY_TOTAL'
            ]
        );
    END IF;
END;
$$;
