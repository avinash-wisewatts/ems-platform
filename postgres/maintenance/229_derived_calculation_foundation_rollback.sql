-- ============================================================================
-- Rollback for migration 229 (Phase 5 -- SPACE_DEW_POINT SELF slice).
--
-- Controlled, dependency-checked reversal. NOT run as part of any migration.
-- No CASCADE. Reverses only what migration 229 created:
--   * analytics.v_space_dew_point_1min                (view)
--   * the SPACE_DEW_POINT config.parameter_calculations row
--   * config.parameter_calculations                   (table)
--   * the DEW_POINT config.parameters row
--
-- There is NO stored derived state (Phase 5 is view-only), so nothing to
-- reconcile. Refuses to run if anything outside migration 229 has come to
-- depend on config.parameter_calculations or the DEW_POINT parameter.
--
-- Run manually, inside a single transaction:
--   docker compose exec -T <db> psql -X -v ON_ERROR_STOP=1 -U ems_admin -d <db> \
--     -f postgres/maintenance/229_derived_calculation_foundation_rollback.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. Order-independent guards: row count + external references to DEW_POINT.
-- ----------------------------------------------------------------------------
DO $rollback_guard$
DECLARE
    v_rows BIGINT;
BEGIN
    IF to_regclass('config.parameter_calculations') IS NULL
       AND NOT EXISTS (SELECT 1 FROM config.parameters WHERE code = 'DEW_POINT') THEN
        RAISE NOTICE 'Rollback 229: nothing to do (table + parameter already absent).';
        RETURN;
    END IF;

    IF to_regclass('config.parameter_calculations') IS NOT NULL THEN
        SELECT count(*) INTO v_rows FROM config.parameter_calculations;
        IF v_rows > 1 THEN
            RAISE EXCEPTION 'Rollback 229 aborted: config.parameter_calculations holds % rows; a later calculation was added -- resolve before rolling back.', v_rows;
        END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM config.parameters WHERE code = 'DEW_POINT') THEN
        IF EXISTS (
            SELECT 1 FROM metadata.logical_points lp
            JOIN config.parameters p ON p.id = lp.parameter_id
            WHERE p.code = 'DEW_POINT'
        ) THEN
            RAISE EXCEPTION 'Rollback 229 aborted: a metadata.logical_points row references parameter DEW_POINT.';
        END IF;
        IF EXISTS (
            SELECT 1 FROM config.parameter_routing pr
            JOIN config.parameters p ON p.id = pr.parameter_id
            WHERE p.code = 'DEW_POINT'
        ) THEN
            RAISE EXCEPTION 'Rollback 229 aborted: a config.parameter_routing row references parameter DEW_POINT.';
        END IF;
    END IF;
END;
$rollback_guard$;


-- ----------------------------------------------------------------------------
-- 1. Drop migration 229's own view first (it legitimately depends on
--    config.parameter_calculations via its calc sub-select).
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS analytics.v_space_dew_point_1min;


-- ----------------------------------------------------------------------------
-- 1b. Dependency check: after 229's view is gone, nothing else may depend on
--     config.parameter_calculations.
-- ----------------------------------------------------------------------------
DO $dep_guard$
DECLARE
    v_dep TEXT;
BEGIN
    IF to_regclass('config.parameter_calculations') IS NULL THEN
        RETURN;
    END IF;

    SELECT string_agg(DISTINCT obj, ', ') INTO v_dep
    FROM (
        SELECT rw.ev_class::regclass::text AS obj
        FROM pg_depend d
        JOIN pg_rewrite rw ON rw.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
        WHERE d.refobjid = 'config.parameter_calculations'::regclass
          AND d.deptype NOT IN ('a','i')
        UNION
        SELECT p.oid::regprocedure::text
        FROM pg_depend d
        JOIN pg_proc p ON p.oid = d.objid AND d.classid = 'pg_proc'::regclass
        WHERE d.refobjid = 'config.parameter_calculations'::regclass
          AND d.deptype NOT IN ('a','i')
    ) s
    WHERE obj IS NOT NULL;

    IF v_dep IS NOT NULL AND v_dep <> '' THEN
        RAISE EXCEPTION 'Rollback 229 aborted: objects still depend on config.parameter_calculations: %', v_dep;
    END IF;
END;
$dep_guard$;


-- ----------------------------------------------------------------------------
-- 2. Delete the seeded calculation row, then drop the table.
-- ----------------------------------------------------------------------------
DELETE FROM config.parameter_calculations
WHERE output_parameter_id IN (SELECT id FROM config.parameters WHERE code = 'DEW_POINT');

DROP TABLE IF EXISTS config.parameter_calculations;


-- ----------------------------------------------------------------------------
-- 3. Delete the DEW_POINT parameter.
-- ----------------------------------------------------------------------------
DELETE FROM config.parameters WHERE code = 'DEW_POINT';


-- ----------------------------------------------------------------------------
-- 4. Postconditions.
-- ----------------------------------------------------------------------------
DO $rollback_post$
BEGIN
    IF to_regclass('config.parameter_calculations') IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 229 postcondition failed: config.parameter_calculations still exists.';
    END IF;
    IF EXISTS (SELECT 1 FROM config.parameters WHERE code = 'DEW_POINT') THEN
        RAISE EXCEPTION 'Rollback 229 postcondition failed: config.parameters DEW_POINT still exists.';
    END IF;
    IF to_regclass('analytics.v_space_dew_point_1min') IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 229 postcondition failed: analytics.v_space_dew_point_1min still exists.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM config.parameters WHERE code = 'TEMPERATURE')
       OR NOT EXISTS (SELECT 1 FROM config.parameters WHERE code = 'HUMIDITY') THEN
        RAISE EXCEPTION 'Rollback 229 postcondition failed: a canonical input parameter was removed.';
    END IF;
    IF position('parameter_calculations' IN
                pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure)) <> 0 THEN
        RAISE EXCEPTION 'Rollback 229 postcondition failed: energy loader references parameter_calculations.';
    END IF;
END;
$rollback_post$;

COMMIT;
