-- ============================================================================
-- File:
--   scripts/test/assert_reference_data_completeness_guard.sql
--
-- Purpose:
--   Regression test for the 2026-08-25 staging-divergence incident: a
--   partial reference-data restore/reseed left config.profile_field_mapping
--   and config.energy_register_semantics silently incomplete for the
--   ENERGY_METER_ENISCOPE_V1 profile (8 of 58 raw fields, 2 of 20 register
--   rows missing) with no error anywhere in the chain. Migration 198
--   introduced config.assert_profile_field_mapping_complete() and
--   config.assert_energy_register_semantics_complete() specifically to
--   turn that silent condition into a loud one.
--
--   This test proves:
--     1. Both guard functions pass cleanly against the real, currently
--        complete ENERGY_METER_ENISCOPE_V1 profile (the positive case --
--        a passing guard must not be a false positive).
--     2. Both guard functions RAISE when a required row is missing,
--        reproducing the exact Aug-20 failure shape (P/P1/P2/P3 and the
--        bare-TOTAL raw fields absent; APPARENT_ENERGY_TOTAL/
--        REACTIVE_ENERGY_TOTAL absent from energy_register_semantics).
--     3. Reference data changes made inside this test never persist --
--        the whole file runs inside one transaction that is rolled back.
--
-- Failure behavior:
--   Any assertion failure raises an exception and causes the test runner
--   to fail.
-- ============================================================================

BEGIN;


DO $$
DECLARE
    v_profile_id UUID;
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION
            'Fixture assumption violated: ENERGY_METER_ENISCOPE_V1 must exist on the canonical test database (seeded by postgres/seeds/reference/28_01_eniscope_energy_profile.sql).';
    END IF;

    -- ------------------------------------------------------------------
    -- 1. Positive case: the guard functions must pass cleanly against
    --    the real, currently complete profile. This is not a smoke test
    --    of "no exception" alone -- if this raises, the fresh canonical
    --    database itself has drifted from what 198 asserts, which is a
    --    real bug in the seed data, not a false positive in the guard.
    -- ------------------------------------------------------------------

    PERFORM config.assert_profile_field_mapping_complete(
        'ENERGY_METER_ENISCOPE_V1',
        ARRAY[
            'A1','A2','A3','AE','AE1','AE2','AE3','C','D','D1','D2','D3',
            'E','E1','E2','E3','Ex','Ex1','Ex2','Ex3','F','I','I1','I2','I3','In',
            'P','P1','P2','P3','PF','PF1','PF2','PF3','Q','Q1','Q2','Q3',
            'RE','RE1','RE2','RE3','REx','REx1','REx2','REx3','S','S1','S2','S3',
            'U','U1','U2','U3','V','V1','V2','V3'
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
END;
$$;


-- ------------------------------------------------------------------
-- 2. Negative case: reproduce the exact Aug-20 shape (P/P1/P2/P3 and
--    AE/Q/RE/S missing from profile_field_mapping) inside a savepoint,
--    and prove the guard raises with a message naming the missing
--    fields. The savepoint is rolled back immediately after, so the
--    deletion never persists even within this transaction.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_profile_id UUID;
    v_raised BOOLEAN := FALSE;
    v_message TEXT;
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';

    BEGIN
        DELETE FROM config.profile_field_mapping
        WHERE profile_id = v_profile_id
          AND raw_field_name IN ('P','P1','P2','P3','AE','Q','RE','S');

        PERFORM config.assert_profile_field_mapping_complete(
            'ENERGY_METER_ENISCOPE_V1',
            ARRAY['P','P1','P2','P3','AE','Q','RE','S','V1']
        );

        RAISE EXCEPTION 'TEST FAILURE: assert_profile_field_mapping_complete did not raise for a deliberately incomplete mapping';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN
                RAISE;
            END IF;
            v_raised := TRUE;
            v_message := SQLERRM;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected guard function to raise, but no exception occurred';
    END IF;

    IF v_message !~ 'P' OR v_message !~ '(missing raw field)' THEN
        RAISE EXCEPTION 'TEST FAILURE: guard exception message did not name the missing fields as expected: %', v_message;
    END IF;

    RAISE NOTICE 'Negative-case guard correctly raised: %', v_message;
END;
$$;


-- ------------------------------------------------------------------
-- 3. Same negative-case proof for config.energy_register_semantics,
--    reproducing the 2-of-20-missing shape found on staging.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_profile_id UUID;
    v_raised BOOLEAN := FALSE;
    v_message TEXT;
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';

    BEGIN
        DELETE FROM config.energy_register_semantics ers
        USING metadata.logical_points lp
        WHERE ers.logical_point_id = lp.id
          AND ers.profile_id = v_profile_id
          AND lp.name IN ('APPARENT_ENERGY_TOTAL', 'REACTIVE_ENERGY_TOTAL');

        PERFORM config.assert_energy_register_semantics_complete(
            'ENERGY_METER_ENISCOPE_V1',
            ARRAY['APPARENT_ENERGY_TOTAL', 'REACTIVE_ENERGY_TOTAL', 'ENERGY_IMPORT_TOTAL']
        );

        RAISE EXCEPTION 'TEST FAILURE: assert_energy_register_semantics_complete did not raise for a deliberately incomplete register set';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN
                RAISE;
            END IF;
            v_raised := TRUE;
            v_message := SQLERRM;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected guard function to raise, but no exception occurred';
    END IF;

    IF v_message !~ 'APPARENT_ENERGY_TOTAL' THEN
        RAISE EXCEPTION 'TEST FAILURE: guard exception message did not name the missing register(s) as expected: %', v_message;
    END IF;

    RAISE NOTICE 'Negative-case register-semantics guard correctly raised: %', v_message;
END;
$$;


-- ------------------------------------------------------------------
-- 4. Guard against an unknown profile: must fail loudly, not silently
--    return / no-op, so a typo'd profile_code in a future migration
--    cannot masquerade as "nothing to check".
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        PERFORM config.assert_profile_field_mapping_complete(
            'NONEXISTENT_PROFILE_CODE_FOR_TEST',
            ARRAY['X']
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected guard function to raise for an unknown profile_code, but no exception occurred';
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Reference-data completeness guard assertions passed.'
    AS result;
