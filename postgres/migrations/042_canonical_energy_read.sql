-- ============================================================================
-- Migration 042
-- Canonical energy reader (production)
--
-- Purpose:
--   Introduce the first production canonical energy read contract:
--   tenant-safe resolution of asset -> PRIMARY_METER -> device -> gateway ->
--   site -> native capture capability -> requested/actual reporting
--   resolution -> already-classified semantic energy, in one call.
--
-- This is the production counterpart of the TEST-DB-only prototype
-- (analytics.resolve_canonical_energy_reader_lookup_testonly and
-- analytics.get_canonical_energy_read_testonly), validated end to end in
-- TEST DB across native/5m/15m/1h/1d, native fallback, strict-unavailable,
-- tenant isolation, missing-asset/missing-PRIMARY_METER, and historical
-- capture-policy boundaries. Self-contained: does not call either
-- TEST-ONLY helper (neither exists in production, and this migration does
-- not introduce them there) -- tenant/resolution logic is inlined below,
-- and the resolution-tier width mapping is an inline VALUES list rather
-- than a physical lookup table, so this migration creates exactly one
-- production object: analytics.get_canonical_energy_read.
--
-- Sources by actual_resolution (never routed by capture_interval_seconds):
--   native -> analytics.v_energy_consumption_native
--   5m     -> analytics.v_energy_reporting_5min
--   15m    -> analytics.v_energy_reporting_15min
--   1h     -> analytics.v_energy_reporting_hourly   (migration 041)
--   1d     -> analytics.v_energy_reporting_daily
--
-- Capture policy (config.telemetry_capture_policies via
-- telemetry.resolve_site_capture_bucket) is used only to establish native
-- capability and to detect a genuine capture-policy change inside
-- [p_from, p_to); it is never used to select a physical source.
--
-- No cumulative-register classification occurs in this function. Every
-- source above is already-classified; consumption is always a valid-only
-- sum, with invalid/gap/reset/rollover coverage exposed as counters
-- rather than collapsing the whole bucket.
-- ============================================================================


CREATE OR REPLACE FUNCTION analytics.get_canonical_energy_read(
    p_grafana_org_id       BIGINT,
    p_asset_id             UUID,
    p_from                 TIMESTAMPTZ,
    p_to                   TIMESTAMPTZ,
    p_requested_resolution TEXT,
    p_fallback_policy      TEXT DEFAULT 'native'
)
RETURNS TABLE (
    requested_resolution       TEXT,
    resolution                 TEXT,
    native_resolution_seconds  INTEGER,
    interval_start              TIMESTAMPTZ,
    interval_end                TIMESTAMPTZ,
    resolved_device_id         UUID,
    device_name                 TEXT,

    import_consumption_kwh      NUMERIC,
    export_consumption_kwh      NUMERIC,

    import_quality_status       TEXT,
    export_quality_status       TEXT,

    source_interval_count       BIGINT,
    valid_import_intervals      BIGINT,
    invalid_import_intervals    BIGINT,
    valid_export_intervals      BIGINT,
    invalid_export_intervals    BIGINT,
    coverage_ratio               NUMERIC,

    gap_interval_count           BIGINT,
    reset_interval_count         BIGINT,
    rollover_interval_count      BIGINT,
    invalid_interval_count       BIGINT,

    first_native_bucket_start   TIMESTAMPTZ,
    last_native_bucket_start    TIMESTAMPTZ,
    is_partial_bucket            BOOLEAN,

    fallback_applied             BOOLEAN,
    fallback_reason               TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    analytics,
    metadata,
    telemetry,
    config
AS $function$
DECLARE
    v_device_id                 UUID;
    v_site_id                   UUID;
    v_device_name                TEXT;

    v_policy_id                  BIGINT;
    v_capture_interval_seconds   INTEGER;
    v_native_duration            INTERVAL;
    v_boundary_time               TIMESTAMPTZ;
    v_boundary_policy_id          BIGINT;

    v_requested_width            INTERVAL;
    v_native_matches             TEXT;

    v_actual                     TEXT;
    v_fallback_applied           BOOLEAN;
    v_fallback_reason            TEXT;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION
            'p_to (%) must be later than p_from (%)', p_to, p_from;
    END IF;

    IF p_requested_resolution IS NULL THEN
        RAISE EXCEPTION 'p_requested_resolution is required';
    END IF;

    IF p_fallback_policy IS NULL THEN
        p_fallback_policy := 'native';
    END IF;

    IF p_fallback_policy NOT IN ('native', 'coarser', 'strict') THEN
        RAISE EXCEPTION
            'p_fallback_policy must be one of ''native'', ''coarser'', '
            '''strict'', got %', p_fallback_policy;
    END IF;

    IF p_requested_resolution != 'native'
        AND p_requested_resolution NOT IN ('5m', '15m', '1h', '1d')
    THEN
        RAISE EXCEPTION
            'unknown requested resolution %; must be ''native'', ''5m'', '
            '''15m'', ''1h'' or ''1d''', p_requested_resolution;
    END IF;

    -- ------------------------------------------------------------------
    -- Tenant authorization + asset + PRIMARY_METER device + gateway + site.
    --
    -- The existing proven Grafana pattern: grafana_organization_map ->
    -- organization -> asset -> asset_devices, extended by one hop to
    -- gateway -> site. Tenant mismatch, a non-existent asset, an asset
    -- with no PRIMARY_METER, and a device with no gateway all collapse to
    -- zero rows -- consistent with analytics.get_grafana_asset_energy_intervals
    -- -- so this never leaks *why* resolution failed.
    -- ------------------------------------------------------------------

    SELECT
        d.id,
        g.site_id,
        d.name
    INTO
        v_device_id,
        v_site_id,
        v_device_name
    FROM metadata.grafana_organization_map AS gom

    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id

    JOIN metadata.asset_devices AS ad
      ON ad.asset_id = a.id
     AND ad.relationship_type = 'PRIMARY_METER'

    JOIN metadata.devices AS d
      ON d.id = ad.device_id

    JOIN metadata.gateways AS g
      ON g.id = d.gateway_id

    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id

    LIMIT 1;

    IF v_device_id IS NULL THEN
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- Native capture capability, resolved at p_from.
    -- ------------------------------------------------------------------

    SELECT
        b.policy_id,
        b.capture_interval_seconds
    INTO
        v_policy_id,
        v_capture_interval_seconds
    FROM telemetry.resolve_site_capture_bucket(v_site_id, p_from) AS b;

    IF v_policy_id IS NULL THEN
        RAISE EXCEPTION
            'no capture policy resolvable for site % at %', v_site_id, p_from;
    END IF;

    -- ------------------------------------------------------------------
    -- Historical-time safety: reject ranges that cross a genuine
    -- capture-policy change rather than silently applying the policy in
    -- force at either endpoint. Re-resolves the actual policy (via
    -- telemetry.resolve_site_capture_bucket itself -- its precedence
    -- logic is never duplicated here) at every candidate transition
    -- instant inside (p_from, p_to); only a real change in what resolves
    -- triggers rejection, so an unrelated platform-default transition
    -- shadowed by a site-specific policy does not cause a false reject.
    -- ------------------------------------------------------------------

    FOR v_boundary_time IN
        SELECT DISTINCT t
        FROM (
            SELECT effective_from AS t
            FROM config.telemetry_capture_policies
            WHERE is_enabled
              AND (site_id = v_site_id OR site_id IS NULL)

            UNION

            SELECT effective_to AS t
            FROM config.telemetry_capture_policies
            WHERE is_enabled
              AND (site_id = v_site_id OR site_id IS NULL)
              AND effective_to IS NOT NULL
        ) AS candidates
        WHERE t > p_from
          AND t < p_to
        ORDER BY t
    LOOP
        SELECT b.policy_id
        INTO v_boundary_policy_id
        FROM telemetry.resolve_site_capture_bucket(v_site_id, v_boundary_time) AS b;

        IF v_boundary_policy_id IS DISTINCT FROM v_policy_id THEN
            RAISE EXCEPTION
                'requested range [%, %) crosses a capture-policy change for '
                'site % at %; cross-policy historical reads are not yet '
                'supported',
                p_from, p_to, v_site_id, v_boundary_time;
        END IF;
    END LOOP;

    v_native_duration := make_interval(secs => v_capture_interval_seconds);

    -- ------------------------------------------------------------------
    -- requested -> actual reporting resolution. Compares ACTUAL DURATIONS,
    -- never strings. The resolution-tier width mapping is an inline
    -- VALUES list (not a physical table) so this migration creates only
    -- one production object.
    -- ------------------------------------------------------------------

    IF p_requested_resolution = 'native' THEN
        v_actual            := 'native';
        v_fallback_applied  := FALSE;
        v_fallback_reason   := NULL;
    ELSE
        SELECT bucket_width
        INTO v_requested_width
        FROM (
            VALUES
                ('5m',  INTERVAL '5 minutes'),
                ('15m', INTERVAL '15 minutes'),
                ('1h',  INTERVAL '1 hour'),
                ('1d',  INTERVAL '1 day')
        ) AS t(resolution_key, bucket_width)
        WHERE resolution_key = p_requested_resolution;

        IF v_requested_width >= v_native_duration THEN
            v_actual            := p_requested_resolution;
            v_fallback_applied  := FALSE;
            v_fallback_reason   := NULL;
        ELSIF p_fallback_policy = 'strict' THEN
            v_actual            := NULL;
            v_fallback_applied  := FALSE;
            v_fallback_reason   := 'requested_resolution_finer_than_native_and_policy_is_strict';
        ELSE
            SELECT resolution_key
            INTO v_native_matches
            FROM (
                VALUES
                    ('5m',  INTERVAL '5 minutes'),
                    ('15m', INTERVAL '15 minutes'),
                    ('1h',  INTERVAL '1 hour'),
                    ('1d',  INTERVAL '1 day')
            ) AS t(resolution_key, bucket_width)
            WHERE bucket_width = v_native_duration;

            v_actual            := COALESCE(v_native_matches, 'native');
            v_fallback_applied  := TRUE;
            v_fallback_reason   := 'requested_resolution_finer_than_native';
        END IF;
    END IF;

    -- ------------------------------------------------------------------
    -- Strict-unavailable: preserve resolved metadata, fabricate no data.
    -- ------------------------------------------------------------------

    IF v_actual IS NULL THEN
        RETURN QUERY SELECT
            p_requested_resolution,
            NULL::TEXT,
            v_capture_interval_seconds,
            NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ,
            v_device_id,
            v_device_name,
            NULL::NUMERIC,
            NULL::NUMERIC,
            NULL::TEXT,
            NULL::TEXT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::NUMERIC,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::BIGINT,
            NULL::TIMESTAMPTZ,
            NULL::TIMESTAMPTZ,
            NULL::BOOLEAN,
            v_fallback_applied,
            v_fallback_reason;
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- NATIVE: analytics.v_energy_consumption_native. One row per already-
    -- classified native interval. No aggregation, no reclassification.
    -- ------------------------------------------------------------------

    IF v_actual = 'native' THEN
        RETURN QUERY
        SELECT
            p_requested_resolution,
            'native'::TEXT,
            v_capture_interval_seconds,
            n.bucket_start,
            n.bucket_start + make_interval(secs => n.native_resolution_seconds),
            v_device_id,
            v_device_name,

            n.import_consumption_kwh,
            n.export_consumption_kwh,

            CASE
                WHEN NOT n.import_is_valid THEN 'INVALID_INTERVALS'
                WHEN n.import_reset_detected THEN 'RESET_DETECTED'
                WHEN n.import_quality_code = 'GAP' THEN 'GAPS_DETECTED'
                WHEN n.import_rollover_detected THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN NOT n.export_is_valid THEN 'INVALID_INTERVALS'
                WHEN n.export_reset_detected THEN 'RESET_DETECTED'
                WHEN n.export_quality_code = 'GAP' THEN 'GAPS_DETECTED'
                WHEN n.export_rollover_detected THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            1::BIGINT,
            n.import_is_valid::INT::BIGINT,
            (NOT n.import_is_valid)::INT::BIGINT,
            n.export_is_valid::INT::BIGINT,
            (NOT n.export_is_valid)::INT::BIGINT,
            1.0::NUMERIC,

            n.gap_detected::INT::BIGINT,
            n.reset_detected::INT::BIGINT,
            n.rollover_detected::INT::BIGINT,
            n.invalid_detected::INT::BIGINT,

            n.bucket_start,
            n.bucket_start,
            FALSE,

            v_fallback_applied,
            v_fallback_reason

        FROM analytics.v_energy_consumption_native n
        WHERE n.device_id = v_device_id
          AND n.bucket_start >= p_from
          AND n.bucket_start < p_to
        ORDER BY n.bucket_start;
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 5m / 15m: analytics.v_energy_reporting_5min / _15min. Already
    -- tenant-scoped (security_barrier views joined to
    -- grafana_organization_map); device_id filter additionally applied
    -- since tenant was already proven above.
    -- ------------------------------------------------------------------

    IF v_actual IN ('5m', '15m') THEN
        RETURN QUERY
        SELECT
            p_requested_resolution,
            v_actual,
            v_capture_interval_seconds,
            r.bucket_start,
            r.bucket_start + (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END),
            v_device_id,
            v_device_name,

            r.import_consumption_kwh,
            r.export_consumption_kwh,

            CASE
                WHEN r.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN r.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN r.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN r.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN r.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN r.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN r.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN r.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            r.source_interval_count,
            r.valid_import_intervals,
            r.invalid_import_intervals,
            r.valid_export_intervals,
            r.invalid_export_intervals,

            (
                r.source_interval_count::NUMERIC
                / NULLIF(
                    (CASE WHEN v_actual = '5m' THEN 300 ELSE 900 END) / v_capture_interval_seconds,
                    0
                )
            ),

            r.gap_interval_count,
            r.reset_interval_count,
            r.rollover_interval_count,
            r.invalid_interval_count,

            r.first_native_bucket_start,
            r.last_native_bucket_start,

            (
                r.source_interval_count < (CASE WHEN v_actual = '5m' THEN 300 ELSE 900 END) / v_capture_interval_seconds
                OR r.bucket_start < p_from
                OR r.bucket_start + (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END) > p_to
            ),

            v_fallback_applied,
            v_fallback_reason

        FROM (
            SELECT * FROM analytics.v_energy_reporting_5min WHERE v_actual = '5m'
            UNION ALL
            SELECT * FROM analytics.v_energy_reporting_15min WHERE v_actual = '15m'
        ) r
        WHERE r.device_id = v_device_id
          AND r.grafana_org_id = p_grafana_org_id
          AND r.bucket_start >= date_bin(
                  (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END),
                  p_from,
                  TIMESTAMPTZ '2000-01-01 00:00:00+00'
              )
          AND r.bucket_start < p_to
        ORDER BY r.bucket_start;
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 1h: analytics.v_energy_reporting_hourly (migration 041). Already
    -- tenant-scoped, site-timezone-aware, aggregated exclusively from the
    -- validated 15-minute semantic contract. bucket_start is already a
    -- real TIMESTAMPTZ (site-local hour start), so this mirrors the 1d
    -- branch's direct-instant overlap filtering rather than 5m/15m's
    -- date_bin pre-filter.
    -- ------------------------------------------------------------------

    IF v_actual = '1h' THEN
        RETURN QUERY
        SELECT
            p_requested_resolution,
            '1h'::TEXT,
            v_capture_interval_seconds,
            h.bucket_start,
            h.bucket_start + INTERVAL '1 hour',
            v_device_id,
            v_device_name,

            h.import_consumption_kwh,
            h.export_consumption_kwh,

            CASE
                WHEN h.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN h.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN h.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN h.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN h.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN h.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN h.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN h.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            h.source_interval_count::BIGINT,
            h.valid_import_intervals::BIGINT,
            h.invalid_import_intervals::BIGINT,
            h.valid_export_intervals::BIGINT,
            h.invalid_export_intervals::BIGINT,

            (h.source_interval_count::NUMERIC / NULLIF(3600 / v_capture_interval_seconds, 0)),

            h.gap_interval_count::BIGINT,
            h.reset_interval_count::BIGINT,
            h.rollover_interval_count::BIGINT,
            h.invalid_interval_count::BIGINT,

            h.first_native_bucket_start,
            h.last_native_bucket_start,

            (
                h.source_interval_count < 3600 / v_capture_interval_seconds
                OR h.bucket_start < p_from
                OR h.bucket_start + INTERVAL '1 hour' > p_to
            ),

            v_fallback_applied,
            v_fallback_reason

        FROM analytics.v_energy_reporting_hourly h
        WHERE h.device_id = v_device_id
          AND h.grafana_org_id = p_grafana_org_id
          AND h.bucket_start < p_to
          AND h.bucket_start + INTERVAL '1 hour' > p_from
        ORDER BY h.bucket_start;
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 1d: analytics.v_energy_reporting_daily. Site-timezone-aware,
    -- aggregated from the validated 15-minute semantic contract.
    -- ------------------------------------------------------------------

    IF v_actual = '1d' THEN
        RETURN QUERY
        SELECT
            p_requested_resolution,
            '1d'::TEXT,
            v_capture_interval_seconds,
            (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone),
            (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day',
            v_device_id,
            v_device_name,

            d.import_consumption_kwh,
            d.export_consumption_kwh,

            CASE
                WHEN d.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN d.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN d.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN d.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN d.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN d.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN d.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN d.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            d.source_interval_count::BIGINT,
            d.valid_import_intervals::BIGINT,
            d.invalid_import_intervals::BIGINT,
            d.valid_export_intervals::BIGINT,
            d.invalid_export_intervals::BIGINT,

            -- Nominal 86400s day length; does not correct for DST transitions.
            (d.source_interval_count::NUMERIC / NULLIF(86400 / v_capture_interval_seconds, 0)),

            d.gap_interval_count::BIGINT,
            d.reset_interval_count::BIGINT,
            d.rollover_interval_count::BIGINT,
            d.invalid_interval_count::BIGINT,

            d.first_native_bucket_start,
            d.last_native_bucket_start,

            (
                d.source_interval_count < 86400 / v_capture_interval_seconds
                OR (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) < p_from
                OR (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day' > p_to
            ),

            v_fallback_applied,
            v_fallback_reason

        FROM analytics.v_energy_reporting_daily d
        WHERE d.device_id = v_device_id
          AND d.grafana_org_id = p_grafana_org_id
          AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) < p_to
          AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day' > p_from
        ORDER BY d.consumption_date;
        RETURN;
    END IF;

    RAISE EXCEPTION
        'unhandled actual_resolution %; canonical reader has no dispatch '
        'branch for this resolution tier',
        v_actual;
END;
$function$;


ALTER FUNCTION analytics.get_canonical_energy_read(
    BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT
)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.get_canonical_energy_read(
    BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT
)
FROM PUBLIC;


-- Matches the deferred-grant posture of the sources it reads
-- (v_energy_reporting_5min/15min/hourly/daily currently grant only
-- ems_admin). Consumer grants (ems_app, ems_readonly, grafana_reader) are
-- deferred until this contract is wired into a real consumer.

GRANT EXECUTE
ON FUNCTION analytics.get_canonical_energy_read(
    BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT
)
TO ems_admin;


COMMENT ON FUNCTION analytics.get_canonical_energy_read(
    BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT
) IS
'Canonical tenant-safe energy read contract: resolves grafana_organization_map -> asset -> PRIMARY_METER -> device -> gateway -> site -> native capture capability -> requested/actual reporting resolution, then reads already-classified semantic energy from the resolution-appropriate reporting contract (native/5m/15m/1h/1d). Never routes on capture_interval_seconds; never reclassifies cumulative registers; never reads raw MAX/MIN continuous aggregates.';
