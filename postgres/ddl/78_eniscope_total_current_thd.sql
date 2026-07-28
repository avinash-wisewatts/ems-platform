-- ============================================================================
-- File:
--   78_eniscope_total_current_thd.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.1 — Formalize import/export register semantics
--
-- Related hardware-contract correction:
--   Current Eniscope firmware also emits:
--
--       D = total/system current total harmonic distortion, percent
--
-- Purpose:
--   Add a canonical logical point for total current THD and map the Eniscope
--   raw field D to that point.
--
-- The existing D1, D2 and D3 fields remain mapped to phase-specific THD.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Create the canonical logical point.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.logical_points
(
    name,
    description,
    unit_id,
    data_type
)
SELECT
    'CURRENT_THD_TOTAL',
    'System total current harmonic distortion',
    eu.id,
    'numeric'
FROM config.engineering_units eu
WHERE eu.symbol = '%'
  AND NOT EXISTS
  (
      SELECT 1
      FROM metadata.logical_points lp
      WHERE lp.name = 'CURRENT_THD_TOTAL'
  );


-- Fail clearly if the percentage engineering unit is missing.
DO
$$
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM metadata.logical_points lp
        WHERE lp.name = 'CURRENT_THD_TOTAL'
    )
    THEN
        RAISE EXCEPTION
            'CURRENT_THD_TOTAL could not be created because the %% engineering unit was not found';
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 2. Map Eniscope raw field D to total current THD.
-- ----------------------------------------------------------------------------

INSERT INTO config.profile_field_mapping
(
    profile_id,
    raw_field_name,
    logical_point_id,
    json_path,
    transform_expression,
    is_required,
    display_order
)
SELECT
    dp.id,
    'D',
    lp.id,
    NULL,
    NULL,
    FALSE,
    0
FROM config.device_profiles dp
JOIN metadata.logical_points lp
  ON lp.name = 'CURRENT_THD_TOTAL'
WHERE dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
ON CONFLICT
(
    profile_id,
    raw_field_name
)
DO UPDATE
SET
    logical_point_id =
        EXCLUDED.logical_point_id,

    json_path =
        EXCLUDED.json_path,

    transform_expression =
        EXCLUDED.transform_expression,

    is_required =
        EXCLUDED.is_required,

    display_order =
        EXCLUDED.display_order;


COMMENT ON COLUMN config.profile_field_mapping.transform_expression IS
'Reserved metadata field. The current normalization view does not execute transform expressions.';


-- ----------------------------------------------------------------------------
-- 3. Least-privilege behavior remains unchanged.
--
-- The application reads mappings through controlled normalization and
-- onboarding contracts. No new direct application grants are introduced.
-- ----------------------------------------------------------------------------
