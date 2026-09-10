-- ============================================================================
-- Migration 231
-- Phase 7 (Analytics API / Query Boundary) -- FIRST SLICE.
--
-- Source of record:
--   docs/DDS/analytics-platform-future-state-architecture.md F / G
--     ("expose asset-shaped, space-shaped, and site-shaped read objects ...
--      never metadata.asset_points or telemetry.* directly"; "the same rule
--      that already governs v_grafana_* should govern every new surface").
--   docs/DDS/analytics-platform-future-state-architecture-implementation-
--     roadmap.md Phase 7 ("the stable contract between the data model and any
--     consumer"; "additive views/functions; no existing v_grafana_* object is
--     altered"; "per-view tenant-isolation contract tests").
--   Phase 7 Pre-Implementation Audit Reconciliation -- APPROVED first slice.
--
-- What this migration does (ADDITIVE ONLY):
--   Creates the read-only, portal-user-scoped query boundary that the new
--   /api/v1 semantic JSON API sits directly on top of. Three new functions in
--   schema analytics, each:
--     * SECURITY DEFINER, STABLE, explicit parameter + return types,
--     * pinned SET search_path, no dynamic SQL, no arbitrary query
--       construction,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope re-derived server-side from p_portal_user_id via the
--       established admin.portal_user_can_access_site pattern; a caller that
--       cannot see the site gets ZERO ROWS (never an error, never a leak of
--       whether the resource exists).
--
--   1. analytics.portal_user_can_access_space(bigint, uuid) -> boolean
--        Space-level accessibility probe. Resolves space -> floor -> building
--        -> site and delegates to admin.portal_user_can_access_site. FALSE for
--        an unknown space. Used by the API to tell 404 (unknown/inaccessible)
--        apart from 200/no_data (accessible, empty range) -- the two are
--        deliberately indistinguishable to the caller.
--
--   2. analytics.get_portal_space_measurement_series(
--          p_portal_user_id bigint, p_space_id uuid, p_parameter text,
--          p_from timestamptz, p_to timestamptz, p_resolution text)
--        RETURNS TABLE(bucket_start timestamptz, numeric_value double
--                      precision, quality_code smallint, sample_count bigint)
--        Supported p_parameter (closed set): 'TEMPERATURE', 'HUMIDITY',
--          'DEW_POINT'.
--        Supported p_resolution (closed set): 'raw' (1-minute native),
--          '1h' (arithmetic mean of the stored 1-minute values in each
--          UTC-aligned hour; sample_count = number of stored values averaged).
--        TEMPERATURE / HUMIDITY read telemetry.environment_measurements
--          (temperature_c / humidity_percent), filtered by the row's
--          routing-resolved space_id (Phase 3 / migration 226).
--        DEW_POINT reads analytics.derived_parameter_values (Phase 6 /
--          migration 230) -- the PERSISTED derived values, selected by
--          output_parameter_id = DEW_POINT and subject_type = 'SPACE'. The
--          stored numeric_value is returned (raw) or averaged (1h); dew point
--          is NEVER recomputed here -- this function does not reference
--          analytics.v_space_dew_point_1min or the Magnus/Arden-Buck formula.
--        quality_code is NULL pass-through (Phase 6 discipline: no lattice,
--          no invented vocabulary); '1h' rows carry NULL quality_code because
--          an average has no single source quality.
--
--   3. analytics.get_portal_site_energy_consumption(
--          p_portal_user_id bigint, p_site_id uuid,
--          p_from timestamptz, p_to timestamptz, p_resolution text)
--        RETURNS TABLE(bucket_start timestamptz, import_consumption_kwh
--                      numeric, export_consumption_kwh numeric,
--                      source_interval_count bigint)
--        Supported p_resolution (closed set): '1h', '1d'.
--        A pure site-level SUM roll-up, per time bucket, of the mature
--        persisted energy historians analytics.energy_consumption_hourly
--        (migration 181) and analytics.energy_consumption_daily (migration
--        183). NO energy calculation, classification, register arithmetic,
--        gap/reset logic, or continuous-aggregate refresh occurs here -- it
--        reads already-computed device rows and adds them up. It writes
--        nothing.
--
-- What this migration does NOT do:
--   * No change to any energy table, energy calculation, energy job, energy
--     pipeline_state, continuous aggregate, or routing configuration.
--   * No change to analytics.v_space_dew_point_1min, analytics.
--     derived_parameter_values, config.parameter_calculations, config.
--     parameter_routing, any Phase 6 job, or any AirSense binding.
--   * No change to any v_grafana_* object, any Grafana provisioning, or
--     grafana_reader grants.
--   * No new table, hypertable, TimescaleDB job, retention/compression
--     policy, trigger, or generalized query engine. No dynamic SQL.
--
-- Transaction: NO BEGIN/COMMIT of its own -- scripts/apply_migrations.sh wraps
--   the file + the ledger INSERT in one transaction (matches 223-230).
--
-- Rollback: postgres/maintenance/231_analytics_api_query_boundary_rollback.sql
--   -- dependency-checked, no CASCADE, safe if never applied.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions -- the boundary depends on Phases 1-6 already being present.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing (three-role scope model).';
    END IF;

    IF to_regprocedure('admin.list_accessible_sites(bigint)') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: admin.list_accessible_sites(bigint) is missing (three-role scope model).';
    END IF;

    IF to_regclass('metadata.spaces')    IS NULL
       OR to_regclass('metadata.floors') IS NULL
       OR to_regclass('metadata.buildings') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: metadata.spaces / floors / buildings not all present.';
    END IF;

    IF to_regclass('telemetry.environment_measurements') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: telemetry.environment_measurements is missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'telemetry' AND table_name = 'environment_measurements'
          AND column_name = 'space_id'
    ) THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: telemetry.environment_measurements.space_id is missing (Phase 3 / migration 226).';
    END IF;

    IF to_regclass('analytics.derived_parameter_values') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: analytics.derived_parameter_values is missing (Phase 6 / migration 230).';
    END IF;

    IF to_regclass('analytics.energy_consumption_hourly') IS NULL
       OR to_regclass('analytics.energy_consumption_daily') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: persisted energy historians (migrations 181 / 183) not both present.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM config.parameters WHERE code = 'DEW_POINT') THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: config.parameters has no DEW_POINT row (Phase 5 / migration 229).';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM config.parameters WHERE code = 'TEMPERATURE')
       OR NOT EXISTS (SELECT 1 FROM config.parameters WHERE code = 'HUMIDITY') THEN
        RAISE EXCEPTION 'Migration 231 precondition failed: config.parameters is missing TEMPERATURE / HUMIDITY (Phase 1 / migration 223).';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.portal_user_can_access_space(bigint, uuid) -> boolean
--    Space-level accessibility probe. FALSE for an unknown space.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.portal_user_can_access_space
(
    p_portal_user_id BIGINT,
    p_space_id       UUID
)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
    SELECT COALESCE(
        (
            SELECT admin.portal_user_can_access_site(
                       p_portal_user_id,
                       building_record.site_id
                   )
            FROM metadata.spaces AS space_record
            JOIN metadata.floors AS floor_record
              ON floor_record.id = space_record.floor_id
            JOIN metadata.buildings AS building_record
              ON building_record.id = floor_record.building_id
            WHERE space_record.id = p_space_id
        ),
        FALSE
    );
$function$;

ALTER FUNCTION analytics.portal_user_can_access_space(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.portal_user_can_access_space(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.portal_user_can_access_space(BIGINT, UUID) TO ems_app;

COMMENT ON FUNCTION analytics.portal_user_can_access_space(BIGINT, UUID) IS
'Phase 7 (migration 231): space-level accessibility probe for the /api/v1 boundary. Resolves space -> floor -> building -> site and delegates to admin.portal_user_can_access_site. FALSE for an unknown space. Lets the API distinguish 404 (unknown or inaccessible -- indistinguishable by design) from 200/no_data (accessible, empty range).';


-- ----------------------------------------------------------------------------
-- 2. analytics.get_portal_space_measurement_series(...)
--    Portal-user-scoped environmental measurement series for one space.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_space_measurement_series
(
    p_portal_user_id BIGINT,
    p_space_id       UUID,
    p_parameter      TEXT,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_resolution     TEXT
)
RETURNS TABLE
(
    bucket_start  TIMESTAMPTZ,
    numeric_value DOUBLE PRECISION,
    quality_code  SMALLINT,
    sample_count  BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata, telemetry, config
AS $function$
DECLARE
    v_site_id            UUID;
    v_dew_point_param_id UUID;
    -- UTC-aligned hour origin (matches migration 230's date_bin origin).
    v_origin CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
BEGIN
    -- Closed-set input validation. Raised errors use SQLSTATE 22023
    -- (invalid_parameter_value); the API maps them to HTTP 422 and never
    -- reaches this function with an out-of-contract value in normal operation.
    IF p_parameter IS NULL OR p_parameter NOT IN ('TEMPERATURE', 'HUMIDITY', 'DEW_POINT') THEN
        RAISE EXCEPTION 'analytics.get_portal_space_measurement_series: unsupported parameter %', p_parameter
            USING ERRCODE = '22023';
    END IF;

    IF p_resolution IS NULL OR p_resolution NOT IN ('raw', '1h') THEN
        RAISE EXCEPTION 'analytics.get_portal_space_measurement_series: unsupported resolution %', p_resolution
            USING ERRCODE = '22023';
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
        RAISE EXCEPTION 'analytics.get_portal_space_measurement_series: invalid time range (from must be < to)'
            USING ERRCODE = '22023';
    END IF;

    -- Server-side tenant scope: resolve the space's site and re-derive
    -- accessibility. Unknown space or no access -> zero rows (no error, no
    -- existence leak).
    SELECT building_record.site_id
      INTO v_site_id
    FROM metadata.spaces AS space_record
    JOIN metadata.floors AS floor_record
      ON floor_record.id = space_record.floor_id
    JOIN metadata.buildings AS building_record
      ON building_record.id = floor_record.building_id
    WHERE space_record.id = p_space_id;

    IF v_site_id IS NULL
       OR NOT admin.portal_user_can_access_site(p_portal_user_id, v_site_id) THEN
        RETURN;
    END IF;

    IF p_parameter IN ('TEMPERATURE', 'HUMIDITY') THEN
        IF p_resolution = 'raw' THEN
            RETURN QUERY
            SELECT
                em.bucket_start,
                (CASE p_parameter
                     WHEN 'TEMPERATURE' THEN em.temperature_c
                     ELSE em.humidity_percent
                 END)::DOUBLE PRECISION,
                em.quality_code,
                1::BIGINT
            FROM telemetry.environment_measurements AS em
            WHERE em.space_id = p_space_id
              AND em.bucket_start >= p_from
              AND em.bucket_start <  p_to
              AND (CASE p_parameter
                       WHEN 'TEMPERATURE' THEN em.temperature_c
                       ELSE em.humidity_percent
                   END) IS NOT NULL
            ORDER BY em.bucket_start;
        ELSE
            RETURN QUERY
            SELECT
                date_bin(INTERVAL '1 hour', em.bucket_start, v_origin),
                avg(CASE p_parameter
                        WHEN 'TEMPERATURE' THEN em.temperature_c
                        ELSE em.humidity_percent
                    END)::DOUBLE PRECISION,
                NULL::SMALLINT,
                count(*)::BIGINT
            FROM telemetry.environment_measurements AS em
            WHERE em.space_id = p_space_id
              AND em.bucket_start >= p_from
              AND em.bucket_start <  p_to
              AND (CASE p_parameter
                       WHEN 'TEMPERATURE' THEN em.temperature_c
                       ELSE em.humidity_percent
                   END) IS NOT NULL
            GROUP BY date_bin(INTERVAL '1 hour', em.bucket_start, v_origin)
            ORDER BY 1;
        END IF;
        RETURN;
    END IF;

    -- DEW_POINT -- read the Phase 6 PERSISTED derived values. Never recompute.
    SELECT p.id INTO v_dew_point_param_id
    FROM config.parameters AS p
    WHERE p.code = 'DEW_POINT';

    IF p_resolution = 'raw' THEN
        RETURN QUERY
        SELECT
            d.bucket_start,
            d.numeric_value::DOUBLE PRECISION,
            d.quality_code,
            1::BIGINT
        FROM analytics.derived_parameter_values AS d
        WHERE d.space_id = p_space_id
          AND d.output_parameter_id = v_dew_point_param_id
          AND d.subject_type = 'SPACE'
          AND d.numeric_value IS NOT NULL
          AND d.bucket_start >= p_from
          AND d.bucket_start <  p_to
        ORDER BY d.bucket_start;
    ELSE
        RETURN QUERY
        SELECT
            date_bin(INTERVAL '1 hour', d.bucket_start, v_origin),
            avg(d.numeric_value)::DOUBLE PRECISION,
            NULL::SMALLINT,
            count(*)::BIGINT
        FROM analytics.derived_parameter_values AS d
        WHERE d.space_id = p_space_id
          AND d.output_parameter_id = v_dew_point_param_id
          AND d.subject_type = 'SPACE'
          AND d.numeric_value IS NOT NULL
          AND d.bucket_start >= p_from
          AND d.bucket_start <  p_to
        GROUP BY date_bin(INTERVAL '1 hour', d.bucket_start, v_origin)
        ORDER BY 1;
    END IF;
END;
$function$;

ALTER FUNCTION analytics.get_portal_space_measurement_series(BIGINT, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_space_measurement_series(BIGINT, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_space_measurement_series(BIGINT, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_space_measurement_series(BIGINT, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) IS
'Phase 7 (migration 231): portal-user-scoped environmental measurement series for one space. Parameters TEMPERATURE / HUMIDITY read telemetry.environment_measurements; DEW_POINT reads the Phase 6 persisted analytics.derived_parameter_values (subject_type SPACE) -- returned raw or hour-averaged, never recomputed. resolution in (raw, 1h). Tenant scope re-derived from p_portal_user_id via admin.portal_user_can_access_site; unknown space or no access -> zero rows. Closed input set; out-of-contract parameter/resolution/range raise SQLSTATE 22023 (API -> HTTP 422).';


-- ----------------------------------------------------------------------------
-- 3. analytics.get_portal_site_energy_consumption(...)
--    Portal-user-scoped site-level energy consumption roll-up (read only).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_energy_consumption
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_resolution     TEXT
)
RETURNS TABLE
(
    bucket_start           TIMESTAMPTZ,
    import_consumption_kwh  NUMERIC,
    export_consumption_kwh  NUMERIC,
    source_interval_count   BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin
AS $function$
BEGIN
    IF p_resolution IS NULL OR p_resolution NOT IN ('1h', '1d') THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_consumption: unsupported resolution %', p_resolution
            USING ERRCODE = '22023';
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_consumption: invalid time range (from must be < to)'
            USING ERRCODE = '22023';
    END IF;

    -- Server-side tenant scope. Unknown site or no access -> zero rows.
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    IF p_resolution = '1h' THEN
        RETURN QUERY
        SELECT
            h.bucket_start,
            sum(h.import_consumption_kwh),
            sum(h.export_consumption_kwh),
            sum(h.source_interval_count)::BIGINT
        FROM analytics.energy_consumption_hourly AS h
        WHERE h.site_id = p_site_id
          AND h.bucket_start >= p_from
          AND h.bucket_start <  p_to
        GROUP BY h.bucket_start
        ORDER BY h.bucket_start;
    ELSE
        RETURN QUERY
        SELECT
            d.bucket_start,
            sum(d.import_consumption_kwh),
            sum(d.export_consumption_kwh),
            sum(d.source_interval_count)::BIGINT
        FROM analytics.energy_consumption_daily AS d
        WHERE d.site_id = p_site_id
          AND d.bucket_start >= p_from
          AND d.bucket_start <  p_to
        GROUP BY d.bucket_start
        ORDER BY d.bucket_start;
    END IF;
END;
$function$;

ALTER FUNCTION analytics.get_portal_site_energy_consumption(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_energy_consumption(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_energy_consumption(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_site_energy_consumption(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) IS
'Phase 7 (migration 231): portal-user-scoped site-level energy consumption series. A pure per-bucket SUM roll-up of the mature persisted device historians analytics.energy_consumption_hourly (resolution 1h) / analytics.energy_consumption_daily (resolution 1d) -- no energy calculation, register arithmetic, gap/reset logic, or CAGG refresh; reads only, writes nothing. Tenant scope re-derived from p_portal_user_id via admin.portal_user_can_access_site; unknown site or no access -> zero rows.';


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig   TEXT;
    v_body  TEXT;
    v_count INT;
BEGIN
    -- (A) all three functions exist with the exact expected signatures.
    IF to_regprocedure('analytics.portal_user_can_access_space(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: analytics.portal_user_can_access_space(bigint, uuid) not created.';
    END IF;
    IF to_regprocedure('analytics.get_portal_space_measurement_series(bigint, uuid, text, timestamptz, timestamptz, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: analytics.get_portal_space_measurement_series(...) not created.';
    END IF;
    IF to_regprocedure('analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: analytics.get_portal_site_energy_consumption(...) not created.';
    END IF;

    -- (B) SECURITY DEFINER, STABLE, owner ems_admin, search_path pinned,
    --     EXECUTE granted to ems_app and NOT to PUBLIC / grafana_reader.
    FOR v_sig IN
        SELECT unnest(ARRAY[
            'analytics.portal_user_can_access_space(bigint, uuid)',
            'analytics.get_portal_space_measurement_series(bigint, uuid, text, timestamptz, timestamptz, text)',
            'analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)'
        ])
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_roles r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND p.prosecdef
              AND p.provolatile = 's'
              AND r.rolname = 'ems_admin'
              AND EXISTS (
                  SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) AS c
                  WHERE c LIKE 'search_path=%'
              )
        ) THEN
            RAISE EXCEPTION 'Migration 231 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
        END IF;

        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 231 postcondition failed: % is executable by PUBLIC.', v_sig;
        END IF;
        IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 231 postcondition failed: % is not executable by ems_app.', v_sig;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader')
           AND has_function_privilege('grafana_reader', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 231 postcondition failed: % is executable by grafana_reader.', v_sig;
        END IF;
    END LOOP;

    -- (C) NO recalculation of dew point, and NO energy-subsystem write path,
    --     in any of the three bodies.
    v_body := '';
    FOR v_sig IN
        SELECT unnest(ARRAY[
            'analytics.portal_user_can_access_space(bigint, uuid)',
            'analytics.get_portal_space_measurement_series(bigint, uuid, text, timestamptz, timestamptz, text)',
            'analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)'
        ])
    LOOP
        v_body := v_body || lower(pg_get_functiondef(v_sig::regprocedure)) || E'\n';
    END LOOP;

    IF position('v_space_dew_point_1min' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: a boundary function references analytics.v_space_dew_point_1min (dew point must be read from the persisted tier, not recomputed).';
    END IF;
    IF position('17.62' IN v_body) > 0 OR position('243.12' IN v_body) > 0 OR position('arden' IN v_body) > 0 OR position('magnus' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: a boundary function contains dew-point formula material.';
    END IF;
    IF position('energy_measurements' IN v_body) > 0
       OR position('normalized_points' IN v_body) > 0
       OR position('load_energy' IN v_body) > 0
       OR position('refresh_energy' IN v_body) > 0
       OR position('refresh_continuous_aggregate' IN v_body) > 0
       OR position('run_energy' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: a boundary function references an energy calculation / ingestion / refresh path.';
    END IF;
    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: a boundary function contains a write statement.';
    END IF;

    -- (D) this migration registered NO TimescaleDB job.
    SELECT count(*) INTO v_count FROM timescaledb_information.jobs
    WHERE proc_name LIKE '%portal_%' OR proc_name LIKE '%api_query_boundary%';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: an unexpected background job was registered.';
    END IF;

    -- (E) energy subsystem untouched: the persisted historians, their
    --     watermark jobs, and the Phase 6 objects are all still as before.
    IF to_regclass('analytics.energy_consumption_hourly') IS NULL
       OR to_regclass('analytics.energy_consumption_daily') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: a persisted energy historian disappeared.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name = 'run_energy_consumption_hourly_job' AND scheduled
    ) OR NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name = 'run_energy_consumption_daily_job' AND scheduled
    ) THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: an energy consumption watermark job is missing or was unscheduled.';
    END IF;
    IF to_regclass('analytics.derived_parameter_values') IS NULL THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: analytics.derived_parameter_values disappeared.';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader')
       AND has_table_privilege('grafana_reader', 'analytics.derived_parameter_values', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 231 postcondition failed: analytics.derived_parameter_values gained a grafana_reader grant.';
    END IF;

    RAISE NOTICE 'Migration 231: all postconditions passed (Phase 7 /api/v1 query boundary created; read-only; energy + Phase 6 untouched).';
END;
$post$;
