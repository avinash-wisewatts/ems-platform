-- ============================================================================
-- Migration 251
-- Demand -- corrects analytics.resolve_demand_source_for_interval (migration
-- 250) so the 3-tier method priority is applied among the Asset's CONFIRMED
-- metadata.asset_points only, never a device's theoretical overall
-- capability. Per ADR-018 Amendment 10's clarification (docs/00-governance/
-- decisions/ADR-018-asset-point-assignment-and-commissioning.md).
--
-- Root cause fixed: migration 250's function called config.resolve_device_
-- demand_method(device_id, basis, interval) once per candidate device --
-- that function returns the device's single OVERALL best method (by profile
-- capability alone), then migration 250 only accepted it if the resulting
-- point happened to be confirmed. A device whose profile supports a
-- higher-priority method via an UNCONFIRMED point was therefore rejected
-- entirely, even when it had a valid, confirmed, lower-priority point.
--
-- Fix: replicate the three method-matching rules config.resolve_device_
-- demand_method already encodes (config.demand_register_semantics for
-- METER_NATIVE; config.energy_register_semantics + ENERGY_IMPORT_TOTAL/
-- APPARENT_ENERGY_TOTAL for ENERGY_COUNTER_DELTA; ACTIVE_POWER_TOTAL/
-- APPARENT_POWER_TOTAL for TIME_WEIGHTED_POWER) evaluated directly against
-- each CONFIRMED (device, point) pair from metadata.asset_points, then apply
-- the unchanged 3-tier priority among only those confirmed matches. config.
-- resolve_device_demand_method itself is NOT modified and is no longer
-- called by this function -- its matching rules are the same rules, applied
-- to a different candidate set (confirmed points, not device capability).
--
-- What this migration does NOT do:
--   * Does NOT modify config.resolve_device_demand_method,
--     config.demand_register_semantics, config.energy_register_semantics,
--     analytics.calculate_demand_window, or analytics.refresh_demand_
--     analytics -- the source-boundary containment logic and calculation
--     branches from migration 250 are unchanged.
--   * Does NOT change the function's signature or return shape.
--
-- Updated tests: scripts/test/assert_demand_source_confirmed_priority.sh
-- (new: lower-priority confirmed point wins over a higher-priority
-- unconfirmed one; higher-priority confirmed point wins when multiple
-- confirmed methods exist; existing single-source behaviour unchanged).
-- ============================================================================


DO $pre$
BEGIN
    IF to_regprocedure('analytics.resolve_demand_source_for_interval(uuid, timestamptz, timestamptz, text, integer)') IS NULL THEN
        RAISE EXCEPTION 'Migration 251 precondition failed: analytics.resolve_demand_source_for_interval(...) is missing (migration 250).';
    END IF;
END;
$pre$;


CREATE OR REPLACE FUNCTION analytics.resolve_demand_source_for_interval
(
    p_asset_id                UUID,
    p_interval_start          TIMESTAMPTZ,
    p_interval_end            TIMESTAMPTZ,
    p_demand_basis            TEXT,
    p_demand_interval_seconds INTEGER
)
RETURNS TABLE
(
    device_id       UUID,
    logical_point_id UUID,
    profile_id      UUID,
    profile_code    TEXT,
    selected_method TEXT
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, config, metadata
AS $function$
    WITH params AS (
        SELECT upper(btrim(p_demand_basis)) AS demand_basis
        WHERE p_demand_basis IS NOT NULL
          AND upper(btrim(p_demand_basis)) IN ('ACTIVE_POWER_KW', 'APPARENT_POWER_KVA')
          AND p_demand_interval_seconds IN (900, 1800)
    ),
    covering_points AS (
        -- Every asset_points binding for this asset whose effective range
        -- fully contains the requested interval -- unchanged from
        -- migration 250: a mid-interval source change fails this
        -- containment check on both sides, implementing the boundary rule.
        SELECT ap.device_id, ap.logical_point_id, d.profile_id, dp.profile_code
        FROM metadata.asset_points AS ap
        JOIN metadata.devices AS d ON d.id = ap.device_id
        LEFT JOIN config.device_profiles AS dp ON dp.id = d.profile_id
        WHERE ap.asset_id = p_asset_id
          AND ap.effective_from <= p_interval_start
          AND (ap.effective_to IS NULL OR ap.effective_to >= p_interval_end)
    ),
    -- The three method-matching rules from config.resolve_device_demand_
    -- method, replicated here and evaluated only against CONFIRMED points
    -- -- never a device's unconfirmed theoretical capability.
    native_matches AS (
        SELECT cp.device_id, cp.logical_point_id, cp.profile_id, cp.profile_code,
               'METER_NATIVE'::TEXT AS selected_method
        FROM covering_points AS cp
        JOIN params AS pr ON TRUE
        JOIN config.demand_register_semantics AS drs
          ON drs.profile_id = cp.profile_id
         AND drs.logical_point_id = cp.logical_point_id
         AND drs.is_active
         AND drs.demand_basis = pr.demand_basis
         AND drs.native_interval_seconds = p_demand_interval_seconds
         AND drs.alignment_mode = 'WALL_CLOCK'
    ),
    counter_matches AS (
        SELECT cp.device_id, cp.logical_point_id, cp.profile_id, cp.profile_code,
               'ENERGY_COUNTER_DELTA'::TEXT AS selected_method
        FROM covering_points AS cp
        JOIN params AS pr ON TRUE
        JOIN metadata.logical_points AS lp ON lp.id = cp.logical_point_id
        JOIN config.energy_register_semantics AS ers
          ON ers.profile_id = cp.profile_id
         AND ers.logical_point_id = cp.logical_point_id
         AND ers.is_active
        WHERE
            (pr.demand_basis = 'ACTIVE_POWER_KW'
             AND lp.name = 'ENERGY_IMPORT_TOTAL'
             AND ers.normalized_unit_symbol = 'Wh')
            OR
            (pr.demand_basis = 'APPARENT_POWER_KVA'
             AND lp.name = 'APPARENT_ENERGY_TOTAL'
             AND ers.normalized_unit_symbol = 'VAh')
    ),
    power_matches AS (
        SELECT cp.device_id, cp.logical_point_id, cp.profile_id, cp.profile_code,
               'TIME_WEIGHTED_POWER'::TEXT AS selected_method
        FROM covering_points AS cp
        JOIN params AS pr ON TRUE
        JOIN metadata.logical_points AS lp ON lp.id = cp.logical_point_id
        WHERE
            (pr.demand_basis = 'ACTIVE_POWER_KW' AND lp.name = 'ACTIVE_POWER_TOTAL')
            OR
            (pr.demand_basis = 'APPARENT_POWER_KVA' AND lp.name = 'APPARENT_POWER_TOTAL')
    ),
    all_matches AS (
        SELECT * FROM native_matches
        UNION ALL
        SELECT * FROM counter_matches
        UNION ALL
        SELECT * FROM power_matches
    )
    SELECT device_id, logical_point_id, profile_id, profile_code, selected_method
    FROM all_matches
    ORDER BY
        CASE selected_method
            WHEN 'METER_NATIVE' THEN 1
            WHEN 'ENERGY_COUNTER_DELTA' THEN 2
            WHEN 'TIME_WEIGHTED_POWER' THEN 3
            ELSE 4
        END
    LIMIT 1;
$function$;

ALTER FUNCTION analytics.resolve_demand_source_for_interval(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.resolve_demand_source_for_interval(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.resolve_demand_source_for_interval(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER) TO ems_app;


DO $post$
DECLARE
    v_sig TEXT := 'analytics.resolve_demand_source_for_interval(uuid, timestamptz, timestamptz, text, integer)';
    v_body TEXT;
BEGIN
    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 251 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 251 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));
    IF position('resolve_device_demand_method' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 251 postcondition failed: % must no longer call config.resolve_device_demand_method -- method matching must be evaluated against confirmed asset_points directly.', v_sig;
    END IF;
    IF position('demand_register_semantics' IN v_body) = 0
       OR position('energy_register_semantics' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 251 postcondition failed: % must evaluate all three method-matching rules directly.', v_sig;
    END IF;

    RAISE NOTICE 'Migration 251: all postconditions passed (Demand source resolution now applies the 3-tier priority among confirmed asset_points only).';
END;
$post$;
