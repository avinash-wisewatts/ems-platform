-- ============================================================================
-- File:
--   81_energy_register_delta_classifier.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.1 — Formalize import/export register semantics
--
-- Purpose:
--   Provide one deterministic classifier for cumulative energy-register
--   intervals. Import, export, reactive, apparent and future generation
--   registers can reuse the same logic.
--
-- Design:
--   The function is pure and does not read tables. All semantic configuration
--   is supplied explicitly by the caller.
--
-- Output:
--   delta_wh           Qualified interval delta; NULL when excluded.
--   quality_code       Classification explaining the outcome.
--   is_valid           TRUE when delta_wh may be included in analytics.
--   reset_detected     TRUE for rejected or accepted reset events.
--   rollover_detected  TRUE for successfully resolved rollover events.
-- ============================================================================


CREATE OR REPLACE FUNCTION analytics.classify_energy_register_delta
(
    p_current_register             NUMERIC,
    p_previous_register            NUMERIC,
    p_elapsed_minutes              NUMERIC,
    p_counter_direction            TEXT,
    p_rollover_behavior            TEXT,
    p_rollover_value               NUMERIC,
    p_reset_behavior               TEXT,
    p_expected_max_interval_delta  NUMERIC,
    p_gap_threshold_minutes        NUMERIC DEFAULT 30
)
RETURNS TABLE
(
    delta_wh            NUMERIC,
    quality_code        TEXT,
    is_valid            BOOLEAN,
    reset_detected      BOOLEAN,
    rollover_detected   BOOLEAN
)
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
DECLARE
    v_candidate_delta NUMERIC;
BEGIN
    -- ------------------------------------------------------------------------
    -- Structural classifications.
    -- ------------------------------------------------------------------------

    IF p_previous_register IS NULL THEN
        RETURN QUERY
        SELECT
            NULL::NUMERIC,
            'INITIAL'::TEXT,
            FALSE,
            FALSE,
            FALSE;
        RETURN;
    END IF;


    IF p_current_register IS NULL THEN
        RETURN QUERY
        SELECT
            NULL::NUMERIC,
            'MISSING_REGISTER'::TEXT,
            FALSE,
            FALSE,
            FALSE;
        RETURN;
    END IF;


    IF p_counter_direction IS NULL
       OR p_rollover_behavior IS NULL
       OR p_reset_behavior IS NULL
       OR p_expected_max_interval_delta IS NULL
    THEN
        RETURN QUERY
        SELECT
            NULL::NUMERIC,
            'CONFIG_MISSING'::TEXT,
            FALSE,
            FALSE,
            FALSE;
        RETURN;
    END IF;


    -- Defensive validation protects callers outside the constrained
    -- config.energy_register_semantics table.

    IF p_counter_direction NOT IN
    (
        'INCREASING',
        'DECREASING',
        'BIDIRECTIONAL'
    )
    OR p_rollover_behavior NOT IN
    (
        'NONE',
        'FIXED_MODULUS',
        'DEVICE_DEFINED'
    )
    OR p_reset_behavior NOT IN
    (
        'REJECT_DELTA',
        'ACCEPT_FROM_ZERO',
        'FLAG_ONLY'
    )
    OR p_expected_max_interval_delta <= 0
    THEN
        RETURN QUERY
        SELECT
            NULL::NUMERIC,
            'CONFIG_INVALID'::TEXT,
            FALSE,
            FALSE,
            FALSE;
        RETURN;
    END IF;


    -- ------------------------------------------------------------------------
    -- Increasing counters.
    -- ------------------------------------------------------------------------

    IF p_counter_direction = 'INCREASING' THEN

        IF p_current_register >= p_previous_register THEN
            v_candidate_delta :=
                p_current_register - p_previous_register;

        ELSE
            -- Register decreased.

            IF p_rollover_behavior = 'DEVICE_DEFINED' THEN
                RETURN QUERY
                SELECT
                    NULL::NUMERIC,
                    'ROLLOVER_UNRESOLVED'::TEXT,
                    FALSE,
                    FALSE,
                    FALSE;
                RETURN;

            ELSIF p_rollover_behavior = 'FIXED_MODULUS' THEN

                IF p_rollover_value IS NULL
                   OR p_rollover_value <= 0
                   OR p_previous_register > p_rollover_value
                THEN
                    RETURN QUERY
                    SELECT
                        NULL::NUMERIC,
                        'CONFIG_INVALID'::TEXT,
                        FALSE,
                        FALSE,
                        FALSE;
                    RETURN;
                END IF;

                v_candidate_delta :=
                    p_rollover_value
                    - p_previous_register
                    + p_current_register;

                IF v_candidate_delta < 0 THEN
                    RETURN QUERY
                    SELECT
                        NULL::NUMERIC,
                        'DIRECTION_ERROR'::TEXT,
                        FALSE,
                        FALSE,
                        FALSE;
                    RETURN;
                END IF;

                IF v_candidate_delta >
                   p_expected_max_interval_delta
                THEN
                    RETURN QUERY
                    SELECT
                        NULL::NUMERIC,
                        'IMPLAUSIBLE_DELTA'::TEXT,
                        FALSE,
                        FALSE,
                        TRUE;
                    RETURN;
                END IF;

                RETURN QUERY
                SELECT
                    v_candidate_delta,
                    'ROLLOVER'::TEXT,
                    TRUE,
                    FALSE,
                    TRUE;
                RETURN;

            ELSIF p_reset_behavior = 'ACCEPT_FROM_ZERO' THEN
                -- After a reset, the current register represents energy
                -- accumulated since zero.
                v_candidate_delta := p_current_register;

                IF v_candidate_delta >
                   p_expected_max_interval_delta
                THEN
                    RETURN QUERY
                    SELECT
                        NULL::NUMERIC,
                        'IMPLAUSIBLE_DELTA'::TEXT,
                        FALSE,
                        TRUE,
                        FALSE;
                    RETURN;
                END IF;

                RETURN QUERY
                SELECT
                    v_candidate_delta,
                    'RESET_FROM_ZERO'::TEXT,
                    TRUE,
                    TRUE,
                    FALSE;
                RETURN;

            ELSE
                -- REJECT_DELTA and FLAG_ONLY both exclude the uncertain delta.
                RETURN QUERY
                SELECT
                    NULL::NUMERIC,
                    'RESET'::TEXT,
                    FALSE,
                    TRUE,
                    FALSE;
                RETURN;
            END IF;
        END IF;


    -- ------------------------------------------------------------------------
    -- Decreasing counters.
    -- ------------------------------------------------------------------------

    ELSIF p_counter_direction = 'DECREASING' THEN

        IF p_current_register <= p_previous_register THEN
            v_candidate_delta :=
                p_previous_register - p_current_register;
        ELSE
            RETURN QUERY
            SELECT
                NULL::NUMERIC,
                'DIRECTION_ERROR'::TEXT,
                FALSE,
                FALSE,
                FALSE;
            RETURN;
        END IF;


    -- ------------------------------------------------------------------------
    -- Bidirectional counters.
    --
    -- Directional interpretation is unavailable, so the absolute movement is
    -- used. Dedicated import/export registers should normally be preferred.
    -- ------------------------------------------------------------------------

    ELSE
        v_candidate_delta :=
            ABS
            (
                p_current_register -
                p_previous_register
            );
    END IF;


    -- ------------------------------------------------------------------------
    -- Plausibility and gap classification for normal progression.
    -- ------------------------------------------------------------------------

    IF v_candidate_delta >
       p_expected_max_interval_delta
    THEN
        RETURN QUERY
        SELECT
            NULL::NUMERIC,
            'IMPLAUSIBLE_DELTA'::TEXT,
            FALSE,
            FALSE,
            FALSE;
        RETURN;
    END IF;


    IF p_elapsed_minutes IS NOT NULL
       AND p_gap_threshold_minutes IS NOT NULL
       AND p_elapsed_minutes > p_gap_threshold_minutes
    THEN
        RETURN QUERY
        SELECT
            v_candidate_delta,
            'GAP'::TEXT,
            TRUE,
            FALSE,
            FALSE;
        RETURN;
    END IF;


    RETURN QUERY
    SELECT
        v_candidate_delta,
        'GOOD'::TEXT,
        TRUE,
        FALSE,
        FALSE;
END;
$function$;


COMMENT ON FUNCTION analytics.classify_energy_register_delta
(
    NUMERIC,
    NUMERIC,
    NUMERIC,
    TEXT,
    TEXT,
    NUMERIC,
    TEXT,
    NUMERIC,
    NUMERIC
)
IS
'Pure semantic classifier for cumulative energy-register interval deltas.';


REVOKE ALL
ON FUNCTION analytics.classify_energy_register_delta
(
    NUMERIC,
    NUMERIC,
    NUMERIC,
    TEXT,
    TEXT,
    NUMERIC,
    TEXT,
    NUMERIC,
    NUMERIC
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION analytics.classify_energy_register_delta
(
    NUMERIC,
    NUMERIC,
    NUMERIC,
    TEXT,
    TEXT,
    NUMERIC,
    TEXT,
    NUMERIC,
    NUMERIC
)
TO grafana_reader;
