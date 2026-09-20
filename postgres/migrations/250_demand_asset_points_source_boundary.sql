-- ============================================================================
-- Migration 250
-- Demand -- Option A attribution migration. Replaces PRIMARY_METER-based
-- ASSET-scope demand-source resolution with metadata.asset_points
-- full-interval containment, and implements the finalized "any source
-- change within an interval is a calculation boundary, never spliced"
-- product rule. Per ADR-018 Amendments 7/9/10 (docs/00-governance/
-- decisions/ADR-018-asset-point-assignment-and-commissioning.md).
--
-- Source of record: this session's read-only Demand investigation series
-- (traced analytics.calculate_demand_window, analytics.resolve_demand_
-- capability, analytics.refresh_demand_analytics, config.resolve_device_
-- demand_method in full; confirmed demand_intervals.quality_status has no
-- CHECK constraint; confirmed the frontend's DEMAND_STATUS_LABELS/
-- DEMAND_STATUS_EXPLANATIONS maps have no entry for VALID/INCOMPLETE and
-- fall through any unrecognized quality_status to "Data unavailable").
--
-- Decision (recorded before this migration): any Asset device/source
-- change within a fixed 15/30-minute interval makes that interval
-- unavailable -- no splicing. A new, distinct quality_status,
-- 'SOURCE_BOUNDARY', is used for this condition rather than reusing
-- 'INCOMPLETE' (which today, verified this session, already carries an
-- inconsistent meaning across methods: NULL demand_kw for
-- ENERGY_COUNTER_DELTA's INCOMPLETE rows, but a real non-null value for
-- TIME_WEIGHTED_POWER's -- reusing it would add a third meaning to an
-- already-ambiguous label). demand_kw/demand_kva are NULL for
-- SOURCE_BOUNDARY rows, exactly like existing NO_DATA/INVALID_SOURCE rows,
-- so the customer-facing trend chart (ChartFrame: null renders a gap,
-- never 0) shows a genuine gap, and DemandOverview.tsx's existing
-- defensive fallback (any status absent from DEMAND_STATUS_LABELS renders
-- "Data unavailable") already covers the new status with zero frontend
-- change required.
--
-- What this migration does (ADDITIVE for the new function; CREATE OR
-- REPLACE for the two existing objects, preserving their exact signatures
-- and every unrelated line of behavior):
--
--   1. analytics.resolve_demand_source_for_interval(uuid, timestamptz,
--      timestamptz, text, integer) RETURNS TABLE(device_id, logical_point_
--      id, profile_id, profile_code, selected_method) -- NEW. Finds every
--      metadata.asset_points binding for the given asset whose
--      effective_range fully contains [p_interval_start, p_interval_end)
--      (a binding that starts or ends partway through the interval fails
--      this containment check and contributes nothing -- this single
--      check IS the "any change is a boundary, no splicing" rule, with no
--      separate change-detection logic needed), resolves each candidate
--      device's method via the UNCHANGED config.resolve_device_demand_
--      method, keeps only methods whose required source point was
--      actually confirmed for that device (never an unconfirmed point),
--      and returns at most one row, preferring METER_NATIVE >
--      ENERGY_COUNTER_DELTA > TIME_WEIGHTED_POWER when more than one
--      candidate independently and fully covers the interval.
--
--   2. analytics.calculate_demand_window(...) -- CREATE OR REPLACE, same
--      signature and RETURNS TABLE shape as before. SITE scope is
--      UNTOUCHED (still resolves via analytics.resolve_demand_capability /
--      config.site_energy_meter_roles -- not part of this migration).
--      ASSET scope now resolves its policy first (config.resolve_asset_
--      demand_policy, the same call already made elsewhere in this
--      function, just reordered earlier) and its source via the new
--      function above; when no source is found, returns a
--      'SOURCE_BOUNDARY' row with NULL demand_kw/demand_kva instead of
--      entering any calculation branch. All three existing calculation
--      branches (METER_NATIVE / ENERGY_COUNTER_DELTA / TIME_WEIGHTED_
--      POWER) are copied VERBATIM, unchanged.
--
--   3. analytics.refresh_demand_analytics(...) -- CREATE OR REPLACE, same
--      signature. Two changes, both mechanical replacements of a
--      PRIMARY_METER-based existence check with an equivalent, currently-
--      effective metadata.asset_points existence check: the ASSET-scope
--      stale-state cleanup DELETE, and the ASSET-scope arm of the scope-
--      enumeration loop. No other line changes.
--
-- What this migration does NOT do (explicit):
--   * Does NOT change SITE-scope demand resolution in any way.
--   * Does NOT change any of the three calculation branches' internal SQL.
--   * Does NOT change analytics.resolve_demand_capability (kept, still
--     used for SITE scope; ASSET scope no longer calls it).
--   * Does NOT change config.resolve_device_demand_method,
--     config.resolve_asset_demand_policy, config.resolve_site_demand_
--     policy, analytics.resolve_demand_interval, or telemetry.resolve_
--     site_capture_bucket.
--   * Does NOT add any schema/column/constraint -- quality_status has no
--     CHECK constraint (verified this session), so 'SOURCE_BOUNDARY' is a
--     plain new string value, not a schema change.
--   * Does NOT touch telemetry.energy_measurements, metadata.
--     asset_devices, or PRIMARY_METER's own schema/constraints.
--   * Does NOT implement source splicing of any kind -- explicitly ruled
--     out by the finalized product decision.
--
-- Rollback: re-apply the pre-250 CREATE OR REPLACE bodies of analytics.
-- calculate_demand_window and analytics.refresh_demand_analytics (restore
-- the PRIMARY_METER-based resolution), and DROP FUNCTION analytics.
-- resolve_demand_source_for_interval(uuid, timestamptz, timestamptz, text,
-- integer); safe, no other object is altered by this migration.
--
-- Updated/new tests: scripts/test/assert_demand_source_boundary.sh (new,
-- data-driven: stable-source regression, mid-interval source-change
-- boundary for each method, resume on the next fully-covered interval,
-- historical immutability, multi-candidate 3-tier priority).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('analytics.calculate_demand_window(uuid, text, uuid, timestamptz, timestamptz, timestamptz, boolean)') IS NULL THEN
        RAISE EXCEPTION 'Migration 250 precondition failed: analytics.calculate_demand_window(...) is missing.';
    END IF;

    IF to_regprocedure('analytics.resolve_demand_capability(uuid, text, uuid, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 250 precondition failed: analytics.resolve_demand_capability(...) is missing.';
    END IF;

    IF to_regprocedure('config.resolve_device_demand_method(uuid, text, integer)') IS NULL THEN
        RAISE EXCEPTION 'Migration 250 precondition failed: config.resolve_device_demand_method(...) is missing.';
    END IF;

    IF to_regprocedure('config.resolve_asset_demand_policy(uuid, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 250 precondition failed: config.resolve_asset_demand_policy(...) is missing.';
    END IF;

    IF to_regclass('metadata.asset_points') IS NULL THEN
        RAISE EXCEPTION 'Migration 250 precondition failed: metadata.asset_points is missing (migration 224).';
    END IF;

    IF to_regprocedure('analytics.refresh_demand_analytics(timestamptz, interval, timestamptz, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 250 precondition failed: analytics.refresh_demand_analytics(...) is missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.resolve_demand_source_for_interval(uuid, timestamptz,
--    timestamptz, text, integer) -- NEW.
-- ----------------------------------------------------------------------------
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
    WITH covering_points AS (
        -- Every asset_points binding for this asset whose effective range
        -- fully contains the requested interval. A binding that starts or
        -- ends partway through the interval (a source change mid-interval)
        -- fails this containment check on both sides and is simply absent
        -- here -- this single check implements "any change is a boundary,
        -- no splicing," with no separate change-detection required.
        SELECT ap.device_id, ap.logical_point_id
        FROM metadata.asset_points AS ap
        WHERE ap.asset_id = p_asset_id
          AND ap.effective_from <= p_interval_start
          AND (ap.effective_to IS NULL OR ap.effective_to >= p_interval_end)
    ),
    candidate_devices AS (
        SELECT DISTINCT device_id FROM covering_points
    ),
    resolved AS (
        SELECT
            cd.device_id,
            m.selected_method,
            m.source_logical_point_id AS logical_point_id,
            m.profile_id,
            m.profile_code
        FROM candidate_devices AS cd
        CROSS JOIN LATERAL config.resolve_device_demand_method(
            cd.device_id, p_demand_basis, p_demand_interval_seconds
        ) AS m
        WHERE COALESCE(m.capability_ready, FALSE)
          -- The point the device's resolved method actually needs must be
          -- one this asset genuinely confirmed for that device (via
          -- covering_points) -- never a point the device merely happens to
          -- support but that was never assigned to this asset.
          AND EXISTS (
              SELECT 1 FROM covering_points AS cp
              WHERE cp.device_id = cd.device_id
                AND cp.logical_point_id = m.source_logical_point_id
          )
    )
    SELECT device_id, logical_point_id, profile_id, profile_code, selected_method
    FROM resolved
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


-- ----------------------------------------------------------------------------
-- 2. analytics.calculate_demand_window(...) -- CREATE OR REPLACE. Same
--    signature/RETURNS TABLE shape. SITE scope unchanged. ASSET scope
--    resolves policy first, then source via the new function above; the
--    three calculation branches below are copied verbatim, unchanged.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.calculate_demand_window
(
    p_site_id        UUID,
    p_scope_type     TEXT,
    p_asset_id       UUID,
    p_interval_start TIMESTAMPTZ,
    p_interval_end   TIMESTAMPTZ,
    p_window_end     TIMESTAMPTZ,
    p_final          BOOLEAN DEFAULT TRUE
)
RETURNS TABLE
(
    organization_id       UUID,
    site_id                UUID,
    scope_type             TEXT,
    asset_id                UUID,
    demand_policy_id        UUID,
    source_device_id        UUID,
    demand_kw                DOUBLE PRECISION,
    demand_kva               DOUBLE PRECISION,
    peak_power_kw             DOUBLE PRECISION,
    energy_kwh                 NUMERIC,
    source_method               TEXT,
    expected_observations        INTEGER,
    observed_observations         INTEGER,
    coverage_percent                NUMERIC,
    quality_status                   TEXT
)
LANGUAGE plpgsql
STABLE
SET search_path TO pg_catalog, analytics, config, metadata, telemetry
AS $function$
DECLARE
    v_org UUID;
    v_cap RECORD;
    v_capture RECORD;
    v_policy RECORD;
    v_source RECORD;
    v_effective_end TIMESTAMPTZ;
    v_receipt_deadline TIMESTAMPTZ;
    v_capture_seconds INTEGER;
    v_expected INTEGER;
    v_observed INTEGER := 0;
    v_coverage NUMERIC(5,2) := 0;
    v_quality TEXT;
    v_method TEXT;
    v_basis TEXT;
    v_start_value NUMERIC;
    v_end_value NUMERIC;
    v_delta NUMERIC;
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_span_seconds DOUBLE PRECISION;
    v_expected_max NUMERIC;
    v_counter_direction TEXT;
    v_rollover_behavior TEXT;
    v_rollover_value NUMERIC;
    v_reset_behavior TEXT;
    v_native_scale NUMERIC := 1;
    v_native_value NUMERIC;
    v_power_value DOUBLE PRECISION;
    v_peak_kw DOUBLE PRECISION;
    v_energy_kwh NUMERIC(20,6);
BEGIN
    IF upper(btrim(p_scope_type)) NOT IN ('SITE', 'ASSET') THEN
        RAISE EXCEPTION 'Invalid demand scope: %', p_scope_type;
    END IF;
    IF p_interval_end <= p_interval_start THEN
        RAISE EXCEPTION 'Demand interval end must be after interval start.';
    END IF;

    v_effective_end := LEAST(p_window_end, p_interval_end);
    IF v_effective_end <= p_interval_start THEN
        RAISE EXCEPTION 'Demand window end must be after interval start.';
    END IF;

    SELECT s.organization_id INTO v_org
    FROM metadata.sites AS s
    WHERE s.id = p_site_id;
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'Demand site not found: %', p_site_id;
    END IF;

    IF upper(btrim(p_scope_type)) = 'SITE' THEN
        -- SITE scope: entirely unchanged -- still resolves via
        -- resolve_demand_capability / config.site_energy_meter_roles, not
        -- part of this migration.
        SELECT * INTO v_cap
        FROM analytics.resolve_demand_capability(
            p_site_id,
            'SITE',
            p_asset_id,
            p_interval_start + INTERVAL '1 microsecond'
        );

        IF v_cap.demand_policy_id IS NULL THEN
            RETURN QUERY SELECT
                v_org, p_site_id, 'SITE',
                NULL::UUID,
                NULL::UUID, v_cap.source_device_id,
                NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION,
                NULL::DOUBLE PRECISION, NULL::NUMERIC(20,6),
                COALESCE(v_cap.selected_method, 'ENERGY_COUNTER_DELTA'),
                NULL::INTEGER, 0::INTEGER, 0::NUMERIC(5,2), 'INVALID_SOURCE'::TEXT;
            RETURN;
        END IF;

        SELECT * INTO v_policy
        FROM config.resolve_site_demand_policy(
            p_site_id,
            p_interval_start + INTERVAL '1 microsecond'
        );
    ELSE
        -- ASSET scope: metadata.asset_points full-interval containment,
        -- per ADR-018 Amendments 7/9/10 -- replaces the prior device-
        -- relationship-based resolution. Policy resolved first (unchanged source,
        -- config.resolve_asset_demand_policy -- a site-wide policy applied
        -- uniformly to every qualifying asset, not asset-specific), then
        -- source via the new containment-based function.
        SELECT * INTO v_policy
        FROM config.resolve_asset_demand_policy(
            p_site_id,
            p_interval_start + INTERVAL '1 microsecond'
        );

        IF v_policy.policy_id IS NULL
           OR NOT COALESCE(v_policy.is_enabled, FALSE)
           OR p_interval_start < v_policy.effective_from
           OR (v_policy.effective_to IS NOT NULL AND p_interval_start >= v_policy.effective_to)
        THEN
            RETURN QUERY SELECT
                v_org, p_site_id, 'ASSET',
                p_asset_id,
                NULL::UUID, NULL::UUID,
                NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION,
                NULL::DOUBLE PRECISION, NULL::NUMERIC(20,6),
                'ENERGY_COUNTER_DELTA'::TEXT,
                NULL::INTEGER, 0::INTEGER, 0::NUMERIC(5,2), 'INVALID_SOURCE'::TEXT;
            RETURN;
        END IF;

        SELECT * INTO v_source
        FROM analytics.resolve_demand_source_for_interval(
            p_asset_id, p_interval_start, v_effective_end,
            v_policy.demand_basis, v_policy.demand_interval_seconds
        );

        IF v_source.device_id IS NULL THEN
            -- No single confirmed source spans the whole interval -- a
            -- source or method boundary (ADR-018 Amendment 10). Never a
            -- synthetic hybrid value: demand_kw/demand_kva are NULL, same
            -- shape as the existing NO_DATA/INVALID_SOURCE rows above.
            RETURN QUERY SELECT
                v_org, p_site_id, 'ASSET',
                p_asset_id,
                v_policy.policy_id, NULL::UUID,
                NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION,
                NULL::DOUBLE PRECISION, NULL::NUMERIC(20,6),
                'NONE'::TEXT,
                NULL::INTEGER, 0::INTEGER, 0::NUMERIC(5,2), 'SOURCE_BOUNDARY'::TEXT;
            RETURN;
        END IF;

        -- v_cap is an untyped RECORD; unlike the SITE branch (which gets its
        -- structure from resolve_demand_capability's SELECT * INTO above),
        -- it must be given a structure via a single SELECT INTO here --
        -- field-by-field assignment on a not-yet-assigned RECORD is invalid
        -- in PL/pgSQL.
        SELECT
            v_policy.policy_id               AS demand_policy_id,
            v_policy.demand_basis            AS demand_basis,
            v_policy.demand_interval_seconds AS demand_interval_seconds,
            TRUE                             AS capability_ready,
            v_source.device_id               AS source_device_id,
            v_source.logical_point_id        AS source_logical_point_id,
            v_source.profile_id              AS source_profile_id,
            v_source.selected_method         AS selected_method
        INTO v_cap;
    END IF;

    v_basis := v_cap.demand_basis;
    v_method := v_cap.selected_method;
    v_receipt_deadline := p_interval_end
        + make_interval(secs => COALESCE(v_policy.late_arrival_tolerance_seconds, 0));

    SELECT * INTO v_capture
    FROM telemetry.resolve_site_capture_bucket(
        p_site_id,
        p_interval_start + INTERVAL '1 microsecond'
    );
    v_capture_seconds := COALESCE(v_capture.capture_interval_seconds, 60);
    v_expected := GREATEST(
        1,
        ceil(extract(epoch FROM (v_effective_end - p_interval_start)) / v_capture_seconds)::INTEGER
    );

    IF NOT COALESCE(v_cap.capability_ready, FALSE) THEN
        RETURN QUERY SELECT
            v_org, p_site_id, upper(btrim(p_scope_type)),
            CASE WHEN upper(btrim(p_scope_type))='ASSET' THEN p_asset_id ELSE NULL::UUID END,
            v_cap.demand_policy_id, v_cap.source_device_id,
            NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION,
            NULL::DOUBLE PRECISION, NULL::NUMERIC(20,6),
            COALESCE(v_method, 'ENERGY_COUNTER_DELTA'),
            v_expected, 0, 0::NUMERIC(5,2), 'INVALID_SOURCE'::TEXT;
        RETURN;
    END IF;

    -- -----------------------------------------------------------------------
    -- Native meter demand. UNCHANGED from the pre-250 body.
    -- -----------------------------------------------------------------------
    IF v_method = 'METER_NATIVE' THEN
        SELECT drs.scale_to_normalized_unit
          INTO v_native_scale
        FROM config.demand_register_semantics AS drs
        WHERE drs.profile_id = v_cap.source_profile_id
          AND drs.logical_point_id = v_cap.source_logical_point_id
          AND drs.demand_basis = v_basis
          AND drs.native_interval_seconds = v_cap.demand_interval_seconds
          AND drs.alignment_mode = 'WALL_CLOCK'
          AND drs.is_active
        LIMIT 1;

        SELECT np.numeric_value, np.event_time
          INTO v_native_value, v_end_time
        FROM telemetry.normalized_points AS np
        WHERE np.device_id = v_cap.source_device_id
          AND np.logical_point_id = v_cap.source_logical_point_id
          AND np.numeric_value IS NOT NULL
          AND np.event_time > p_interval_start
          AND np.event_time <= v_effective_end
          AND (
                np.platform_received_at IS NULL
                OR np.platform_received_at <= v_receipt_deadline
              )
        ORDER BY np.event_time DESC
        LIMIT 1;

        v_observed := CASE WHEN v_native_value IS NULL THEN 0 ELSE 1 END;
        v_expected := 1;
        v_coverage := CASE WHEN v_observed=1 THEN 100 ELSE 0 END;
        v_quality := CASE
            WHEN v_observed=0 THEN 'NO_DATA'
            WHEN p_final THEN 'VALID'
            ELSE 'PROVISIONAL'
        END;

        RETURN QUERY SELECT
            v_org, p_site_id, upper(btrim(p_scope_type)),
            CASE WHEN upper(btrim(p_scope_type))='ASSET' THEN p_asset_id ELSE NULL::UUID END,
            v_cap.demand_policy_id, v_cap.source_device_id,
            CASE WHEN v_basis='ACTIVE_POWER_KW' THEN (v_native_value*v_native_scale)::DOUBLE PRECISION ELSE NULL END,
            CASE WHEN v_basis='APPARENT_POWER_KVA' THEN (v_native_value*v_native_scale)::DOUBLE PRECISION ELSE NULL END,
            NULL::DOUBLE PRECISION, NULL::NUMERIC(20,6),
            v_method, v_expected, v_observed, v_coverage, v_quality;
        RETURN;
    END IF;

    -- -----------------------------------------------------------------------
    -- Cumulative energy-counter delta. UNCHANGED from the pre-250 body.
    -- -----------------------------------------------------------------------
    IF v_method = 'ENERGY_COUNTER_DELTA' THEN
        SELECT
            ers.expected_max_interval_delta,
            ers.counter_direction,
            ers.rollover_behavior,
            ers.rollover_value,
            ers.reset_behavior
          INTO
            v_expected_max,
            v_counter_direction,
            v_rollover_behavior,
            v_rollover_value,
            v_reset_behavior
        FROM config.energy_register_semantics AS ers
        WHERE ers.profile_id = v_cap.source_profile_id
          AND ers.logical_point_id = v_cap.source_logical_point_id
          AND ers.is_active
        LIMIT 1;

        IF v_basis='ACTIVE_POWER_KW' THEN
            SELECT count(*), min(em.bucket_start), max(em.bucket_start), max(em.active_power_total_w)/1000.0
              INTO v_observed, v_start_time, v_end_time, v_peak_kw
            FROM telemetry.energy_measurements AS em
            WHERE em.device_id=v_cap.source_device_id
              AND em.bucket_start >= p_interval_start
              AND em.bucket_start <= v_effective_end
              AND (em.received_at IS NULL OR em.received_at <= v_receipt_deadline)
              AND em.import_energy_total_wh IS NOT NULL;

            SELECT em.import_energy_total_wh INTO v_start_value
            FROM telemetry.energy_measurements AS em
            WHERE em.device_id=v_cap.source_device_id
              AND em.bucket_start >= p_interval_start
              AND em.bucket_start <= v_effective_end
              AND (em.received_at IS NULL OR em.received_at <= v_receipt_deadline)
              AND em.import_energy_total_wh IS NOT NULL
            ORDER BY em.bucket_start ASC LIMIT 1;

            SELECT em.import_energy_total_wh INTO v_end_value
            FROM telemetry.energy_measurements AS em
            WHERE em.device_id=v_cap.source_device_id
              AND em.bucket_start >= p_interval_start
              AND em.bucket_start <= v_effective_end
              AND (em.received_at IS NULL OR em.received_at <= v_receipt_deadline)
              AND em.import_energy_total_wh IS NOT NULL
            ORDER BY em.bucket_start DESC LIMIT 1;
        ELSE
            SELECT count(*), min(em.bucket_start), max(em.bucket_start), max(em.active_power_total_w)/1000.0
              INTO v_observed, v_start_time, v_end_time, v_peak_kw
            FROM telemetry.energy_measurements AS em
            WHERE em.device_id=v_cap.source_device_id
              AND em.bucket_start >= p_interval_start
              AND em.bucket_start <= v_effective_end
              AND (em.received_at IS NULL OR em.received_at <= v_receipt_deadline)
              AND em.apparent_energy_total_vah IS NOT NULL;

            SELECT em.apparent_energy_total_vah INTO v_start_value
            FROM telemetry.energy_measurements AS em
            WHERE em.device_id=v_cap.source_device_id
              AND em.bucket_start >= p_interval_start
              AND em.bucket_start <= v_effective_end
              AND (em.received_at IS NULL OR em.received_at <= v_receipt_deadline)
              AND em.apparent_energy_total_vah IS NOT NULL
            ORDER BY em.bucket_start ASC LIMIT 1;

            SELECT em.apparent_energy_total_vah INTO v_end_value
            FROM telemetry.energy_measurements AS em
            WHERE em.device_id=v_cap.source_device_id
              AND em.bucket_start >= p_interval_start
              AND em.bucket_start <= v_effective_end
              AND (em.received_at IS NULL OR em.received_at <= v_receipt_deadline)
              AND em.apparent_energy_total_vah IS NOT NULL
            ORDER BY em.bucket_start DESC LIMIT 1;
        END IF;

        IF v_observed < 2 OR v_start_value IS NULL OR v_end_value IS NULL OR v_end_time <= v_start_time THEN
            v_quality := CASE WHEN v_observed=0 THEN 'NO_DATA' ELSE 'INCOMPLETE' END;
            RETURN QUERY SELECT
                v_org, p_site_id, upper(btrim(p_scope_type)),
                CASE WHEN upper(btrim(p_scope_type))='ASSET' THEN p_asset_id ELSE NULL::UUID END,
                v_cap.demand_policy_id, v_cap.source_device_id,
                NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION, v_peak_kw,
                NULL::NUMERIC(20,6), v_method, v_expected, v_observed,
                0::NUMERIC(5,2), v_quality;
            RETURN;
        END IF;

        v_span_seconds := extract(epoch FROM (v_end_time-v_start_time));
        v_coverage := LEAST(
            100,
            round((100.0*v_span_seconds / extract(epoch FROM (v_effective_end-p_interval_start)))::NUMERIC,2)
        );

        IF v_counter_direction='DECREASING' THEN
            v_delta := v_start_value-v_end_value;
        ELSE
            v_delta := v_end_value-v_start_value;
        END IF;

        IF v_delta < 0 THEN
            IF v_rollover_behavior='FIXED_MODULUS' AND v_rollover_value IS NOT NULL THEN
                v_delta := (v_rollover_value-v_start_value)+v_end_value;
            ELSIF v_reset_behavior='ACCEPT_FROM_ZERO' THEN
                v_delta := v_end_value;
            ELSE
                v_quality := 'INVALID_SOURCE';
            END IF;
        END IF;

        IF v_quality IS NULL AND (v_delta < 0 OR (v_expected_max IS NOT NULL AND v_delta > v_expected_max)) THEN
            v_quality := 'INVALID_SOURCE';
        END IF;

        IF v_quality IS NULL THEN
            v_quality := CASE
                WHEN NOT p_final THEN 'PROVISIONAL'
                WHEN v_coverage >= COALESCE(v_policy.minimum_coverage_percent,90) THEN 'VALID'
                ELSE 'INCOMPLETE'
            END;
        END IF;

        IF v_quality IN ('VALID','PROVISIONAL') THEN
            v_power_value := (v_delta / 1000.0)
                / (v_span_seconds / 3600.0);
            IF v_basis='ACTIVE_POWER_KW' THEN
                v_energy_kwh := round((v_delta/1000.0)::NUMERIC,6);
            END IF;
        END IF;

        RETURN QUERY SELECT
            v_org, p_site_id, upper(btrim(p_scope_type)),
            CASE WHEN upper(btrim(p_scope_type))='ASSET' THEN p_asset_id ELSE NULL::UUID END,
            v_cap.demand_policy_id, v_cap.source_device_id,
            CASE WHEN v_basis='ACTIVE_POWER_KW' THEN v_power_value ELSE NULL END,
            CASE WHEN v_basis='APPARENT_POWER_KVA' THEN v_power_value ELSE NULL END,
            v_peak_kw, v_energy_kwh, v_method,
            v_expected, v_observed, v_coverage, v_quality;
        RETURN;
    END IF;

    -- -----------------------------------------------------------------------
    -- Time-weighted instantaneous power. UNCHANGED from the pre-250 body.
    -- -----------------------------------------------------------------------
    IF v_method = 'TIME_WEIGHTED_POWER' THEN
        IF v_capture_seconds > floor(v_cap.demand_interval_seconds/3.0) THEN
            RETURN QUERY SELECT
                v_org, p_site_id, upper(btrim(p_scope_type)),
                CASE WHEN upper(btrim(p_scope_type))='ASSET' THEN p_asset_id ELSE NULL::UUID END,
                v_cap.demand_policy_id, v_cap.source_device_id,
                NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION,
                NULL::DOUBLE PRECISION, NULL::NUMERIC(20,6), v_method,
                v_expected, 0, 0::NUMERIC(5,2), 'INSUFFICIENT_SOURCE_RESOLUTION'::TEXT;
            RETURN;
        END IF;

        IF v_basis='ACTIVE_POWER_KW' THEN
            WITH points AS (
                SELECT
                    em.bucket_start AS t,
                    em.active_power_total_w/1000.0 AS v,
                    lead(em.bucket_start) OVER (ORDER BY em.bucket_start) AS next_t,
                    lead(em.active_power_total_w/1000.0) OVER (ORDER BY em.bucket_start) AS next_v
                FROM telemetry.energy_measurements AS em
                WHERE em.device_id=v_cap.source_device_id
                  AND em.bucket_start >= p_interval_start
                  AND em.bucket_start <= v_effective_end
                  AND (em.received_at IS NULL OR em.received_at <= v_receipt_deadline)
                  AND em.active_power_total_w IS NOT NULL
            ), segments AS (
                SELECT *, extract(epoch FROM (next_t-t)) AS seconds
                FROM points
                WHERE next_t IS NOT NULL
                  AND next_t > t
                  AND extract(epoch FROM (next_t-t)) <= v_capture_seconds*2.5
            )
            SELECT
                (SELECT count(*) FROM points),
                COALESCE(sum(seconds),0),
                CASE WHEN sum(seconds)>0
                     THEN sum(((v+next_v)/2.0)*seconds)/sum(seconds)
                END,
                (SELECT max(v) FROM points)
            INTO v_observed, v_span_seconds, v_power_value, v_peak_kw
            FROM segments;
        ELSE
            WITH points AS (
                SELECT
                    em.bucket_start AS t,
                    em.apparent_power_total_va/1000.0 AS v,
                    lead(em.bucket_start) OVER (ORDER BY em.bucket_start) AS next_t,
                    lead(em.apparent_power_total_va/1000.0) OVER (ORDER BY em.bucket_start) AS next_v
                FROM telemetry.energy_measurements AS em
                WHERE em.device_id=v_cap.source_device_id
                  AND em.bucket_start >= p_interval_start
                  AND em.bucket_start <= v_effective_end
                  AND (em.received_at IS NULL OR em.received_at <= v_receipt_deadline)
                  AND em.apparent_power_total_va IS NOT NULL
            ), segments AS (
                SELECT *, extract(epoch FROM (next_t-t)) AS seconds
                FROM points
                WHERE next_t IS NOT NULL
                  AND next_t > t
                  AND extract(epoch FROM (next_t-t)) <= v_capture_seconds*2.5
            )
            SELECT
                (SELECT count(*) FROM points),
                COALESCE(sum(seconds),0),
                CASE WHEN sum(seconds)>0
                     THEN sum(((v+next_v)/2.0)*seconds)/sum(seconds)
                END,
                (SELECT max(em.active_power_total_w)/1000.0
                 FROM telemetry.energy_measurements em
                 WHERE em.device_id=v_cap.source_device_id
                   AND em.bucket_start >= p_interval_start
                   AND em.bucket_start <= v_effective_end)
            INTO v_observed, v_span_seconds, v_power_value, v_peak_kw
            FROM segments;
        END IF;

        v_coverage := LEAST(
            100,
            round((100.0*COALESCE(v_span_seconds,0) / extract(epoch FROM (v_effective_end-p_interval_start)))::NUMERIC,2)
        );
        v_quality := CASE
            WHEN COALESCE(v_observed,0)=0 THEN 'NO_DATA'
            WHEN NOT p_final THEN 'PROVISIONAL'
            WHEN v_coverage >= COALESCE(v_policy.minimum_coverage_percent,90) THEN 'VALID'
            ELSE 'INCOMPLETE'
        END;

        RETURN QUERY SELECT
            v_org, p_site_id, upper(btrim(p_scope_type)),
            CASE WHEN upper(btrim(p_scope_type))='ASSET' THEN p_asset_id ELSE NULL::UUID END,
            v_cap.demand_policy_id, v_cap.source_device_id,
            CASE WHEN v_basis='ACTIVE_POWER_KW' THEN v_power_value ELSE NULL END,
            CASE WHEN v_basis='APPARENT_POWER_KVA' THEN v_power_value ELSE NULL END,
            v_peak_kw, NULL::NUMERIC(20,6), v_method,
            v_expected, COALESCE(v_observed,0), v_coverage, v_quality;
        RETURN;
    END IF;

    RETURN QUERY SELECT
        v_org, p_site_id, upper(btrim(p_scope_type)),
        CASE WHEN upper(btrim(p_scope_type))='ASSET' THEN p_asset_id ELSE NULL::UUID END,
        v_cap.demand_policy_id, v_cap.source_device_id,
        NULL::DOUBLE PRECISION, NULL::DOUBLE PRECISION,
        NULL::DOUBLE PRECISION, NULL::NUMERIC(20,6),
        COALESCE(v_method,'ENERGY_COUNTER_DELTA'),
        v_expected, 0, 0::NUMERIC(5,2), 'INVALID_SOURCE'::TEXT;
END;
$function$;

ALTER FUNCTION analytics.calculate_demand_window(UUID, TEXT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.calculate_demand_window(UUID, TEXT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.calculate_demand_window(UUID, TEXT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) TO ems_app;


-- ----------------------------------------------------------------------------
-- 3. analytics.refresh_demand_analytics(...) -- CREATE OR REPLACE, same
--    signature. Two mechanical replacements only: the ASSET-scope stale-
--    state cleanup, and the ASSET-scope arm of the scope-enumeration loop
--    -- both move from a PRIMARY_METER asset_devices existence check to an
--    equivalent, currently-effective metadata.asset_points existence
--    check. Every other line is unchanged from the pre-250 body.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.refresh_demand_analytics
(
    IN p_now            TIMESTAMPTZ DEFAULT clock_timestamp(),
    IN p_lookback        INTERVAL DEFAULT '03:00:00'::INTERVAL,
    IN p_finalize_from    TIMESTAMPTZ DEFAULT NULL::TIMESTAMPTZ,
    IN p_finalize_to       TIMESTAMPTZ DEFAULT NULL::TIMESTAMPTZ
)
LANGUAGE plpgsql
SET search_path TO pg_catalog, analytics, config, metadata
AS $procedure$
DECLARE
    v_site RECORD;
    v_scope RECORD;
    v_interval RECORD;
    v_calc RECORD;
    v_policy RECORD;
    v_site_policy RECORD;
    v_asset_policy RECORD;
    v_current RECORD;
    v_n INTEGER;
    v_max_n INTEGER;
    v_win_from TIMESTAMPTZ;
    v_win_to TIMESTAMPTZ;
BEGIN
    IF p_lookback IS NULL OR p_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_lookback must be positive.';
    END IF;

    v_win_from := COALESCE(p_finalize_from, p_now - p_lookback);
    v_win_to   := COALESCE(p_finalize_to,   p_now);

    -- Every non-decommissioned site participates in automatic ASSET demand.
    -- SITE demand remains opt-in through the user-managed SITE policy.
    FOR v_site IN
        SELECT s.id AS site_id
        FROM metadata.sites AS s
        WHERE COALESCE(s.lifecycle_status, 'ACTIVE') <> 'DECOMMISSIONED'
    LOOP
        SELECT * INTO v_site_policy
        FROM config.resolve_site_demand_policy(v_site.site_id, p_now);

        SELECT * INTO v_asset_policy
        FROM config.resolve_asset_demand_policy(v_site.site_id, p_now);

        IF v_site_policy.policy_id IS NULL
           OR NOT COALESCE(v_site_policy.is_enabled, FALSE) THEN
            DELETE FROM analytics.demand_state
            WHERE site_id = v_site.site_id
              AND scope_type = 'SITE';
        END IF;

        -- Remove stale asset state when the asset no longer has any
        -- currently-effective metadata.asset_points binding -- replaces
        -- the prior device-relationship-based existence check, per
        -- ADR-018 Amendments 7/9/10.
        DELETE FROM analytics.demand_state AS ds
        WHERE ds.site_id = v_site.site_id
          AND ds.scope_type = 'ASSET'
          AND NOT EXISTS (
              SELECT 1
              FROM metadata.asset_points AS ap
              WHERE ap.asset_id = ds.asset_id
                AND ap.effective_from <= p_now
                AND (ap.effective_to IS NULL OR ap.effective_to > p_now)
          );

        FOR v_scope IN
            SELECT 'SITE'::TEXT AS scope_type,
                   NULL::UUID AS asset_id,
                   v_site_policy.policy_id AS policy_id,
                   v_site_policy.demand_interval_seconds AS demand_interval_seconds,
                   v_site_policy.effective_from AS effective_from,
                   v_site_policy.effective_to AS effective_to,
                   v_site_policy.late_arrival_tolerance_seconds AS late_arrival_tolerance_seconds
            WHERE v_site_policy.policy_id IS NOT NULL
              AND COALESCE(v_site_policy.is_enabled, FALSE)

            UNION ALL

            -- Enumerate every asset at this site with a currently-
            -- effective metadata.asset_points binding -- replaces the
            -- prior device-relationship-based enumeration.
            SELECT 'ASSET'::TEXT,
                   ap.asset_id,
                   v_asset_policy.policy_id,
                   v_asset_policy.demand_interval_seconds,
                   v_asset_policy.effective_from,
                   v_asset_policy.effective_to,
                   v_asset_policy.late_arrival_tolerance_seconds
            FROM (
                SELECT DISTINCT asset_id
                FROM metadata.asset_points
                WHERE effective_from <= p_now
                  AND (effective_to IS NULL OR effective_to > p_now)
            ) AS ap
            JOIN metadata.assets AS a ON a.id = ap.asset_id
            WHERE a.site_id = v_site.site_id
              AND v_asset_policy.policy_id IS NOT NULL
        LOOP
            IF v_scope.scope_type = 'ASSET' THEN
                SELECT * INTO v_policy
                FROM config.resolve_asset_demand_policy(v_site.site_id, p_now);
            ELSE
                SELECT * INTO v_policy
                FROM config.resolve_site_demand_policy(v_site.site_id, p_now);
            END IF;

            v_max_n := ceil(
                extract(epoch FROM (v_win_to - v_win_from)) / v_policy.demand_interval_seconds
            )::INTEGER + 2;

            -- Current provisional state.
            SELECT * INTO v_current
            FROM analytics.resolve_demand_interval(
                v_site.site_id,
                v_policy.demand_interval_seconds,
                p_now
            );

            IF v_current.interval_start >= v_policy.effective_from
               AND (v_policy.effective_to IS NULL OR v_current.interval_start < v_policy.effective_to) THEN
                SELECT * INTO v_calc
                FROM analytics.calculate_demand_window(
                    v_site.site_id,
                    v_scope.scope_type,
                    v_scope.asset_id,
                    v_current.interval_start,
                    v_current.interval_end,
                    p_now,
                    FALSE
                );

                IF v_calc.demand_policy_id IS NOT NULL THEN
                    INSERT INTO analytics.demand_state(
                        site_id,scope_type,asset_id,demand_policy_id,source_device_id,
                        interval_start,interval_end,current_demand_kw,current_demand_kva,
                        expected_observations,observed_observations,coverage_percent,
                        quality_status,updated_at
                    ) VALUES (
                        v_site.site_id,v_scope.scope_type,v_scope.asset_id,
                        v_calc.demand_policy_id,v_calc.source_device_id,
                        v_current.interval_start,v_current.interval_end,
                        v_calc.demand_kw,v_calc.demand_kva,
                        v_calc.expected_observations,v_calc.observed_observations,
                        v_calc.coverage_percent,
                        CASE
                            WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION','SOURCE_BOUNDARY')
                                THEN v_calc.quality_status
                            ELSE 'PROVISIONAL'
                        END,
                        clock_timestamp()
                    )
                    ON CONFLICT DO NOTHING;

                    IF v_scope.scope_type='SITE' THEN
                        UPDATE analytics.demand_state SET
                            demand_policy_id=v_calc.demand_policy_id,
                            source_device_id=v_calc.source_device_id,
                            interval_start=v_current.interval_start,
                            interval_end=v_current.interval_end,
                            current_demand_kw=v_calc.demand_kw,
                            current_demand_kva=v_calc.demand_kva,
                            expected_observations=v_calc.expected_observations,
                            observed_observations=v_calc.observed_observations,
                            coverage_percent=v_calc.coverage_percent,
                            quality_status=CASE
                                WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION','SOURCE_BOUNDARY')
                                    THEN v_calc.quality_status
                                ELSE 'PROVISIONAL'
                            END,
                            updated_at=clock_timestamp()
                        WHERE site_id=v_site.site_id AND scope_type='SITE';
                    ELSE
                        UPDATE analytics.demand_state SET
                            site_id=v_site.site_id,
                            demand_policy_id=v_calc.demand_policy_id,
                            source_device_id=v_calc.source_device_id,
                            interval_start=v_current.interval_start,
                            interval_end=v_current.interval_end,
                            current_demand_kw=v_calc.demand_kw,
                            current_demand_kva=v_calc.demand_kva,
                            expected_observations=v_calc.expected_observations,
                            observed_observations=v_calc.observed_observations,
                            coverage_percent=v_calc.coverage_percent,
                            quality_status=CASE
                                WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION','SOURCE_BOUNDARY')
                                    THEN v_calc.quality_status
                                ELSE 'PROVISIONAL'
                            END,
                            updated_at=clock_timestamp()
                        WHERE asset_id=v_scope.asset_id AND scope_type='ASSET';
                    END IF;
                END IF;
            END IF;

            -- Finalized historical intervals. Five-minute processing grace remains
            -- separate from the policy late-arrival allowance.
            FOR v_n IN 1..v_max_n LOOP
                SELECT * INTO v_interval
                FROM analytics.resolve_demand_interval(
                    v_site.site_id,
                    v_policy.demand_interval_seconds,
                    v_win_to - make_interval(secs => v_n*v_policy.demand_interval_seconds)
                );

                CONTINUE WHEN v_interval.interval_start IS NULL;
                EXIT WHEN v_interval.interval_end <= v_win_from;

                IF v_interval.interval_start < v_policy.effective_from THEN
                    CONTINUE;
                END IF;
                IF v_policy.effective_to IS NOT NULL
                   AND v_interval.interval_end > v_policy.effective_to THEN
                    CONTINUE;
                END IF;
                IF v_interval.interval_end
                   + make_interval(secs => COALESCE(v_policy.late_arrival_tolerance_seconds,0))
                   + INTERVAL '5 minutes' > p_now THEN
                    CONTINUE;
                END IF;

                SELECT * INTO v_calc
                FROM analytics.calculate_demand_window(
                    v_site.site_id,
                    v_scope.scope_type,
                    v_scope.asset_id,
                    v_interval.interval_start,
                    v_interval.interval_end,
                    v_interval.interval_end,
                    TRUE
                );

                IF v_calc.demand_policy_id IS NULL THEN CONTINUE; END IF;

                IF v_scope.scope_type = 'SITE' THEN
                    INSERT INTO analytics.demand_intervals(
                    interval_start,interval_end,organization_id,site_id,scope_type,
                    asset_id,demand_policy_id,source_device_id,demand_kw,demand_kva,
                    peak_power_kw,energy_kwh,source_method,expected_observations,
                    observed_observations,coverage_percent,quality_status,finalized_at
                    ) VALUES (
                    v_interval.interval_start,v_interval.interval_end,
                    v_calc.organization_id,v_calc.site_id,v_calc.scope_type,
                    v_calc.asset_id,v_calc.demand_policy_id,v_calc.source_device_id,
                    v_calc.demand_kw,v_calc.demand_kva,v_calc.peak_power_kw,
                    v_calc.energy_kwh,v_calc.source_method,v_calc.expected_observations,
                    v_calc.observed_observations,v_calc.coverage_percent,
                    CASE WHEN v_calc.quality_status='PROVISIONAL' THEN 'INCOMPLETE' ELSE v_calc.quality_status END,
                    clock_timestamp()
                    )
                    ON CONFLICT (site_id,interval_start,demand_policy_id) WHERE scope_type = 'SITE'
                    DO UPDATE SET
                        organization_id=EXCLUDED.organization_id,
                        source_device_id=EXCLUDED.source_device_id,
                        demand_kw=EXCLUDED.demand_kw,
                        demand_kva=EXCLUDED.demand_kva,
                        peak_power_kw=EXCLUDED.peak_power_kw,
                        energy_kwh=EXCLUDED.energy_kwh,
                        source_method=EXCLUDED.source_method,
                        expected_observations=EXCLUDED.expected_observations,
                        observed_observations=EXCLUDED.observed_observations,
                        coverage_percent=EXCLUDED.coverage_percent,
                        quality_status=EXCLUDED.quality_status,
                        finalized_at=clock_timestamp()
                    WHERE analytics.demand_intervals.quality_status <> 'VALID'
                      AND (   EXCLUDED.quality_status        IS DISTINCT FROM analytics.demand_intervals.quality_status
                           OR EXCLUDED.demand_kw             IS DISTINCT FROM analytics.demand_intervals.demand_kw
                           OR EXCLUDED.demand_kva            IS DISTINCT FROM analytics.demand_intervals.demand_kva
                           OR EXCLUDED.coverage_percent      IS DISTINCT FROM analytics.demand_intervals.coverage_percent
                           OR EXCLUDED.observed_observations IS DISTINCT FROM analytics.demand_intervals.observed_observations );
                ELSE
                    INSERT INTO analytics.demand_intervals(
                    interval_start,interval_end,organization_id,site_id,scope_type,
                    asset_id,demand_policy_id,source_device_id,demand_kw,demand_kva,
                    peak_power_kw,energy_kwh,source_method,expected_observations,
                    observed_observations,coverage_percent,quality_status,finalized_at
                    ) VALUES (
                    v_interval.interval_start,v_interval.interval_end,
                    v_calc.organization_id,v_calc.site_id,v_calc.scope_type,
                    v_calc.asset_id,v_calc.demand_policy_id,v_calc.source_device_id,
                    v_calc.demand_kw,v_calc.demand_kva,v_calc.peak_power_kw,
                    v_calc.energy_kwh,v_calc.source_method,v_calc.expected_observations,
                    v_calc.observed_observations,v_calc.coverage_percent,
                    CASE WHEN v_calc.quality_status='PROVISIONAL' THEN 'INCOMPLETE' ELSE v_calc.quality_status END,
                    clock_timestamp()
                    )
                    ON CONFLICT (asset_id,interval_start,demand_policy_id) WHERE scope_type = 'ASSET'
                    DO UPDATE SET
                        organization_id=EXCLUDED.organization_id,
                        source_device_id=EXCLUDED.source_device_id,
                        demand_kw=EXCLUDED.demand_kw,
                        demand_kva=EXCLUDED.demand_kva,
                        peak_power_kw=EXCLUDED.peak_power_kw,
                        energy_kwh=EXCLUDED.energy_kwh,
                        source_method=EXCLUDED.source_method,
                        expected_observations=EXCLUDED.expected_observations,
                        observed_observations=EXCLUDED.observed_observations,
                        coverage_percent=EXCLUDED.coverage_percent,
                        quality_status=EXCLUDED.quality_status,
                        finalized_at=clock_timestamp()
                    WHERE analytics.demand_intervals.quality_status <> 'VALID'
                      AND (   EXCLUDED.quality_status        IS DISTINCT FROM analytics.demand_intervals.quality_status
                           OR EXCLUDED.demand_kw             IS DISTINCT FROM analytics.demand_intervals.demand_kw
                           OR EXCLUDED.demand_kva            IS DISTINCT FROM analytics.demand_intervals.demand_kva
                           OR EXCLUDED.coverage_percent      IS DISTINCT FROM analytics.demand_intervals.coverage_percent
                           OR EXCLUDED.observed_observations IS DISTINCT FROM analytics.demand_intervals.observed_observations );
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$procedure$;

ALTER PROCEDURE analytics.refresh_demand_analytics(TIMESTAMPTZ, INTERVAL, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.refresh_demand_analytics(TIMESTAMPTZ, INTERVAL, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE analytics.refresh_demand_analytics(TIMESTAMPTZ, INTERVAL, TIMESTAMPTZ, TIMESTAMPTZ) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig_new  TEXT := 'analytics.resolve_demand_source_for_interval(uuid, timestamptz, timestamptz, text, integer)';
    v_sig_calc TEXT := 'analytics.calculate_demand_window(uuid, text, uuid, timestamptz, timestamptz, timestamptz, boolean)';
    v_body_calc TEXT;
    v_body_refresh TEXT;
BEGIN
    IF to_regprocedure(v_sig_new) IS NULL THEN
        RAISE EXCEPTION 'Migration 250 postcondition failed: % was not created.', v_sig_new;
    END IF;

    IF has_function_privilege('public', v_sig_new, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 250 postcondition failed: % is executable by PUBLIC.', v_sig_new;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig_new, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 250 postcondition failed: % is not executable by ems_app.', v_sig_new;
    END IF;

    v_body_calc := lower(pg_get_functiondef(v_sig_calc::regprocedure));
    IF position('asset_points' IN v_body_calc) = 0 THEN
        RAISE EXCEPTION 'Migration 250 postcondition failed: calculate_demand_window must resolve ASSET scope via metadata.asset_points.';
    END IF;
    IF position('source_boundary' IN v_body_calc) = 0 THEN
        RAISE EXCEPTION 'Migration 250 postcondition failed: calculate_demand_window must produce the SOURCE_BOUNDARY quality_status.';
    END IF;

    SELECT lower(pg_get_functiondef(p.oid))
      INTO v_body_refresh
    FROM pg_proc p
    WHERE p.proname = 'refresh_demand_analytics'
      AND p.pronamespace = 'analytics'::regnamespace
    LIMIT 1;

    IF position('primary_meter' IN v_body_refresh) > 0 THEN
        RAISE EXCEPTION 'Migration 250 postcondition failed: refresh_demand_analytics must no longer reference PRIMARY_METER.';
    END IF;
    IF position('asset_points' IN v_body_refresh) = 0 THEN
        RAISE EXCEPTION 'Migration 250 postcondition failed: refresh_demand_analytics must enumerate/clean up via metadata.asset_points.';
    END IF;

    RAISE NOTICE 'Migration 250: all postconditions passed (Demand ASSET-scope attribution migrated to metadata.asset_points full-interval containment; PRIMARY_METER no longer referenced by calculate_demand_window or refresh_demand_analytics; SOURCE_BOUNDARY introduced for source/method changes mid-interval; SITE scope unaffected).';
END;
$post$;
