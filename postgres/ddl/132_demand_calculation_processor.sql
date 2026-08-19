-- 013_demand_calculation_processor.sql
-- Canonical demand calculation processor.
--
-- Uses the vendor-neutral capability resolver introduced by migration 012 and
-- computes SITE/ASSET demand without assuming a specific energy-meter vendor.
-- Supported execution methods:
--   * METER_NATIVE
--   * ENERGY_COUNTER_DELTA
--   * TIME_WEIGHTED_POWER
--
-- Final rows are written only after a fixed downstream-processing grace. The
-- demand policy late-arrival tolerance remains the event-eligibility deadline.
-- This keeps finalization stable while allowing the 5-minute normalization
-- pipeline to materialize eligible readings before the interval is frozen.

-- ---------------------------------------------------------------------------
-- 1. Wall-clock demand interval alignment in the site's local timezone.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.resolve_demand_interval(
    p_site_id UUID,
    p_interval_seconds INTEGER,
    p_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE (
    interval_start TIMESTAMPTZ,
    interval_end TIMESTAMPTZ,
    site_timezone TEXT
)
LANGUAGE SQL
STABLE
SET search_path TO pg_catalog, analytics, metadata
AS $function$
WITH context AS (
    SELECT COALESCE(s.timezone, 'UTC') AS timezone
    FROM metadata.sites AS s
    WHERE s.id = p_site_id
), local_clock AS (
    SELECT
        c.timezone,
        p_at AT TIME ZONE c.timezone AS local_at
    FROM context AS c
), aligned AS (
    SELECT
        lc.timezone,
        date_trunc('day', lc.local_at)
        + make_interval(
            secs => (
                floor(
                    extract(epoch FROM (lc.local_at - date_trunc('day', lc.local_at)))
                    / p_interval_seconds
                )::INTEGER * p_interval_seconds
            )
        ) AS local_start
    FROM local_clock AS lc
)
SELECT
    a.local_start AT TIME ZONE a.timezone,
    (a.local_start + make_interval(secs => p_interval_seconds)) AT TIME ZONE a.timezone,
    a.timezone
FROM aligned AS a
WHERE p_interval_seconds IN (900, 1800);
$function$;

COMMENT ON FUNCTION analytics.resolve_demand_interval(UUID, INTEGER, TIMESTAMPTZ) IS
'Resolves a 15/30-minute wall-clock demand interval in the configured site timezone.';

-- ---------------------------------------------------------------------------
-- 2. Calculate one explicit SITE/ASSET demand window.
--
-- p_window_end may be the scheduled interval end (final calculation) or an
-- earlier timestamp inside the interval (provisional/current calculation).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.calculate_demand_window(
    p_site_id UUID,
    p_scope_type TEXT,
    p_asset_id UUID,
    p_interval_start TIMESTAMPTZ,
    p_interval_end TIMESTAMPTZ,
    p_window_end TIMESTAMPTZ,
    p_final BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    organization_id UUID,
    site_id UUID,
    scope_type TEXT,
    asset_id UUID,
    demand_policy_id UUID,
    source_device_id UUID,
    demand_kw DOUBLE PRECISION,
    demand_kva DOUBLE PRECISION,
    peak_power_kw DOUBLE PRECISION,
    energy_kwh NUMERIC(20,6),
    source_method TEXT,
    expected_observations INTEGER,
    observed_observations INTEGER,
    coverage_percent NUMERIC(5,2),
    quality_status TEXT
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

    SELECT * INTO v_cap
    FROM analytics.resolve_demand_capability(
        p_site_id,
        upper(btrim(p_scope_type)),
        p_asset_id,
        p_interval_start + INTERVAL '1 microsecond'
    );

    IF v_cap.demand_policy_id IS NULL THEN
        RETURN QUERY SELECT
            v_org, p_site_id, upper(btrim(p_scope_type)),
            CASE WHEN upper(btrim(p_scope_type))='ASSET' THEN p_asset_id ELSE NULL::UUID END,
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
    -- Native meter demand. 012 guarantees basis, interval and wall-clock
    -- compatibility. One finalized native interval reading is sufficient.
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
    -- Cumulative energy-counter delta.
    -- Stored energy_measurements counters are already in canonical Wh/VAh.
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
    -- Time-weighted instantaneous power. Require at least three expected
    -- observations per demand interval and do not bridge gaps larger than
    -- 2.5x the configured site capture interval.
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

COMMENT ON FUNCTION analytics.calculate_demand_window(UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN) IS
'Calculates one canonical demand window using the method selected by migration 012. Handles native registers, cumulative counters and time-weighted power with explicit quality states.';

-- ---------------------------------------------------------------------------
-- 3. Refresh finalized intervals and provisional current state.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.refresh_demand_analytics(
    p_now TIMESTAMPTZ DEFAULT clock_timestamp(),
    p_lookback INTERVAL DEFAULT INTERVAL '3 hours'
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
    v_current RECORD;
    v_n INTEGER;
    v_max_n INTEGER;
BEGIN
    IF p_lookback IS NULL OR p_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_lookback must be positive.';
    END IF;

    FOR v_site IN
        SELECT DISTINCT p.site_id
        FROM config.site_demand_policies AS p
        WHERE p.effective_from <= p_now
          AND (p.effective_to IS NULL OR p.effective_to >= p_now-p_lookback-INTERVAL '30 minutes')
    LOOP
        SELECT * INTO v_policy
        FROM config.resolve_site_demand_policy(v_site.site_id,p_now);

        IF v_policy.policy_id IS NULL OR NOT COALESCE(v_policy.is_enabled,FALSE) THEN
            DELETE FROM analytics.demand_state WHERE site_id=v_site.site_id;
            CONTINUE;
        END IF;

        v_max_n := ceil(
            extract(epoch FROM p_lookback) / v_policy.demand_interval_seconds
        )::INTEGER + 2;

        FOR v_scope IN
            SELECT 'SITE'::TEXT AS scope_type, NULL::UUID AS asset_id
            UNION ALL
            SELECT 'ASSET'::TEXT, ad.asset_id
            FROM metadata.asset_devices AS ad
            JOIN metadata.assets AS a ON a.id=ad.asset_id
            WHERE a.site_id=v_site.site_id
              AND ad.relationship_type='PRIMARY_METER'
        LOOP
            -- Current provisional state.
            SELECT * INTO v_current
            FROM analytics.resolve_demand_interval(
                v_site.site_id,
                v_policy.demand_interval_seconds,
                p_now
            );

            IF v_current.interval_start >= v_policy.effective_from THEN
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
                            WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION')
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
                                WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION')
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
                                WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION')
                                    THEN v_calc.quality_status
                                ELSE 'PROVISIONAL'
                            END,
                            updated_at=clock_timestamp()
                        WHERE asset_id=v_scope.asset_id AND scope_type='ASSET';
                    END IF;
                END IF;
            END IF;

            -- Finalized historical intervals. Ten-minute processing grace is
            -- deliberately separate from the policy late-arrival allowance.
            FOR v_n IN 1..v_max_n LOOP
                SELECT * INTO v_interval
                FROM analytics.resolve_demand_interval(
                    v_site.site_id,
                    v_policy.demand_interval_seconds,
                    p_now - make_interval(secs => v_n*v_policy.demand_interval_seconds)
                );

                EXIT WHEN v_interval.interval_end < p_now-p_lookback;

                IF v_interval.interval_start < v_policy.effective_from THEN
                    CONTINUE;
                END IF;
                IF v_policy.effective_to IS NOT NULL
                   AND v_interval.interval_end > v_policy.effective_to THEN
                    CONTINUE;
                END IF;
                IF v_interval.interval_end
                   + make_interval(secs => COALESCE(v_policy.late_arrival_tolerance_seconds,0))
                   + INTERVAL '10 minutes' > p_now THEN
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
                ON CONFLICT DO NOTHING;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$procedure$;

COMMENT ON PROCEDURE analytics.refresh_demand_analytics(TIMESTAMPTZ,INTERVAL) IS
'Refreshes provisional current demand state and finalizes stable SITE/ASSET demand intervals over a bounded lookback.';

-- ---------------------------------------------------------------------------
-- 4. TimescaleDB job wrapper and scheduler registration.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.run_demand_calculation_job(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
SET search_path TO pg_catalog, analytics
AS $procedure$
DECLARE
    v_lookback INTERVAL := INTERVAL '3 hours';
BEGIN
    IF config ? 'lookback' THEN
        v_lookback := (config->>'lookback')::INTERVAL;
    END IF;
    CALL analytics.refresh_demand_analytics(clock_timestamp(),v_lookback);
END;
$procedure$;

DO $block$
DECLARE
    v_job_id INTEGER;
BEGIN
    SELECT j.job_id INTO v_job_id
    FROM timescaledb_information.jobs AS j
    WHERE j.proc_schema='analytics'
      AND j.proc_name='run_demand_calculation_job'
    ORDER BY j.job_id
    LIMIT 1;

    IF v_job_id IS NULL THEN
        SELECT add_job(
            'analytics.run_demand_calculation_job',
            INTERVAL '1 minute',
            config => '{"lookback":"3 hours"}'::JSONB
        ) INTO v_job_id;
    ELSE
        PERFORM alter_job(
            v_job_id,
            schedule_interval => INTERVAL '1 minute',
            config => '{"lookback":"3 hours"}'::JSONB,
            scheduled => TRUE
        );
    END IF;
END;
$block$;

-- ---------------------------------------------------------------------------
-- 5. Ownership and read boundaries.
-- ---------------------------------------------------------------------------
ALTER FUNCTION analytics.resolve_demand_interval(UUID,INTEGER,TIMESTAMPTZ) OWNER TO ems_admin;
ALTER FUNCTION analytics.calculate_demand_window(UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN) OWNER TO ems_admin;
ALTER PROCEDURE analytics.refresh_demand_analytics(TIMESTAMPTZ,INTERVAL) OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_demand_calculation_job(INTEGER,JSONB) OWNER TO ems_admin;

REVOKE ALL ON FUNCTION analytics.resolve_demand_interval(UUID,INTEGER,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.calculate_demand_window(UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN) FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.refresh_demand_analytics(TIMESTAMPTZ,INTERVAL) FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.run_demand_calculation_job(INTEGER,JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION analytics.resolve_demand_interval(UUID,INTEGER,TIMESTAMPTZ) TO ems_app,ems_readonly,grafana_reader;
GRANT EXECUTE ON FUNCTION analytics.calculate_demand_window(UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN) TO ems_readonly;
GRANT EXECUTE ON PROCEDURE analytics.refresh_demand_analytics(TIMESTAMPTZ,INTERVAL) TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.run_demand_calculation_job(INTEGER,JSONB) TO ems_admin;
