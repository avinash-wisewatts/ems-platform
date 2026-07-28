-- ============================================================================
-- File:
--   scripts/test/assert_energy_register_semantics.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.1 — Formalize import/export register semantics
--
-- Purpose:
--   Deterministically validate the cumulative-register classifier without
--   creating persistent metadata or telemetry fixtures.
--
-- Failure behavior:
--   Any mismatch raises an exception and causes the test runner to fail.
-- ============================================================================

BEGIN;


DO $$
DECLARE
    v_failures INTEGER;
BEGIN
    WITH test_cases AS
    (
        SELECT *
        FROM
        (
            VALUES
            (
                'normal increase',
                1250::NUMERIC,
                1000::NUMERIC,
                15::NUMERIC,
                'INCREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'GOOD'::TEXT,
                250::NUMERIC,
                TRUE,
                FALSE,
                FALSE
            ),
            (
                'long gap',
                1500::NUMERIC,
                1000::NUMERIC,
                45::NUMERIC,
                'INCREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'GAP'::TEXT,
                500::NUMERIC,
                TRUE,
                FALSE,
                FALSE
            ),
            (
                'rejected reset',
                100::NUMERIC,
                900::NUMERIC,
                15::NUMERIC,
                'INCREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'RESET'::TEXT,
                NULL::NUMERIC,
                FALSE,
                TRUE,
                FALSE
            ),
            (
                'flag-only reset',
                100::NUMERIC,
                900::NUMERIC,
                15::NUMERIC,
                'INCREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'FLAG_ONLY'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'RESET'::TEXT,
                NULL::NUMERIC,
                FALSE,
                TRUE,
                FALSE
            ),
            (
                'accepted reset from zero',
                100::NUMERIC,
                900::NUMERIC,
                15::NUMERIC,
                'INCREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'ACCEPT_FROM_ZERO'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'RESET_FROM_ZERO'::TEXT,
                100::NUMERIC,
                TRUE,
                TRUE,
                FALSE
            ),
            (
                'fixed modulus rollover',
                25::NUMERIC,
                990::NUMERIC,
                15::NUMERIC,
                'INCREASING'::TEXT,
                'FIXED_MODULUS'::TEXT,
                1000::NUMERIC,
                'REJECT_DELTA'::TEXT,
                100::NUMERIC,
                30::NUMERIC,
                'ROLLOVER'::TEXT,
                35::NUMERIC,
                TRUE,
                FALSE,
                TRUE
            ),
            (
                'unresolved device rollover',
                25::NUMERIC,
                990::NUMERIC,
                15::NUMERIC,
                'INCREASING'::TEXT,
                'DEVICE_DEFINED'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                100::NUMERIC,
                30::NUMERIC,
                'ROLLOVER_UNRESOLVED'::TEXT,
                NULL::NUMERIC,
                FALSE,
                FALSE,
                FALSE
            ),
            (
                'implausible increase',
                2500::NUMERIC,
                1000::NUMERIC,
                15::NUMERIC,
                'INCREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'IMPLAUSIBLE_DELTA'::TEXT,
                NULL::NUMERIC,
                FALSE,
                FALSE,
                FALSE
            ),
            (
                'missing configuration',
                1250::NUMERIC,
                1000::NUMERIC,
                15::NUMERIC,
                NULL::TEXT,
                NULL::TEXT,
                NULL::NUMERIC,
                NULL::TEXT,
                NULL::NUMERIC,
                30::NUMERIC,
                'CONFIG_MISSING'::TEXT,
                NULL::NUMERIC,
                FALSE,
                FALSE,
                FALSE
            ),
            (
                'decreasing counter valid',
                750::NUMERIC,
                1000::NUMERIC,
                15::NUMERIC,
                'DECREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'GOOD'::TEXT,
                250::NUMERIC,
                TRUE,
                FALSE,
                FALSE
            ),
            (
                'decreasing direction violation',
                1250::NUMERIC,
                1000::NUMERIC,
                15::NUMERIC,
                'DECREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'DIRECTION_ERROR'::TEXT,
                NULL::NUMERIC,
                FALSE,
                FALSE,
                FALSE
            ),
            (
                'bidirectional movement',
                750::NUMERIC,
                1000::NUMERIC,
                15::NUMERIC,
                'BIDIRECTIONAL'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'GOOD'::TEXT,
                250::NUMERIC,
                TRUE,
                FALSE,
                FALSE
            ),
            (
                'initial register',
                1000::NUMERIC,
                NULL::NUMERIC,
                NULL::NUMERIC,
                'INCREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'INITIAL'::TEXT,
                NULL::NUMERIC,
                FALSE,
                FALSE,
                FALSE
            ),
            (
                'missing current register',
                NULL::NUMERIC,
                1000::NUMERIC,
                15::NUMERIC,
                'INCREASING'::TEXT,
                'NONE'::TEXT,
                NULL::NUMERIC,
                'REJECT_DELTA'::TEXT,
                1000::NUMERIC,
                30::NUMERIC,
                'MISSING_REGISTER'::TEXT,
                NULL::NUMERIC,
                FALSE,
                FALSE,
                FALSE
            )
        )
        AS t
        (
            test_name,
            current_register,
            previous_register,
            elapsed_minutes,
            counter_direction,
            rollover_behavior,
            rollover_value,
            reset_behavior,
            expected_max_delta,
            gap_threshold_minutes,
            expected_quality,
            expected_delta,
            expected_valid,
            expected_reset,
            expected_rollover
        )
    ),
    evaluated AS
    (
        SELECT
            tc.*,
            result.delta_wh,
            result.quality_code,
            result.is_valid,
            result.reset_detected,
            result.rollover_detected
        FROM test_cases tc

        CROSS JOIN LATERAL
        analytics.classify_energy_register_delta
        (
            tc.current_register,
            tc.previous_register,
            tc.elapsed_minutes,
            tc.counter_direction,
            tc.rollover_behavior,
            tc.rollover_value,
            tc.reset_behavior,
            tc.expected_max_delta,
            tc.gap_threshold_minutes
        ) result
    )
    SELECT COUNT(*)
    INTO v_failures
    FROM evaluated
    WHERE quality_code IS DISTINCT FROM expected_quality
       OR delta_wh IS DISTINCT FROM expected_delta
       OR is_valid IS DISTINCT FROM expected_valid
       OR reset_detected IS DISTINCT FROM expected_reset
       OR rollover_detected IS DISTINCT FROM expected_rollover;


    IF v_failures > 0 THEN
        RAISE EXCEPTION
            'Energy register semantic classifier failed % test case(s)',
            v_failures;
    END IF;
END;
$$;


-- Confirm the production view invokes the authoritative classifier twice:
-- once for import and once for export.

DO $$
DECLARE
    v_classifier_references INTEGER;
BEGIN
    SELECT
        (
            LENGTH(view_definition)
            -
            LENGTH
            (
                REPLACE
                (
                    view_definition,
                    'classify_energy_register_delta',
                    ''
                )
            )
        )
        /
        LENGTH('classify_energy_register_delta')
    INTO v_classifier_references
    FROM information_schema.views
    WHERE table_schema = 'analytics'
      AND table_name = 'v_energy_consumption_15min';


    IF v_classifier_references <> 2 THEN
        RAISE EXCEPTION
            'Expected 2 classifier references in analytics.v_energy_consumption_15min, found %',
            v_classifier_references;
    END IF;
END;
$$;


-- Confirm Eniscope import/export semantics are uniquely configured.

DO $$
DECLARE
    v_invalid_devices INTEGER;
BEGIN
    WITH coverage AS
    (
        SELECT
            d.id,

            COUNT(*) FILTER
            (
                WHERE ers.flow_interpretation = 'GRID_IMPORT'
                  AND ers.is_active = TRUE
            ) AS import_count,

            COUNT(*) FILTER
            (
                WHERE ers.flow_interpretation = 'GRID_EXPORT'
                  AND ers.is_active = TRUE
            ) AS export_count

        FROM metadata.devices d

        JOIN config.device_profiles dp
          ON dp.id = d.profile_id

        LEFT JOIN config.energy_register_semantics ers
          ON ers.profile_id = d.profile_id

        WHERE dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'

        GROUP BY d.id
    )
    SELECT COUNT(*)
    INTO v_invalid_devices
    FROM coverage
    WHERE import_count <> 1
       OR export_count <> 1;


    IF v_invalid_devices > 0 THEN
        RAISE EXCEPTION
            '% Eniscope device(s) lack exactly one import and export semantic contract',
            v_invalid_devices;
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Energy register semantic assertions passed.'
    AS result;
