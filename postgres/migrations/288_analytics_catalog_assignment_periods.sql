-- ============================================================================
-- Migration 288
-- Analytics catalogue: historical assignment periods.
--
-- ADR-018 decisions 7/8: an asset keeps the history it accumulated while an
-- asset_points binding was open, and assignment changes never rewrite past
-- Analytics results. The Analytics series read already honours this -- it
-- resolves bindings against the REQUESTED range
-- (analytics.resolve_asset_energy_source_windows) and reports buckets
-- outside every binding as NOT_ASSIGNED / NO_DATA NOT_ASSIGNED_IN_RANGE --
-- but the catalogue and the availability read kept only bindings effective
-- at now(), so a closed assignment (e.g. Energy Export unassigned from an
-- asset) disappeared from Analytics entirely, history included, and the API
-- refused it as NOT_AVAILABLE.
--
-- Decision (product owner, 2026-10-05): a closed assignment stays in the
-- catalogue with its assignment period(s); the selector offers it only when
-- the selected range overlaps a period; data outside the periods stays
-- unavailable (existing NOT_ASSIGNED_IN_RANGE). No customer-facing "no longer
-- assigned" label.
--
-- Changes:
--   1. analytics.get_portal_analytics_catalog: the effective_range @> now()
--      filter is removed; every binding of an ACTIVE asset counts. One row
--      per asset x parameter x qualifier x assignment PERIOD, where the
--      periods are the union of that point's bindings (range_agg: a source
--      replacement at the same instant is one continuous period; separate
--      assignments stay separate). Two new columns, assigned_from and
--      assigned_to; an unbounded end (the parity-bridge '-infinity' start,
--      an open assignment) is NULL, never PostgreSQL infinity. All other
--      columns are unchanged; attribution_basis is CONFIRMED when any binding
--      of the point is CONFIRMED (internal only, never in the API). The
--      return type changes, so the function is dropped and recreated with
--      the same owner, grants, SECURITY DEFINER / STABLE / search_path.
--   2. analytics.get_portal_analytics_energy_availability: the same now()
--      filter is removed from the eligible-points CTE; the body is migration
--      286's byte for byte otherwise. Bounds were already computed across all
--      of a direction's binding windows (assignment-window clipping is
--      unchanged). Comment updated.
--
-- Unchanged: the series read, lifecycle rule (ACTIVE assets only), tenant
-- scoping, every other Analytics function.
--
-- Preconditions: both functions and the availability comment match the
-- deployed versions (md5; identical on the CI test database and staging);
-- the catalogue function has no dependent objects.
-- Rollback: re-apply migration 276's catalogue function (DROP + CREATE) and
-- migration 286's availability function and comment (migration 280's).
-- ============================================================================

DO $pre$
BEGIN
    IF md5(pg_get_functiondef('analytics.get_portal_analytics_catalog(bigint,uuid)'::regprocedure)) <> '586a533d408fdae936705f25dfd94f63' THEN
        RAISE EXCEPTION 'Migration 288 precondition failed: analytics.get_portal_analytics_catalog differs from migration 276''s definition.';
    END IF;
    IF md5(pg_get_functiondef('analytics.get_portal_analytics_energy_availability(bigint,uuid)'::regprocedure)) <> 'ab4e1d4d8c4ef1763f372c41541b96dd' THEN
        RAISE EXCEPTION 'Migration 288 precondition failed: analytics.get_portal_analytics_energy_availability differs from migration 286''s definition.';
    END IF;
    IF md5(obj_description('analytics.get_portal_analytics_energy_availability(bigint,uuid)'::regprocedure, 'pg_proc')) IS DISTINCT FROM 'bb352ba5380264118a27d102d7a1a70b' THEN
        RAISE EXCEPTION 'Migration 288 precondition failed: the availability function''s comment differs from migration 280''s.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_depend
        WHERE refobjid = 'analytics.get_portal_analytics_catalog(bigint,uuid)'::regprocedure
          AND deptype = 'n'
    ) THEN
        RAISE EXCEPTION 'Migration 288 precondition failed: an object depends on analytics.get_portal_analytics_catalog; review before dropping it.';
    END IF;
END;
$pre$;

-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_analytics_catalog -- assignment periods.
-- ----------------------------------------------------------------------------

DROP FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID);

CREATE FUNCTION analytics.get_portal_analytics_catalog
(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE
(
    asset_id          UUID,
    asset_name        TEXT,
    asset_type_id     UUID,
    asset_type_name   TEXT,
    building_name     TEXT,
    floor_name        TEXT,
    space_id          UUID,
    space_name        TEXT,
    location_path     TEXT,
    data_point        TEXT,
    data_point_name   TEXT,
    category          TEXT,
    unit              TEXT,
    qualifier         TEXT,
    attribution_basis TEXT,
    assigned_from     TIMESTAMPTZ,
    assigned_to       TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata, config
AS $function$
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH bindings AS (
        -- Every binding of an ACTIVE asset of the site -- current, closed or
        -- future -- to a semantic parameter (migration 288: no now() filter).
        SELECT
            la.asset_id        AS b_asset_id,
            la.asset_name      AS b_asset_name,
            la.asset_type_id   AS b_asset_type_id,
            la.asset_type_name AS b_asset_type_name,
            la.building_name   AS b_building_name,
            la.floor_name      AS b_floor_name,
            la.space_id        AS b_space_id,
            la.space_name      AS b_space_name,
            la.location_path   AS b_location_path,
            p.code::TEXT       AS b_data_point,
            p.name::TEXT       AS b_data_point_name,
            pc.name::TEXT      AS b_category,
            COALESCE(pu.symbol, lu.symbol)::TEXT AS b_unit,
            lp.qualifier::TEXT AS b_qualifier,
            ap.effective_from  AS b_effective_from,
            ap.effective_range AS b_effective_range
        FROM admin.list_accessible_assets(p_portal_user_id) AS la
        JOIN metadata.assets AS a
          ON a.id = la.asset_id
        JOIN metadata.asset_points AS ap
          ON ap.asset_id = a.id
         AND ap.organization_id = a.organization_id
        JOIN metadata.logical_points AS lp
          ON lp.id = ap.logical_point_id
        JOIN config.parameters AS p
          ON p.id = lp.parameter_id
        LEFT JOIN config.point_categories AS pc
          ON pc.id = p.parameter_category_id
        LEFT JOIN config.engineering_units AS pu
          ON pu.id = p.unit_id
        LEFT JOIN config.engineering_units AS lu
          ON lu.id = lp.unit_id
        WHERE la.site_id = p_site_id
          AND a.site_id = p_site_id
          AND a.lifecycle_status = 'ACTIVE'
    ),
    point_periods AS (
        -- One catalogue entry per asset x parameter x qualifier; its
        -- assignment periods are the union of its bindings (a replacement
        -- at the same instant is one continuous period). A parameter bound
        -- on two devices at once is one entry; CONFIRMED wins the internal
        -- classification.
        SELECT
            b.b_asset_id,
            b.b_data_point,
            b.b_qualifier,
            CASE WHEN bool_or(b.b_effective_from <> '-infinity'::timestamptz)
                 THEN 'CONFIRMED' ELSE 'PARITY_BRIDGE' END AS b_attribution_basis,
            range_agg(b.b_effective_range) AS b_periods
        FROM bindings AS b
        GROUP BY b.b_asset_id, b.b_data_point, b.b_qualifier
    ),
    descriptions AS (
        SELECT DISTINCT ON (b.b_asset_id, b.b_data_point, b.b_qualifier)
            b.b_asset_id, b.b_asset_name, b.b_asset_type_id, b.b_asset_type_name,
            b.b_building_name, b.b_floor_name, b.b_space_id, b.b_space_name,
            b.b_location_path, b.b_data_point, b.b_data_point_name, b.b_category,
            b.b_unit, b.b_qualifier
        FROM bindings AS b
        ORDER BY b.b_asset_id, b.b_data_point, b.b_qualifier,
                 (b.b_effective_from = '-infinity'::timestamptz), b.b_effective_from DESC
    )
    SELECT
        d.b_asset_id,
        d.b_asset_name,
        d.b_asset_type_id,
        d.b_asset_type_name,
        d.b_building_name,
        d.b_floor_name,
        d.b_space_id,
        d.b_space_name,
        d.b_location_path,
        d.b_data_point,
        d.b_data_point_name,
        d.b_category,
        d.b_unit,
        d.b_qualifier,
        pp.b_attribution_basis,
        -- Unbounded ends are NULL, never +/-infinity.
        CASE WHEN lower_inf(r.period) OR NOT isfinite(lower(r.period)) THEN NULL ELSE lower(r.period) END,
        CASE WHEN upper_inf(r.period) OR NOT isfinite(upper(r.period)) THEN NULL ELSE upper(r.period) END
    FROM point_periods AS pp
    JOIN descriptions AS d
      ON d.b_asset_id = pp.b_asset_id
     AND d.b_data_point = pp.b_data_point
     AND d.b_qualifier IS NOT DISTINCT FROM pp.b_qualifier
    CROSS JOIN LATERAL unnest(pp.b_periods) AS r(period)
    ORDER BY d.b_asset_id, d.b_data_point, d.b_qualifier, lower(r.period);
END;
$function$;

ALTER FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_analytics_catalog(BIGINT, UUID) IS
'Analytics v1 catalogue (migration 276; assignment periods since migration 288, ADR-018 decisions 7/8): one row per ACTIVE asset of the site x semantic parameter x qualifier x assignment period, from every metadata.asset_points binding (current, closed or future). assigned_from / assigned_to are the period''s bounds (the union of the point''s bindings); an unbounded end is NULL. Portal-scoped (portal_user_can_access_site + list_accessible_assets). attribution_basis (CONFIRMED | PARITY_BRIDGE; CONFIRMED when any binding is confirmed) is internal read-model metadata and is not exposed by the customer API. Read-only.';

-- ----------------------------------------------------------------------------
-- 2. analytics.get_portal_analytics_energy_availability -- every binding.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_portal_analytics_energy_availability
(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE
(
    asset_id       UUID,
    data_point     TEXT,
    available_from TIMESTAMPTZ,
    available_to   TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH directions (data_point, logical_point) AS (
        VALUES ('ENERGY_IMPORT', 'ENERGY_IMPORT_TOTAL'),
               ('ENERGY_EXPORT', 'ENERGY_EXPORT_TOTAL')
    ),
    eligible AS (
        SELECT DISTINCT a.id AS asset_id, a.organization_id, dir.data_point, dir.logical_point
        FROM metadata.assets AS a
        JOIN metadata.asset_points AS ap
          ON ap.asset_id = a.id
         AND ap.organization_id = a.organization_id
        JOIN metadata.logical_points AS lp
          ON lp.id = ap.logical_point_id
        JOIN directions AS dir
          ON dir.logical_point = lp.name
        WHERE a.site_id = p_site_id
          AND a.lifecycle_status = 'ACTIVE'
    ),
    windows AS (
        SELECT e.asset_id, e.organization_id, e.data_point, w.device_id, w.window_from, w.window_to
        FROM eligible AS e
        CROSS JOIN LATERAL analytics.resolve_asset_energy_source_windows(
            e.asset_id, e.logical_point, '-infinity'::timestamptz, 'infinity'::timestamptz
        ) AS w
    ),
    bounds AS MATERIALIZED (
        SELECT
            w.asset_id,
            w.data_point,
            GREATEST(w.window_from, first_day.day_start) AS window_available_from,
            LEAST(
                w.window_to,
                COALESCE(GREATEST(last_15m.bucket_end, last_raw.bucket_end), last_day.day_end)
            ) AS window_available_to
        FROM windows AS w
        LEFT JOIN LATERAL (
            SELECT d.bucket_start AS day_start
            FROM analytics.energy_consumption_daily AS d
            WHERE d.organization_id = w.organization_id
              AND d.device_id = w.device_id
              AND d.bucket_start < w.window_to
              AND (d.consumption_date + 1)::timestamp AT TIME ZONE d.site_timezone > w.window_from
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN d.import_consumption_kwh IS NOT NULL
                       ELSE d.export_consumption_kwh IS NOT NULL END
            ORDER BY d.bucket_start
            LIMIT 1
        ) AS first_day ON TRUE
        LEFT JOIN LATERAL (
            SELECT (d.consumption_date + 1)::timestamp AT TIME ZONE d.site_timezone AS day_end
            FROM analytics.energy_consumption_daily AS d
            WHERE d.organization_id = w.organization_id
              AND d.device_id = w.device_id
              AND d.bucket_start < w.window_to
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN d.import_consumption_kwh IS NOT NULL
                       ELSE d.export_consumption_kwh IS NOT NULL END
            ORDER BY d.bucket_start DESC
            LIMIT 1
        ) AS last_day ON TRUE
        LEFT JOIN LATERAL (
            SELECT q.bucket_start + INTERVAL '15 minutes' AS bucket_end
            FROM analytics.energy_consumption_15min AS q
            WHERE q.organization_id = w.organization_id
              AND q.device_id = w.device_id
              AND q.bucket_start < w.window_to
              AND q.bucket_start + INTERVAL '15 minutes' > w.window_from
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN q.import_consumption_kwh IS NOT NULL
                       ELSE q.export_consumption_kwh IS NOT NULL END
            ORDER BY q.bucket_start DESC
            LIMIT 1
        ) AS last_15m ON TRUE
        LEFT JOIN LATERAL (
            SELECT m.bucket_start + INTERVAL '1 minute' AS bucket_end
            FROM analytics.energy_consumption_1min AS m
            WHERE m.organization_id = w.organization_id
              AND m.device_id = w.device_id
              AND m.bucket_start < w.window_to
              AND m.bucket_start + INTERVAL '1 minute' > w.window_from
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN m.import_consumption_kwh IS NOT NULL
                       ELSE m.export_consumption_kwh IS NOT NULL END
            ORDER BY m.bucket_start DESC
            LIMIT 1
        ) AS last_raw ON TRUE
        WHERE first_day.day_start IS NOT NULL
    )
    SELECT
        e.asset_id,
        e.data_point,
        MIN(b.window_available_from),
        MAX(b.window_available_to)
    FROM eligible AS e
    LEFT JOIN bounds AS b
      ON b.asset_id = e.asset_id
     AND b.data_point = e.data_point
     AND b.window_available_to > b.window_available_from
    GROUP BY e.asset_id, e.data_point;
END;
$function$;

COMMENT ON FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) IS
'Analytics v1 Energy availability (migration 277, aligned with the persisted-tier read by migration 280; every binding since migration 288): per ACTIVE asset of the site and Energy direction with any asset_points binding (current, closed or future), the earliest persisted daily day and the latest persisted-15m or raw-1m bucket end across all of the direction''s asset_points windows, each clipped to its window. NULL bounds = no data yet. Portal-scoped; read-only.';

-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_cat   TEXT := 'analytics.get_portal_analytics_catalog(bigint, uuid)';
    v_av    TEXT := 'analytics.get_portal_analytics_energy_availability(bigint, uuid)';
    v_body  TEXT;
    v_def   TEXT;
BEGIN
    FOREACH v_body IN ARRAY ARRAY[v_cat, v_av] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
            WHERE p.oid = v_body::regprocedure
              AND p.prosecdef AND p.provolatile = 's' AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 288 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_body;
        END IF;
        IF has_function_privilege('public', v_body, 'EXECUTE')
           OR has_function_privilege('grafana_reader', v_body, 'EXECUTE')
           OR NOT has_function_privilege('ems_app', v_body, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 288 postcondition failed: % must be executable by ems_app only.', v_body;
        END IF;
    END LOOP;

    -- Catalogue: the two period columns exist; no now() filter; 276's
    -- read-only / asset_points-only / portal-scoped / ACTIVE-only rules hold.
    IF (SELECT pg_get_function_result(v_cat::regprocedure)) NOT LIKE '%assigned_from timestamp with time zone, assigned_to timestamp with time zone)' THEN
        RAISE EXCEPTION 'Migration 288 postcondition failed: the catalogue does not return assigned_from / assigned_to.';
    END IF;
    v_def := lower(pg_get_functiondef(v_cat::regprocedure));
    IF position('effective_range @> now()' IN v_def) > 0 THEN
        RAISE EXCEPTION 'Migration 288 postcondition failed: the catalogue still filters bindings to now().';
    END IF;
    IF position('insert into' IN v_def) > 0 OR position('update ' IN v_def) > 0 OR position('delete from' IN v_def) > 0
       OR position(' merge ' IN v_def) > 0 OR position('execute ' IN v_def) > 0 OR position('format(' IN v_def) > 0 THEN
        RAISE EXCEPTION 'Migration 288 postcondition failed: the catalogue contains a write statement or dynamic SQL.';
    END IF;
    IF position('primary_meter' IN v_def) > 0 OR position('asset_devices' IN v_def) > 0
       OR position('device_point_configuration' IN v_def) > 0 OR position('v_grafana_asset_point_selector' IN v_def) > 0 THEN
        RAISE EXCEPTION 'Migration 288 postcondition failed: the catalogue must derive availability from metadata.asset_points only (ADR-018 decision 1).';
    END IF;
    IF position('portal_user_can_access_site' IN v_def) = 0 OR position('list_accessible_assets' IN v_def) = 0
       OR position('lifecycle_status = ''active''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 288 postcondition failed: the catalogue must be portal-scoped and ACTIVE-only.';
    END IF;

    -- Availability: re-inserting the removed filter line reproduces migration
    -- 286's definition exactly.
    v_def := pg_get_functiondef(v_av::regprocedure);
    IF md5(replace(v_def,
            E'AND ap.organization_id = a.organization_id\n        JOIN metadata.logical_points AS lp',
            E'AND ap.organization_id = a.organization_id\n         AND ap.effective_range @> now()\n        JOIN metadata.logical_points AS lp'))
       <> 'ab4e1d4d8c4ef1763f372c41541b96dd' THEN
        RAISE EXCEPTION 'Migration 288 postcondition failed: the availability function changed beyond the removed now() filter.';
    END IF;
    IF position('bounds AS MATERIALIZED (' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 288 postcondition failed: migration 286''s materialized bounds were lost.';
    END IF;

    RAISE NOTICE 'Migration 288: all postconditions passed (catalogue lists every binding with assigned_from/assigned_to, unbounded ends NULL; availability counts every binding, otherwise identical to migration 286; owners and grants unchanged).';
END;
$post$;
