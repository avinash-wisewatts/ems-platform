-- 019_asset_dashboard_consolidated_read_path_fix.sql
-- Consolidated production fix for the Asset Dashboard read path.
--
-- Goals:
--   1. Automatic ASSET demand must never depend on SITE demand enablement and
--      the dashboard must not surface the obsolete NOT_CONFIGURED state when
--      the platform-managed ASSET policy should exist.
--   2. Current-demand and telemetry cards must always return an explicit state,
--      rather than a blank Grafana panel.
--   3. Asset energy KPI/trend/performance queries must be parameterized by
--      Grafana organization, asset and time range before cumulative-register
--      delta work is performed. Do not execute tenant-wide 1/5/15-minute
--      register-delta views on every dashboard refresh.
--   4. Keep config internals private. All dashboard functions below are
--      SECURITY DEFINER with fixed search paths and expose only approved data.

-- ---------------------------------------------------------------------------
-- 1. Defensive repair/backfill of the system-managed ASSET demand policy.
--    Migration 017 already installs the same future-site trigger. This backfill
--    makes the read contract self-healing for any site that pre-dates or missed
--    that seed.
-- ---------------------------------------------------------------------------

INSERT INTO config.site_demand_policies (
    site_id,
    policy_scope,
    is_enabled,
    demand_interval_seconds,
    demand_basis,
    site_demand_source_role,
    alignment_mode,
    minimum_coverage_percent,
    late_arrival_tolerance_seconds,
    effective_from,
    effective_to
)
SELECT
    s.id,
    'ASSET',
    TRUE,
    900,
    'ACTIVE_POWER_KW',
    NULL,
    'WALL_CLOCK',
    90.00,
    30,
    TIMESTAMPTZ '2000-01-01 00:00:00+00',
    NULL
FROM metadata.sites AS s
WHERE COALESCE(s.lifecycle_status, 'ACTIVE') <> 'DECOMMISSIONED'
  AND NOT EXISTS (
      SELECT 1
      FROM config.site_demand_policies AS p
      WHERE p.site_id = s.id
        AND p.policy_scope = 'ASSET'
        AND p.effective_to IS NULL
  );

-- ---------------------------------------------------------------------------
-- 2. Device/time index for fast parameterized asset-energy reads.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS energy_measurements_device_bucket_start_idx
ON telemetry.energy_measurements (device_id, bucket_start DESC);

-- ---------------------------------------------------------------------------
-- 3. Fast, explicit telemetry context for one asset.
--    The card reports the PRIMARY_METER when present, otherwise the first
--    assigned device. It always returns a state for a valid tenant asset.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_grafana_asset_telemetry_context(
    p_grafana_org_id BIGINT,
    p_asset_id UUID,
    p_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE (
    asset_id UUID,
    asset_name TEXT,
    site_id UUID,
    source_device_id UUID,
    source_device_name TEXT,
    relationship_type TEXT,
    telemetry_state TEXT,
    latest_received_timestamp TIMESTAMPTZ,
    latest_valid_source_timestamp TIMESTAMPTZ,
    latest_valid_received_timestamp TIMESTAMPTZ,
    age_seconds DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, config, metadata, telemetry
AS $function$
DECLARE
    v_asset_name TEXT;
    v_site_id UUID;
    v_device_id UUID;
    v_device_name TEXT;
    v_relationship_type TEXT;
    v_latest_received TIMESTAMPTZ;
    v_latest_valid_source TIMESTAMPTZ;
    v_latest_valid_received TIMESTAMPTZ;
    v_receiving_seconds INTEGER := 180;
    v_stale_seconds INTEGER := 900;
    v_silent_seconds INTEGER := 1800;
    v_state TEXT;
BEGIN
    SELECT a.name, a.site_id
      INTO v_asset_name, v_site_id
    FROM metadata.grafana_organization_map AS gom
    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id
    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id
    LIMIT 1;

    IF v_site_id IS NULL THEN
        RETURN;
    END IF;

    SELECT ad.device_id, d.name, ad.relationship_type
      INTO v_device_id, v_device_name, v_relationship_type
    FROM metadata.asset_devices AS ad
    JOIN metadata.devices AS d
      ON d.id = ad.device_id
    WHERE ad.asset_id = p_asset_id
    ORDER BY
        CASE WHEN ad.relationship_type = 'PRIMARY_METER' THEN 0 ELSE 1 END,
        ad.device_id
    LIMIT 1;

    IF v_device_id IS NULL THEN
        RETURN QUERY SELECT
            p_asset_id,
            v_asset_name,
            v_site_id,
            NULL::UUID,
            NULL::TEXT,
            NULL::TEXT,
            'NO_ASSIGNED_DEVICE'::TEXT,
            NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ,
            NULL::DOUBLE PRECISION;
        RETURN;
    END IF;

    SELECT
        COALESCE(p.receiving_threshold_seconds, v_receiving_seconds),
        COALESCE(p.stale_threshold_seconds, v_stale_seconds),
        COALESCE(p.silent_threshold_seconds, v_silent_seconds)
      INTO v_receiving_seconds, v_stale_seconds, v_silent_seconds
    FROM config.telemetry_availability_policy AS p
    WHERE p.policy_key = 'DEFAULT'
    LIMIT 1;

    SELECT
        ts.latest_received_timestamp,
        ts.latest_valid_source_timestamp,
        ts.latest_valid_received_timestamp
      INTO
        v_latest_received,
        v_latest_valid_source,
        v_latest_valid_received
    FROM telemetry.device_telemetry_state AS ts
    WHERE ts.device_id = v_device_id;

    v_state := CASE
        WHEN v_latest_received IS NULL THEN 'NEVER_SEEN'
        WHEN v_latest_received < p_at - make_interval(secs => v_silent_seconds)
            THEN 'SILENT'
        WHEN v_latest_valid_source IS NULL
            THEN 'RECEIVING'
        WHEN v_latest_valid_source < p_at - make_interval(secs => v_stale_seconds)
            THEN 'STALE'
        WHEN v_latest_valid_received >= p_at - make_interval(secs => v_receiving_seconds)
            THEN 'VALIDATED'
        ELSE 'RECEIVING'
    END;

    RETURN QUERY SELECT
        p_asset_id,
        v_asset_name,
        v_site_id,
        v_device_id,
        v_device_name,
        v_relationship_type,
        v_state,
        v_latest_received,
        v_latest_valid_source,
        v_latest_valid_received,
        CASE
            WHEN v_latest_received IS NULL THEN NULL::DOUBLE PRECISION
            ELSE extract(epoch FROM (p_at - v_latest_received))::DOUBLE PRECISION
        END;
END;
$function$;

COMMENT ON FUNCTION analytics.get_grafana_asset_telemetry_context(BIGINT,UUID,TIMESTAMPTZ) IS
'Fast tenant-safe telemetry state for one asset. Uses compact device_telemetry_state and returns an explicit state even when the asset has no assigned device or has never been seen.';

-- ---------------------------------------------------------------------------
-- 4. Fast demand summary for one asset.
--    The ASSET policy is platform-managed; SITE demand monitoring is irrelevant
--    to this function. A NULL current value is retained when the current window
--    genuinely has no usable data, while display_status explains why.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_grafana_asset_demand_summary(
    p_grafana_org_id BIGINT,
    p_asset_id UUID,
    p_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE (
    asset_id UUID,
    asset_name TEXT,
    site_id UUID,
    demand_policy_id UUID,
    demand_monitoring_enabled BOOLEAN,
    demand_interval_seconds INTEGER,
    demand_basis TEXT,
    demand_unit TEXT,
    source_device_id UUID,
    source_device_name TEXT,
    source_profile_code TEXT,
    selected_method TEXT,
    capability_ready BOOLEAN,
    readiness_status TEXT,
    current_interval_start TIMESTAMPTZ,
    current_interval_end TIMESTAMPTZ,
    current_demand_value DOUBLE PRECISION,
    current_demand_kw DOUBLE PRECISION,
    coverage_percent NUMERIC(5,2),
    quality_status TEXT,
    display_status TEXT,
    updated_at TIMESTAMPTZ,
    latest_valid_demand_kw DOUBLE PRECISION,
    latest_valid_interval_end TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, config, metadata
AS $function$
DECLARE
    v_asset_name TEXT;
    v_site_id UUID;
    v_cap RECORD;
    v_state RECORD;
    v_last RECORD;
    v_display TEXT;
BEGIN
    SELECT a.name, a.site_id
      INTO v_asset_name, v_site_id
    FROM metadata.grafana_organization_map AS gom
    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id
    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id
    LIMIT 1;

    IF v_site_id IS NULL THEN
        RETURN;
    END IF;

    SELECT *
      INTO v_cap
    FROM analytics.resolve_demand_capability(
        v_site_id,
        'ASSET',
        p_asset_id,
        p_at
    );

    IF v_cap.demand_policy_id IS NOT NULL THEN
        SELECT
            ds.interval_start,
            ds.interval_end,
            ds.current_demand_kw,
            ds.current_demand_kva,
            ds.coverage_percent,
            ds.quality_status,
            ds.updated_at
          INTO v_state
        FROM analytics.demand_state AS ds
        WHERE ds.site_id = v_site_id
          AND ds.scope_type = 'ASSET'
          AND ds.asset_id = p_asset_id
          AND ds.demand_policy_id = v_cap.demand_policy_id
        LIMIT 1;

        SELECT
            di.demand_kw,
            di.interval_end
          INTO v_last
        FROM analytics.demand_intervals AS di
        WHERE di.site_id = v_site_id
          AND di.scope_type = 'ASSET'
          AND di.asset_id = p_asset_id
          AND di.demand_policy_id = v_cap.demand_policy_id
          AND di.quality_status = 'VALID'
          AND di.demand_kw IS NOT NULL
          AND di.interval_end <= p_at
        ORDER BY di.interval_end DESC
        LIMIT 1;
    END IF;

    v_display := CASE
        WHEN v_cap.demand_policy_id IS NULL THEN 'POLICY_MISSING'
        WHEN COALESCE(v_cap.readiness_status, 'UNKNOWN') <> 'READY'
            THEN COALESCE(v_cap.readiness_status, 'UNKNOWN')
        WHEN v_state.quality_status IS NULL THEN 'PROCESSOR_PENDING'
        ELSE v_state.quality_status
    END;

    RETURN QUERY SELECT
        p_asset_id,
        v_asset_name,
        v_site_id,
        v_cap.demand_policy_id,
        COALESCE(v_cap.demand_monitoring_enabled, TRUE),
        COALESCE(v_cap.demand_interval_seconds, 900),
        COALESCE(v_cap.demand_basis, 'ACTIVE_POWER_KW'),
        CASE COALESCE(v_cap.demand_basis, 'ACTIVE_POWER_KW')
            WHEN 'APPARENT_POWER_KVA' THEN 'kVA'
            ELSE 'kW'
        END,
        v_cap.source_device_id,
        v_cap.source_device_name,
        v_cap.source_profile_code,
        v_cap.selected_method,
        COALESCE(v_cap.capability_ready, FALSE),
        CASE
            WHEN v_cap.demand_policy_id IS NULL THEN 'POLICY_MISSING'
            ELSE COALESCE(v_cap.readiness_status, 'UNKNOWN')
        END,
        v_state.interval_start,
        v_state.interval_end,
        CASE COALESCE(v_cap.demand_basis, 'ACTIVE_POWER_KW')
            WHEN 'APPARENT_POWER_KVA' THEN v_state.current_demand_kva
            ELSE v_state.current_demand_kw
        END,
        v_state.current_demand_kw,
        v_state.coverage_percent,
        v_state.quality_status,
        v_display,
        v_state.updated_at,
        v_last.demand_kw,
        v_last.interval_end;
END;
$function$;

COMMENT ON FUNCTION analytics.get_grafana_asset_demand_summary(BIGINT,UUID,TIMESTAMPTZ) IS
'Fast tenant-safe automatic ASSET demand summary. Uses PRIMARY_METER capability plus the platform-managed 15-minute kW ASSET policy and never depends on SITE demand enablement.';

-- ---------------------------------------------------------------------------
-- 5. Parameterized cumulative-energy delta read for one asset/time range.
--
-- This is intentionally a function rather than another broad view. The device
-- and time predicates are applied to telemetry.energy_measurements first, then
-- register semantics and quality classification are evaluated only for those
-- samples. One sample immediately before p_from is included only to establish
-- the first in-range delta.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_grafana_asset_energy_intervals(
    p_grafana_org_id BIGINT,
    p_asset_id UUID,
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TABLE (
    interval_start TIMESTAMPTZ,
    device_id UUID,
    device_name TEXT,
    elapsed_minutes NUMERIC,
    import_consumption_kwh NUMERIC,
    export_consumption_kwh NUMERIC,
    import_quality_code TEXT,
    export_quality_code TEXT,
    reset_detected BOOLEAN,
    gap_detected BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics, config, metadata, telemetry
AS $function$
WITH ctx AS (
    SELECT
        a.id AS asset_id,
        a.site_id,
        ad.device_id,
        d.name AS device_name,
        d.profile_id
    FROM metadata.grafana_organization_map AS gom
    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id
    JOIN metadata.asset_devices AS ad
      ON ad.asset_id = a.id
     AND ad.relationship_type = 'PRIMARY_METER'
    JOIN metadata.devices AS d
      ON d.id = ad.device_id
    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id
      AND p_to > p_from
    LIMIT 1
),
prior_sample AS (
    SELECT
        em.bucket_start,
        em.device_id,
        em.import_energy_total_wh,
        em.export_energy_total_wh
    FROM ctx AS c
    CROSS JOIN LATERAL (
        SELECT
            x.bucket_start,
            x.device_id,
            x.import_energy_total_wh,
            x.export_energy_total_wh
        FROM telemetry.energy_measurements AS x
        WHERE x.device_id = c.device_id
          AND x.bucket_start < p_from
        ORDER BY x.bucket_start DESC
        LIMIT 1
    ) AS em
),
range_samples AS (
    SELECT
        em.bucket_start,
        em.device_id,
        em.import_energy_total_wh,
        em.export_energy_total_wh
    FROM ctx AS c
    JOIN telemetry.energy_measurements AS em
      ON em.device_id = c.device_id
     AND em.bucket_start >= p_from
     AND em.bucket_start <= p_to
),
samples AS (
    SELECT * FROM prior_sample
    UNION ALL
    SELECT * FROM range_samples
),
ordered AS (
    SELECT
        s.*,
        lag(s.bucket_start) OVER (ORDER BY s.bucket_start) AS previous_bucket_start,
        lag(s.import_energy_total_wh) OVER (ORDER BY s.bucket_start) AS previous_import_wh,
        lag(s.export_energy_total_wh) OVER (ORDER BY s.bucket_start) AS previous_export_wh
    FROM samples AS s
),
semantics AS (
    SELECT
        c.device_id,
        c.device_name,
        i.counter_direction AS import_counter_direction,
        i.rollover_behavior AS import_rollover_behavior,
        i.rollover_value AS import_rollover_value,
        i.reset_behavior AS import_reset_behavior,
        i.expected_max_interval_delta AS import_expected_max_delta_wh,
        e.counter_direction AS export_counter_direction,
        e.rollover_behavior AS export_rollover_behavior,
        e.rollover_value AS export_rollover_value,
        e.reset_behavior AS export_reset_behavior,
        e.expected_max_interval_delta AS export_expected_max_delta_wh
    FROM ctx AS c
    LEFT JOIN LATERAL (
        SELECT
            ers.counter_direction,
            ers.rollover_behavior,
            ers.rollover_value,
            ers.reset_behavior,
            ers.expected_max_interval_delta
        FROM config.energy_register_semantics AS ers
        WHERE ers.profile_id = c.profile_id
          AND ers.flow_interpretation = 'GRID_IMPORT'
          AND ers.is_active
        LIMIT 1
    ) AS i ON TRUE
    LEFT JOIN LATERAL (
        SELECT
            ers.counter_direction,
            ers.rollover_behavior,
            ers.rollover_value,
            ers.reset_behavior,
            ers.expected_max_interval_delta
        FROM config.energy_register_semantics AS ers
        WHERE ers.profile_id = c.profile_id
          AND ers.flow_interpretation = 'GRID_EXPORT'
          AND ers.is_active
        LIMIT 1
    ) AS e ON TRUE
),
classified AS (
    SELECT
        o.bucket_start,
        o.device_id,
        sem.device_name,
        (extract(epoch FROM (o.bucket_start - o.previous_bucket_start)) / 60.0)::NUMERIC
            AS elapsed_minutes,
        import_result.delta_wh / 1000.0 AS import_consumption_kwh,
        export_result.delta_wh / 1000.0 AS export_consumption_kwh,
        import_result.quality_code AS import_quality_code,
        export_result.quality_code AS export_quality_code,
        (import_result.reset_detected OR export_result.reset_detected) AS reset_detected,
        (
            import_result.quality_code = 'GAP'
            OR export_result.quality_code = 'GAP'
        ) AS gap_detected
    FROM ordered AS o
    JOIN semantics AS sem
      ON sem.device_id = o.device_id
    LEFT JOIN LATERAL config.resolve_interval_quality_rule(
        o.device_id,
        o.bucket_start
    ) AS interval_rule ON TRUE
    CROSS JOIN LATERAL analytics.classify_energy_register_delta(
        o.import_energy_total_wh,
        o.previous_import_wh,
        (extract(epoch FROM (o.bucket_start - o.previous_bucket_start)) / 60.0)::NUMERIC,
        sem.import_counter_direction,
        sem.import_rollover_behavior,
        sem.import_rollover_value,
        sem.import_reset_behavior,
        sem.import_expected_max_delta_wh,
        COALESCE(interval_rule.gap_threshold_minutes, 30)
    ) AS import_result
    CROSS JOIN LATERAL analytics.classify_energy_register_delta(
        o.export_energy_total_wh,
        o.previous_export_wh,
        (extract(epoch FROM (o.bucket_start - o.previous_bucket_start)) / 60.0)::NUMERIC,
        sem.export_counter_direction,
        sem.export_rollover_behavior,
        sem.export_rollover_value,
        sem.export_reset_behavior,
        sem.export_expected_max_delta_wh,
        COALESCE(interval_rule.gap_threshold_minutes, 30)
    ) AS export_result
)
SELECT
    c.bucket_start,
    c.device_id,
    c.device_name,
    c.elapsed_minutes,
    c.import_consumption_kwh,
    c.export_consumption_kwh,
    c.import_quality_code,
    c.export_quality_code,
    c.reset_detected,
    c.gap_detected
FROM classified AS c
WHERE c.bucket_start >= p_from
  AND c.bucket_start <= p_to
ORDER BY c.bucket_start;
$function$;

COMMENT ON FUNCTION analytics.get_grafana_asset_energy_intervals(BIGINT,UUID,TIMESTAMPTZ,TIMESTAMPTZ) IS
'Fast tenant-safe cumulative energy consumption for one asset/time range. Device/time filtering happens before semantic delta classification; one pre-range sample anchors the first delta.';

-- ---------------------------------------------------------------------------
-- 6. Ownership and least-privilege execution boundary.
-- ---------------------------------------------------------------------------

ALTER FUNCTION analytics.get_grafana_asset_telemetry_context(BIGINT,UUID,TIMESTAMPTZ)
    OWNER TO ems_admin;
ALTER FUNCTION analytics.get_grafana_asset_demand_summary(BIGINT,UUID,TIMESTAMPTZ)
    OWNER TO ems_admin;
ALTER FUNCTION analytics.get_grafana_asset_energy_intervals(BIGINT,UUID,TIMESTAMPTZ,TIMESTAMPTZ)
    OWNER TO ems_admin;

REVOKE ALL ON FUNCTION analytics.get_grafana_asset_telemetry_context(BIGINT,UUID,TIMESTAMPTZ)
FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.get_grafana_asset_demand_summary(BIGINT,UUID,TIMESTAMPTZ)
FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.get_grafana_asset_energy_intervals(BIGINT,UUID,TIMESTAMPTZ,TIMESTAMPTZ)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION analytics.get_grafana_asset_telemetry_context(BIGINT,UUID,TIMESTAMPTZ)
TO ems_app, ems_readonly, grafana_reader;
GRANT EXECUTE ON FUNCTION analytics.get_grafana_asset_demand_summary(BIGINT,UUID,TIMESTAMPTZ)
TO ems_app, ems_readonly, grafana_reader;
GRANT EXECUTE ON FUNCTION analytics.get_grafana_asset_energy_intervals(BIGINT,UUID,TIMESTAMPTZ,TIMESTAMPTZ)
TO ems_app, ems_readonly, grafana_reader;
