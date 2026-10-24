-- ============================================================================
-- Migration 312
-- Reports: asset selection and a device-keyed 1-minute read for the site
-- measurement export (EMS Web App "Reports" tab, migration 309).
--
-- WHY
--   The Reports export must serve 1-minute data for up to 14 days. A site
--   export is now limited to a selection of assets (at most 10, enforced by
--   the API), and the job must remember the selection: a background job runs
--   later, in the worker.
--
--   At 1 minute every measurement column is read from
--   telemetry.normalized_points. The generic Analytics read
--   (analytics.get_portal_asset_point_series, migrations 292 / 293) probes
--   that table once per (asset, point) on the (logical_point_id, time) index,
--   which on the uncompressed chunk visits the point's rows of EVERY device:
--   measured on staging 2026-10-24, 9 points x 1 day did not finish in 90 s
--   (the Analytics docs record ~35 s per series-day). An asset's points come
--   from one or a few devices, so reading each device once on the existing
--   (device_id, event_time) index serves every point of the asset at once:
--   one Coimbatore meter, all 58 points x 14 days, 1.17 M minute values in
--   2.9 s. No index is added (the normalized_points identity-index decision,
--   draft migration 296, is unchanged).
--
-- OBJECTS
--   1. analytics.report_export_jobs.asset_ids UUID[] -- the selected assets
--      of a job. NULL = every asset of the site (jobs queued before 312).
--   2. analytics.create_portal_report_export_job(..., p_asset_ids UUID[]) --
--      the 309 create plus the selection; no row unless every selected
--      asset is an accessible asset of the site. The 309 signature is kept
--      unchanged for the container still running during a deployment.
--   3. analytics.get_portal_asset_measurements_1m -- every requested
--      measurement point of ONE asset at 1 minute, one row per minute with
--      data, wide: series_indexes INTEGER[] (1-based positions in
--      p_parameters / p_qualifiers) and vals DOUBLE PRECISION[] (parallel).
--      The first row (bucket_start NULL) lists in series_indexes the
--      requested points that are register (delta) points: they have no
--      1-minute source and are not 1-minute columns.
--
-- VALUE RULES (identical to get_portal_asset_point_series at 1m)
--   value = mean of the GOOD samples of the minute (date_bin 1 minute,
--   origin 2000-01-01 UTC), converted with the field-mapping scale / offset
--   (analytics.analytics_point_source_scale), counting only samples inside
--   an effective metadata.asset_points window of the asset; the logical
--   point is the first logical point of (parameter code, qualifier). When the
--   site capture policy cannot serve 1 minute (policy gap, change or a
--   capture interval other than 60 s) or the range starts before the 1m
--   retention floor, no values are returned (the export leaves the columns
--   empty, as the Analytics read reports them unavailable). Portal-scoped
--   exactly like the Analytics reads: admin.portal_user_can_access_site,
--   admin.list_accessible_assets, ACTIVE asset of the site and organization;
--   nothing for anything else. Read-only; never Grafana-keyed.
--
-- Bounded: at most 15 days per call (the API allows 14) and 200 points.
-- No telemetry, metadata, configuration, job, Analytics read or data change.
--
-- Rollback: DROP FUNCTION analytics.get_portal_asset_measurements_1m(BIGINT,
-- UUID, UUID, TEXT[], TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ); DROP
-- FUNCTION analytics.create_portal_report_export_job(BIGINT, UUID,
-- TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, INTEGER, UUID[]); ALTER TABLE
-- analytics.report_export_jobs DROP COLUMN asset_ids (deploy the previous
-- application image first).
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('analytics.report_export_jobs') IS NULL THEN
        RAISE EXCEPTION 'Migration 312 precondition failed: analytics.report_export_jobs (migration 309) is missing.';
    END IF;
    IF to_regprocedure('analytics.analytics_point_source_scale(uuid, uuid)') IS NULL
       OR to_regprocedure('analytics.get_analytics_point_resolution_floors(timestamptz)') IS NULL
       OR to_regprocedure('telemetry.resolve_site_capture_bucket(uuid, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 312 precondition failed: a migration 292 helper or the capture-policy resolver is missing.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'report_export_jobs' AND column_name = 'asset_ids'
    ) THEN
        RAISE EXCEPTION 'Migration 312 precondition failed: analytics.report_export_jobs.asset_ids already exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. The selected assets of a job.
-- ----------------------------------------------------------------------------

ALTER TABLE analytics.report_export_jobs
    ADD COLUMN asset_ids UUID[],
    ADD CONSTRAINT report_export_jobs_asset_ids_chk
        CHECK (asset_ids IS NULL OR (cardinality(asset_ids) >= 1 AND array_position(asset_ids, NULL) IS NULL));

COMMENT ON COLUMN analytics.report_export_jobs.asset_ids IS
'Migration 312: the assets selected for the export (the API allows at most 10). NULL = every asset of the site (jobs queued before migration 312).';


-- ----------------------------------------------------------------------------
-- 2. Queue a job for selected assets.
-- ----------------------------------------------------------------------------

-- The 309 create, plus p_asset_ids. No row when the site, or any selected
-- asset, is not accessible to the user (indistinguishable from a missing
-- one). SQLSTATE 54000 when the owner already has p_max_active QUEUED /
-- PROCESSING jobs.
CREATE OR REPLACE FUNCTION analytics.create_portal_report_export_job(
    p_portal_user_id       BIGINT,
    p_site_id              UUID,
    p_range_from           TIMESTAMPTZ,
    p_range_to             TIMESTAMPTZ,
    p_requested_resolution TEXT,
    p_resolution           TEXT,
    p_max_active           INTEGER,
    p_asset_ids            UUID[]
)
RETURNS SETOF analytics.report_export_jobs
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
DECLARE
    v_active INTEGER;
    v_assets UUID[];
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    SELECT array_agg(DISTINCT u.id ORDER BY u.id) INTO v_assets
    FROM unnest(p_asset_ids) AS u(id);
    IF v_assets IS NULL OR array_position(v_assets, NULL) IS NOT NULL OR EXISTS (
        SELECT 1 FROM unnest(v_assets) AS u(id)
        WHERE NOT EXISTS (
            SELECT 1
            FROM admin.list_accessible_assets(p_portal_user_id) AS la
            JOIN metadata.assets AS a ON a.id = la.asset_id
            JOIN metadata.sites AS s ON s.id = p_site_id
            WHERE la.asset_id = u.id
              AND la.site_id = p_site_id
              AND a.site_id = p_site_id
              AND a.organization_id = s.organization_id
              AND a.lifecycle_status = 'ACTIVE'
        )
    ) THEN
        RETURN;
    END IF;

    -- One owner's concurrent creates serialise on this lock, so the active
    -- job limit cannot be raced past (the 309 lock key).
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.report_export_jobs:' || p_portal_user_id::TEXT, 0));
    SELECT count(*) INTO v_active
    FROM analytics.report_export_jobs
    WHERE portal_user_id = p_portal_user_id AND status IN ('QUEUED', 'PROCESSING');
    IF v_active >= p_max_active THEN
        RAISE EXCEPTION 'report_export_active_limit' USING ERRCODE = '54000';
    END IF;

    RETURN QUERY
    INSERT INTO analytics.report_export_jobs (
        portal_user_id, site_id, range_from, range_to, requested_resolution, resolution, asset_ids
    )
    VALUES (p_portal_user_id, p_site_id, p_range_from, p_range_to, p_requested_resolution, p_resolution, v_assets)
    RETURNING *;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 3. One asset's measurements at 1 minute, read per device.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_portal_asset_measurements_1m
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_asset_id       UUID,
    p_parameters     TEXT[],
    p_qualifiers     TEXT[],
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_as_of          TIMESTAMPTZ
)
RETURNS TABLE
(
    bucket_start   TIMESTAMPTZ,
    series_indexes INTEGER[],
    vals           DOUBLE PRECISION[]
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata, telemetry, config
AS $function$
DECLARE
    c_origin     CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    c_minute     CONSTANT INTERVAL := INTERVAL '1 minute';
    c_max_window CONSTANT INTERVAL := INTERVAL '15 days';
    c_max_points CONSTANT INTEGER := 200;
    v_now          TIMESTAMPTZ;
    v_org          UUID;
    v_grid_from    TIMESTAMPTZ;
    v_grid_to      TIMESTAMPTZ;
    v_policy_from  TIMESTAMPTZ;
    v_capture      INTEGER;
    v_capture_n    INTEGER;
    v_policy_gap   BOOLEAN;
    v_floor        TIMESTAMPTZ;
    v_i            INTEGER;
    v_point        UUID;
    v_idx          INTEGER[] := ARRAY[]::INTEGER[];
    v_points       UUID[] := ARRAY[]::UUID[];
    v_delta        INTEGER[] := ARRAY[]::INTEGER[];
BEGIN
    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RAISE EXCEPTION 'p_from and p_to are required and p_to must be later than p_from'
            USING ERRCODE = '22023';
    END IF;
    IF p_to - p_from > c_max_window THEN
        RAISE EXCEPTION 'the 1-minute export read covers at most %', c_max_window
            USING ERRCODE = '22023';
    END IF;
    IF p_parameters IS NULL OR p_qualifiers IS NULL
       OR cardinality(p_parameters) <> cardinality(p_qualifiers)
       OR cardinality(p_parameters) > c_max_points THEN
        RAISE EXCEPTION 'p_parameters and p_qualifiers must be parallel arrays of at most % points', c_max_points
            USING ERRCODE = '22023';
    END IF;
    v_now := COALESCE(p_as_of, now());

    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;
    SELECT s.organization_id INTO v_org FROM metadata.sites AS s WHERE s.id = p_site_id;
    IF NOT EXISTS (
        SELECT 1
        FROM admin.list_accessible_assets(p_portal_user_id) AS la
        JOIN metadata.assets AS a ON a.id = la.asset_id
        WHERE la.asset_id = p_asset_id
          AND la.site_id = p_site_id
          AND a.site_id = p_site_id
          AND a.organization_id = v_org
          AND a.lifecycle_status = 'ACTIVE'
    ) THEN
        RETURN;
    END IF;

    -- 1-minute grid. Every site-local minute boundary is a UTC minute
    -- boundary (whole-minute offsets), so this is the Analytics 1m grid.
    v_grid_from := date_bin(c_minute, p_from, c_origin);
    v_grid_to   := date_bin(c_minute, p_to, c_origin);
    IF v_grid_to < p_to THEN
        v_grid_to := v_grid_to + c_minute;
    END IF;

    -- Points: the logical point of each (code, qualifier); register (delta)
    -- points have no 1-minute source (get_portal_asset_point_series raises
    -- for them at 1m) and are reported in the first row instead.
    FOR v_i IN 1 .. COALESCE(cardinality(p_parameters), 0) LOOP
        SELECT lp.id INTO v_point
        FROM metadata.logical_points AS lp
        JOIN config.parameters AS p ON p.id = lp.parameter_id
        WHERE p.code = p_parameters[v_i]
          AND lp.qualifier::TEXT IS NOT DISTINCT FROM p_qualifiers[v_i]
        ORDER BY lp.id
        LIMIT 1;
        CONTINUE WHEN v_point IS NULL;

        IF EXISTS (
            SELECT 1 FROM metadata.asset_points AS ap
            JOIN metadata.devices AS d ON d.id = ap.device_id
            JOIN config.energy_register_semantics AS ers
              ON ers.profile_id = d.profile_id AND ers.logical_point_id = ap.logical_point_id
             AND ers.is_active
            WHERE ap.asset_id = p_asset_id AND ap.logical_point_id = v_point
        ) THEN
            v_delta := v_delta || v_i;
        ELSE
            v_idx := v_idx || v_i;
            v_points := v_points || v_point;
        END IF;
    END LOOP;

    RETURN QUERY SELECT NULL::TIMESTAMPTZ, v_delta, NULL::DOUBLE PRECISION[];

    IF cardinality(v_idx) = 0 THEN
        RETURN;
    END IF;

    -- Capture-policy gating: get_portal_asset_point_series (migration 293).
    SELECT MIN(p.effective_from) INTO v_policy_from
    FROM config.telemetry_capture_policies AS p
    WHERE p.is_enabled AND (p.site_id = p_site_id OR p.site_id IS NULL);

    IF v_policy_from IS NOT NULL AND v_grid_to > v_policy_from THEN
        SELECT COUNT(DISTINCT b.capture_interval_seconds),
               MIN(b.capture_interval_seconds),
               bool_or(b.policy_id IS NULL)
        INTO v_capture_n, v_capture, v_policy_gap
        FROM (
            SELECT GREATEST(v_grid_from, v_policy_from) AS t
            UNION
            SELECT p.effective_from FROM config.telemetry_capture_policies AS p
            WHERE p.is_enabled AND (p.site_id = p_site_id OR p.site_id IS NULL)
              AND p.effective_from > GREATEST(v_grid_from, v_policy_from) AND p.effective_from < v_grid_to
            UNION
            SELECT p.effective_to FROM config.telemetry_capture_policies AS p
            WHERE p.is_enabled AND (p.site_id = p_site_id OR p.site_id IS NULL)
              AND p.effective_to IS NOT NULL
              AND p.effective_to > GREATEST(v_grid_from, v_policy_from) AND p.effective_to < v_grid_to
        ) AS candidates
        CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(p_site_id, candidates.t) AS b;

        IF v_policy_gap OR v_capture_n <> 1 OR v_capture <> 60 THEN
            RETURN;
        END IF;
    END IF;

    SELECT f.earliest_available INTO v_floor
    FROM analytics.get_analytics_point_resolution_floors(v_now) AS f
    WHERE f.source_kind = 'mean' AND f.resolution = '1m';
    IF v_floor IS NOT NULL AND v_grid_from < v_floor THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH points AS (
        SELECT u.idx, u.point
        FROM unnest(v_idx, v_points) AS u(idx, point)
    ),
    windows AS MATERIALIZED (
        SELECT pt.idx,
               ap.device_id AS w_device,
               ap.logical_point_id AS w_point,
               GREATEST(ap.effective_from, v_grid_from) AS w_from,
               LEAST(COALESCE(ap.effective_to, 'infinity'::TIMESTAMPTZ), v_grid_to) AS w_to,
               sc.scale AS w_scale,
               sc.value_offset AS w_offset
        FROM points AS pt
        JOIN metadata.asset_points AS ap
          ON ap.asset_id = p_asset_id AND ap.logical_point_id = pt.point
        CROSS JOIN LATERAL analytics.analytics_point_source_scale(ap.device_id, ap.logical_point_id) AS sc
        WHERE ap.effective_from < v_grid_to
          AND (ap.effective_to IS NULL OR ap.effective_to > v_grid_from)
    ),
    devices AS MATERIALIZED (
        SELECT w.w_device AS d_device,
               MIN(w.w_from) AS d_from,
               MAX(w.w_to) AS d_to,
               array_agg(DISTINCT w.w_point) AS d_points
        FROM windows AS w
        GROUP BY w.w_device
    ),
    -- One range scan per DEVICE on (device_id, event_time); the fence keeps
    -- the planner from flattening the probe into a join over every chunk
    -- (the migration 293 lesson).
    samples AS (
        SELECT w.idx,
               date_bin(c_minute, x.t, c_origin) AS s_bucket,
               CASE WHEN x.good THEN x.v * w.w_scale + w.w_offset END AS s_value
        FROM devices AS d
        CROSS JOIN LATERAL (
            SELECT np.logical_point_id AS point, np.event_time AS t, np.numeric_value AS v,
                   np.quality_code = 'GOOD' AS good
            FROM telemetry.normalized_points AS np
            WHERE np.device_id = d.d_device
              AND np.event_time >= d.d_from
              AND np.event_time < d.d_to
              AND np.logical_point_id = ANY (d.d_points)
              AND np.numeric_value IS NOT NULL
            OFFSET 0   -- planner fence (migration 312)
        ) AS x
        JOIN windows AS w
          ON w.w_device = d.d_device
         AND w.w_point = x.point
         AND x.t >= w.w_from
         AND x.t < w.w_to
    ),
    minute_values AS (
        SELECT s.s_bucket, s.idx, AVG(s.s_value)::DOUBLE PRECISION AS value
        FROM samples AS s
        GROUP BY s.s_bucket, s.idx
        HAVING COUNT(s.s_value) > 0
    )
    SELECT mv.s_bucket,
           array_agg(mv.idx ORDER BY mv.idx),
           array_agg(mv.value ORDER BY mv.idx)
    FROM minute_values AS mv
    GROUP BY mv.s_bucket
    ORDER BY mv.s_bucket;
END;
$function$;


-- ----------------------------------------------------------------------------
-- 4. Ownership and grants: ems_app EXECUTE only.
-- ----------------------------------------------------------------------------

DO $grants$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.create_portal_report_export_job(bigint, uuid, timestamptz, timestamptz, text, text, integer, uuid[])',
        'analytics.get_portal_asset_measurements_1m(bigint, uuid, uuid, text[], text[], timestamptz, timestamptz, timestamptz)'
    ] LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ems_admin', v_sig);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO ems_app', v_sig);
    END LOOP;
END;
$grants$;

COMMENT ON FUNCTION analytics.create_portal_report_export_job(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, INTEGER, UUID[]) IS
'Migration 312 (Reports tab): queues a background export job for the selected assets of a site. No row when the site, or any selected asset, is not an accessible ACTIVE asset of the site for the user; SQLSTATE 54000 (report_export_active_limit) when the user already has p_max_active QUEUED/PROCESSING jobs.';
COMMENT ON FUNCTION analytics.get_portal_asset_measurements_1m(BIGINT, UUID, UUID, TEXT[], TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ) IS
'Migration 312 (Reports tab): every requested measurement point of one asset at 1 minute, read once per bound device on telemetry.normalized_points (device_id, event_time). One row per minute with data: series_indexes (1-based positions in p_parameters / p_qualifiers) and vals (parallel); the first row (bucket_start NULL) lists the requested register (delta) points, which have no 1-minute source. Values follow analytics.get_portal_asset_point_series at 1m: mean of the GOOD samples, field-mapping scale / offset, only inside effective asset_points windows; nothing when the capture policy cannot serve 1 minute or the range starts before the 1m retention floor. Portal-scoped (portal_user_can_access_site + list_accessible_assets, ACTIVE asset of the site and organization). At most 15 days and 200 points per call. Read-only.';


-- ----------------------------------------------------------------------------
-- 5. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.create_portal_report_export_job(bigint, uuid, timestamptz, timestamptz, text, text, integer)',
        'analytics.create_portal_report_export_job(bigint, uuid, timestamptz, timestamptz, text, text, integer, uuid[])',
        'analytics.get_portal_asset_measurements_1m(bigint, uuid, uuid, text[], text[], timestamptz, timestamptz, timestamptz)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND p.prosecdef AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 312 postcondition failed: % is not SECURITY DEFINER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE')
           OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 312 postcondition failed: % grants are not ems_app-only.', v_sig;
        END IF;
    END LOOP;

    IF (SELECT provolatile FROM pg_proc
        WHERE oid = 'analytics.get_portal_asset_measurements_1m(bigint, uuid, uuid, text[], text[], timestamptz, timestamptz, timestamptz)'::regprocedure) <> 's' THEN
        RAISE EXCEPTION 'Migration 312 postcondition failed: get_portal_asset_measurements_1m is not STABLE.';
    END IF;

    IF has_table_privilege('ems_app', 'analytics.report_export_jobs', 'SELECT')
       OR has_table_privilege('grafana_reader', 'analytics.report_export_jobs', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 312 postcondition failed: analytics.report_export_jobs is directly readable.';
    END IF;

    RAISE NOTICE 'Migration 312: all postconditions passed (asset selection column, create with assets, 1-minute measurements read; SECURITY DEFINER, ems_app-only).';
END;
$post$;
