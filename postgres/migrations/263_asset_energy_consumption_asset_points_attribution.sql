-- ============================================================================
-- Migration 263
-- Asset Energy Consumption -- Option A attribution migration. Replaces
-- analytics.get_canonical_energy_read's PRIMARY_METER-based device
-- resolution with metadata.asset_points/telemetry-derived attribution, per
-- ADR-018 Amendments 1/2/4/7 (docs/00-governance/decisions/ADR-018-asset-
-- point-assignment-and-commissioning.md). Mirrors migration 249's Asset
-- Power Trend correction; approved design from this session's read-only
-- investigation + design report.
--
-- REBASED ONTO MIGRATION 269 (ADR-020 PR2, read-side hardening), which is
-- applied before this migration in every environment (manifest order).
-- The 269 measured-vs-reconstructed semantics are re-applied here to the
-- separate import (i.) / export (e.) row sets -- per direction, in every
-- tier:
--   * native: a synthetic row's non-reconstructed direction reports
--     INVALID_INTERVALS; a reconstructed direction reports
--     RECONSTRUCTED_TIMING (after GAPS_DETECTED); source_interval_count,
--     valid/invalid counts, coverage and gap/reset/rollover counters are
--     measured-only (is_measured_interval, *_is_interior).
--   * 5m/15m, 1h, 1d: RECONSTRUCTED_TIMING when the direction has
--     reconstructed intervals (after GAPS_DETECTED); INVALID_INTERVALS --
--     never GOOD -- when it has neither measured nor reconstructed
--     intervals. Counters/coverage come from the 269 views (measured-
--     only).
--   With no reconstructed rows every output equals this migration's
--   original (pre-269-semantics) asset_points behavior.
--
-- Findings this migration acts on:
--   * The function's only device-resolution dependency was a single early
--     query resolving p_asset_id -> device_id via metadata.asset_devices
--     WHERE relationship_type = 'PRIMARY_METER' LIMIT 1, then filtering
--     every one of the five resolution-tier branches (native/5m/15m/1h/1d)
--     by that single device_id. Per ADR-018 Amendment 1/4, attribution must
--     come from metadata.asset_points, never PRIMARY_METER.
--   * Per migration 254 (config.canonical_measurement_groups), ENERGY_IMPORT
--     and ENERGY_EXPORT are INDEPENDENT canonical measurement groups and may
--     legitimately be confirmed on DIFFERENT devices for the same asset.
--     The existing device-keyed aggregate views (v_energy_consumption_
--     native, v_energy_reporting_5min/15min/hourly/daily) each carry both
--     import_consumption_kwh and export_consumption_kwh on one device-keyed
--     row, so a single resolved device can no longer be assumed to serve
--     both directions. This migration resolves Import and Export windows
--     independently (via the new shared helper below) and combines them
--     per-interval with a FULL OUTER JOIN -- never summing, never cross-
--     attributing either direction's reading to the other direction's
--     device.
--   * Source replacement mid-range uses the same GREATEST/LEAST window-
--     clipping semantics as migration 249: a replacement yields two (or
--     more) window rows per direction, each contributing only its own
--     effective slice. Bucket matching against a source window is
--     OVERLAP-based (bucket_start < window_to AND bucket_end > window_from)
--     for EVERY resolution tier, not start-containment: a binding's
--     effective_from is essentially never aligned to a bucket boundary (an
--     admin confirms an assignment at an arbitrary wall-clock instant, not
--     on a 5-minute/hour/day grid), so requiring the bucket to START at or
--     after window_from would wrongly exclude the very bucket containing
--     that instant -- not a narrow edge case, but the ordinary case for
--     every confirmed assignment. Each import_rows/export_rows CTE uses
--     SELECT DISTINCT ON (bucket) ... ORDER BY bucket, window_from DESC to
--     guarantee at most one row per bucket even when a replacement cutover
--     falls inside a single coarse bucket (rare): the incoming device's
--     window (the later window_from) wins that one straddling bucket,
--     rather than fanning out into two ambiguous/duplicate rows -- the
--     cross-attribution this migration must not produce. The original
--     request-boundary filters (date_bin pre-alignment for native/5m/15m;
--     bucket_start < p_to AND bucket_end > v_effective_from for 1h/1d) are
--     preserved unchanged, in addition to the source-window overlap check.
--   * Contract decisions (this session, explicit):
--       - Response shape and signature are unchanged.
--       - resolved_device_id/device_name represent the IMPORT-side source
--         device only (the asset_points-confirmed ENERGY_IMPORT_TOTAL
--         binding with the latest effective_from within the requested
--         window), for backward compatibility. They must not be read as
--         "the asset's single energy device" -- when Export is confirmed on
--         a different device, that device is not reflected in these two
--         columns.
--       - The existing non-direction-specific diagnostic columns
--         (source_interval_count, coverage_ratio, gap_interval_count,
--         reset_interval_count, rollover_interval_count,
--         invalid_interval_count, first_native_bucket_start,
--         last_native_bucket_start, is_partial_bucket) are sourced from the
--         IMPORT side only, for backward compatibility -- no sums/averages
--         across the two directions are invented. When there is no Import
--         data for a given output row (Import unconfirmed, or confirmed but
--         with no matching data for that interval), these columns are NULL,
--         never a fabricated zero -- except is_partial_bucket in the native
--         tier, which stays the unconditional FALSE it always was (a
--         structural property of native-resolution buckets, never data-
--         derived).
--       - Direction-specific columns (import_quality_status,
--         export_quality_status, valid_import_intervals,
--         invalid_import_intervals, valid_export_intervals,
--         invalid_export_intervals, import_consumption_kwh,
--         export_consumption_kwh) are always sourced independently from
--         their own resolved measurement.
--       - A single confirmed direction is valid: if only one of Import/
--         Export has a confirmed asset_points binding, the function returns
--         that direction's data with the other direction's columns NULL,
--         never requiring both directions to be confirmed.
--   * v_site_id (needed for capture-policy resolution) is now resolved
--     directly from metadata.assets.site_id via the tenant/org join, rather
--     than via a PRIMARY_METER device's gateway. This is an intentional,
--     necessary part of removing the PRIMARY_METER dependency: site
--     resolution -- and therefore capture-policy resolvability -- no longer
--     requires the asset to have ANY device relationship at all. The
--     existing "mismatched tenant / nonexistent asset -> zero rows, no
--     error" semantics are preserved exactly; only the resolution path
--     changed.
--
-- What this migration does NOT do (explicit, per instruction):
--   * Does NOT alter any of the five underlying aggregate views
--     (v_energy_consumption_native, v_energy_reporting_5min/15min/hourly/
--     daily) -- they remain device-keyed exactly as-is; only how this
--     function joins against them changes.
--   * Does NOT change ingestion, telemetry.energy_measurements,
--     metadata.asset_devices, or PRIMARY_METER's schema/constraints.
--   * Does NOT change analytics.get_grafana_asset_energy_intervals or
--     analytics.get_portal_asset_energy_intervals -- both are thin wrappers
--     with no PRIMARY_METER dependency of their own; they are unaffected by
--     this migration's signature-preserving change.
--   * Does NOT change any other analytics path (Demand, Power Trend, PQ).
--   * Does NOT change the function's signature or RETURNS TABLE shape.
--
-- Rollback: re-apply migration 200's CREATE OR REPLACE FUNCTION body
-- (PRIMARY_METER-based) and DROP FUNCTION
-- analytics.resolve_asset_energy_source_windows(uuid, text, timestamptz,
-- timestamptz) -- safe, no other object is altered by this migration.
--
-- Tests: scripts/test/assert_canonical_energy_read_asset_points_attribution.sh
-- (new; covers all required regression scenarios including the different-
-- device Import/Export case). scripts/test/
-- assert_canonical_energy_read_pre_policy_range.sql (migration 200's test)
-- is updated in this migration's changeset to add the metadata.asset_points
-- bindings this rewritten function now requires -- its PRIMARY_METER
-- fixture rows are left in place as harmless, now-unused metadata, per
-- minimal-diff preference; its assertions are otherwise unchanged.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 263 precondition failed: analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text) is missing (migration 042/200).';
    END IF;

    IF to_regclass('metadata.asset_points') IS NULL THEN
        RAISE EXCEPTION 'Migration 263 precondition failed: metadata.asset_points is missing (migration 224).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata' AND table_name = 'asset_points'
          AND column_name = 'device_id'
    ) THEN
        RAISE EXCEPTION 'Migration 263 precondition failed: metadata.asset_points.device_id is missing (migration 228).';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL') THEN
        RAISE EXCEPTION 'Migration 263 precondition failed: metadata.logical_points has no ENERGY_IMPORT_TOTAL row.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM metadata.logical_points WHERE name = 'ENERGY_EXPORT_TOTAL') THEN
        RAISE EXCEPTION 'Migration 263 precondition failed: metadata.logical_points has no ENERGY_EXPORT_TOTAL row.';
    END IF;

    IF to_regclass('analytics.v_energy_consumption_native') IS NULL
       OR to_regclass('analytics.v_energy_reporting_5min') IS NULL
       OR to_regclass('analytics.v_energy_reporting_15min') IS NULL
       OR to_regclass('analytics.v_energy_reporting_hourly') IS NULL
       OR to_regclass('analytics.v_energy_reporting_daily') IS NULL
    THEN
        RAISE EXCEPTION 'Migration 263 precondition failed: one or more of the five energy reporting views is missing.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id = '269_energy_reconstruction_read_hardening')
       OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'analytics'
                      AND table_name = 'v_energy_consumption_native' AND column_name = 'is_measured_interval')
       OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'analytics'
                      AND table_name = 'v_energy_reporting_daily' AND column_name = 'export_reconstructed_intervals') THEN
        RAISE EXCEPTION 'Migration 263 precondition failed: migration 269 (ADR-020 read-side hardening) must be applied first -- this migration re-applies its semantics.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.resolve_asset_energy_source_windows(uuid, text, timestamptz,
--    timestamptz). Shared, reusable resolver -- generalizes migration 249's
--    assigned_points CTE into a named function so the five resolution-tier
--    branches below call it (once per direction) instead of each
--    duplicating the GREATEST/LEAST windowing logic. Internal helper only:
--    not SECURITY DEFINER (runs under its SECURITY DEFINER caller's already-
--    switched role), not granted beyond its owner.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.resolve_asset_energy_source_windows
(
    p_asset_id            UUID,
    p_logical_point_name  TEXT,
    p_from                TIMESTAMPTZ,
    p_to                  TIMESTAMPTZ
)
RETURNS TABLE
(
    device_id   UUID,
    window_from TIMESTAMPTZ,
    window_to   TIMESTAMPTZ
)
LANGUAGE SQL
STABLE
SET search_path TO pg_catalog, analytics, metadata
AS $function$
    -- One row per asset_points binding for the given logical point name
    -- whose effective range overlaps [p_from, p_to). GREATEST/LEAST clip
    -- each binding's window to both the request range and its own
    -- effective_from/effective_to, so a source replacement mid-range yields
    -- two (or more) rows, each contributing only its own slice.
    SELECT
        ap.device_id,
        GREATEST(ap.effective_from, p_from) AS window_from,
        LEAST(COALESCE(ap.effective_to, 'infinity'::TIMESTAMPTZ), p_to) AS window_to
    FROM metadata.asset_points AS ap
    JOIN metadata.logical_points AS lp ON lp.id = ap.logical_point_id
    WHERE ap.asset_id = p_asset_id
      AND lp.name = p_logical_point_name
      AND ap.effective_from < p_to
      AND (ap.effective_to IS NULL OR ap.effective_to > p_from);
$function$;

ALTER FUNCTION analytics.resolve_asset_energy_source_windows(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.resolve_asset_energy_source_windows(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION analytics.resolve_asset_energy_source_windows(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) IS
'Shared effective-dated asset_points window resolver, parameterized by logical point name. Returns one (device_id, window_from, window_to) row per confirmed binding overlapping the request range, clipped to both the binding''s own effective range and the request range. Internal helper for analytics.get_canonical_energy_read; not independently granted.';


-- ----------------------------------------------------------------------------
-- 2. analytics.get_canonical_energy_read(...). Same signature and RETURNS
--    TABLE shape as migration 200. Import and Export are resolved
--    independently via the helper above and combined per-interval with a
--    FULL OUTER JOIN against each tier's existing aggregate view -- the
--    views themselves are untouched.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_canonical_energy_read(p_grafana_org_id bigint, p_asset_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_requested_resolution text, p_fallback_policy text DEFAULT 'native'::text)
 RETURNS TABLE(requested_resolution text, resolution text, native_resolution_seconds integer, interval_start timestamp with time zone, interval_end timestamp with time zone, resolved_device_id uuid, device_name text, import_consumption_kwh numeric, export_consumption_kwh numeric, import_quality_status text, export_quality_status text, source_interval_count bigint, valid_import_intervals bigint, invalid_import_intervals bigint, valid_export_intervals bigint, invalid_export_intervals bigint, coverage_ratio numeric, gap_interval_count bigint, reset_interval_count bigint, rollover_interval_count bigint, invalid_interval_count bigint, first_native_bucket_start timestamp with time zone, last_native_bucket_start timestamp with time zone, is_partial_bucket boolean, fallback_applied boolean, fallback_reason text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'metadata', 'telemetry', 'config'
AS $function$
DECLARE
    -- Represents the IMPORT-side source device only (see migration 263
    -- header). Never "the asset's single energy device" -- Export may be
    -- confirmed on a different device and is not reflected here.
    v_device_id                 UUID;
    v_site_id                   UUID;
    v_device_name                TEXT;

    v_policy_id                  BIGINT;
    v_capture_interval_seconds   INTEGER;
    v_native_duration            INTERVAL;
    v_boundary_time               TIMESTAMPTZ;
    v_boundary_capture_interval_seconds INTEGER;

    v_earliest_applicable_from   TIMESTAMPTZ;
    v_effective_from             TIMESTAMPTZ;

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
    -- Tenant authorization + asset + site. Resolved directly from
    -- metadata.assets.site_id -- no device-relationship dependency at all
    -- (see migration 263 header for why). A tenant mismatch or a
    -- nonexistent asset collapses to zero rows, exactly as before; this no
    -- longer additionally requires the asset to have any device relationship.
    -- ------------------------------------------------------------------

    SELECT
        a.site_id
    INTO
        v_site_id
    FROM metadata.grafana_organization_map AS gom

    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id

    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id;

    IF v_site_id IS NULL THEN
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- Native capture capability, resolved at p_from.
    -- ------------------------------------------------------------------

    v_effective_from := p_from;

    SELECT
        b.policy_id,
        b.capture_interval_seconds
    INTO
        v_policy_id,
        v_capture_interval_seconds
    FROM telemetry.resolve_site_capture_bucket(v_site_id, v_effective_from) AS b;

    IF v_policy_id IS NULL THEN
        -- ------------------------------------------------------------------
        -- No policy (site-specific or the global site_id IS NULL default)
        -- covers p_from. Distinguish "genuinely before any capture
        -- configuration ever existed for this site" (expected -- no policy
        -- could ever have produced telemetry there, so the correct answer
        -- is an empty result, not an error) from "a gap inside an
        -- otherwise-configured era" (a real configuration inconsistency for
        -- a commissioned period -- still an error). The distinguishing
        -- signal is the earliest effective_from across every policy that
        -- could ever apply to this site: if p_from predates that instant,
        -- there was categorically no policy yet, anywhere, for this site;
        -- if p_from is at or after it but resolution still fails, a policy
        -- actually goes missing somewhere it should not.
        -- ------------------------------------------------------------------

        SELECT MIN(p.effective_from)
        INTO v_earliest_applicable_from
        FROM config.telemetry_capture_policies p
        WHERE p.is_enabled
          AND (p.site_id = v_site_id OR p.site_id IS NULL);

        IF v_earliest_applicable_from IS NULL
            OR p_from >= v_earliest_applicable_from
        THEN
            -- Either this site has no applicable policy at all (a genuine
            -- configuration gap regardless of when it's queried), or
            -- p_from already falls inside the configured era and still
            -- didn't resolve (a gap between policies). Both are real
            -- configuration problems, not "no data yet" -- preserve the
            -- original failure.
            RAISE EXCEPTION
                'no capture policy resolvable for site % at %', v_site_id, p_from;
        END IF;

        IF p_to <= v_earliest_applicable_from THEN
            -- The entire requested range predates any capture policy this
            -- site has ever had. No telemetry could exist for any of it --
            -- an empty result, not an error.
            RETURN;
        END IF;

        -- The requested range straddles the boundary: nothing could have
        -- been captured before v_earliest_applicable_from, so clip the
        -- effective read window forward to it and re-resolve. The portion
        -- from p_from up to the clip point contributes zero rows, exactly
        -- as if it had never been part of the request.
        v_effective_from := v_earliest_applicable_from;

        SELECT
            b.policy_id,
            b.capture_interval_seconds
        INTO
            v_policy_id,
            v_capture_interval_seconds
        FROM telemetry.resolve_site_capture_bucket(v_site_id, v_effective_from) AS b;

        IF v_policy_id IS NULL THEN
            RAISE EXCEPTION
                'no capture policy resolvable for site % at % after clipping to the earliest applicable policy',
                v_site_id, v_effective_from;
        END IF;
    END IF;

    -- ------------------------------------------------------------------
    -- Import-side device metadata (resolved_device_id/device_name output
    -- columns only -- see migration 263 header). The Import binding with
    -- the latest effective_from within [v_effective_from, p_to) is used as
    -- "the" device shown in these two columns; per-row consumption values
    -- below are attributed independently and are unaffected by this.
    -- NULL when Import is not confirmed at all -- no invented value.
    -- ------------------------------------------------------------------

    SELECT d.id, d.name
    INTO v_device_id, v_device_name
    FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_IMPORT_TOTAL', v_effective_from, p_to) AS w
    JOIN metadata.devices AS d ON d.id = w.device_id
    ORDER BY w.window_from DESC
    LIMIT 1;

    -- ------------------------------------------------------------------
    -- Historical-time safety: reject ranges that cross a genuine change in
    -- capture_interval_seconds rather than silently applying the interval
    -- in force at either endpoint. Re-resolves the actual policy (via
    -- telemetry.resolve_site_capture_bucket itself -- its precedence
    -- logic is never duplicated here) at every candidate transition
    -- instant inside (p_from, p_to).
    --
    -- Compares only capture_interval_seconds -- the one resolved parameter
    -- this function's own math actually depends on (bucket width, and
    -- every coverage-ratio / partial-bucket denominator below all assume
    -- one constant interval across the window). late_arrival_tolerance_
    -- seconds is deliberately excluded: it only governs whether a raw
    -- sample gets folded into its bucket at *ingestion* time, which is
    -- already baked into whatever is persisted in the native/aggregate
    -- tables this function reads -- it changes nothing about how this
    -- function computes its output. Comparing it here (as an earlier
    -- version of this function did) rejected every multi-week read that
    -- crossed a site's late-arrival-tolerance tuning during onboarding,
    -- even though nothing this function returns would have been affected
    -- -- a false positive, not a real capture-policy change.
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
        WHERE t > v_effective_from
          AND t < p_to
        ORDER BY t
    LOOP
        SELECT b.capture_interval_seconds
        INTO v_boundary_capture_interval_seconds
        FROM telemetry.resolve_site_capture_bucket(v_site_id, v_boundary_time) AS b;

        IF v_boundary_capture_interval_seconds IS DISTINCT FROM v_capture_interval_seconds THEN
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
    -- NATIVE: analytics.v_energy_consumption_native. Import and Export are
    -- resolved independently (each via analytics.resolve_asset_energy_
    -- source_windows) and combined per-bucket with a FULL OUTER JOIN --
    -- never summed, never cross-attributed. is_partial_bucket stays the
    -- unconditional FALSE it always was (native buckets are never partial
    -- by construction, independent of data presence).
    -- ------------------------------------------------------------------

    IF v_actual = 'native' THEN
        RETURN QUERY
        WITH import_windows AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_IMPORT_TOTAL', v_effective_from, p_to)
        ),
        export_windows AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_EXPORT_TOTAL', v_effective_from, p_to)
        ),
        import_rows AS (
            -- Overlap-based (not start-containment): a binding's
            -- effective_from is essentially never aligned to a bucket
            -- boundary, so requiring the bucket to START at/after
            -- window_from would wrongly exclude the bucket containing that
            -- instant. DISTINCT ON, preferring the latest-starting window,
            -- guarantees at most one row per bucket_start even if a
            -- replacement cutover falls inside this bucket (the incoming
            -- device wins that bucket; see migration 263 header).
            SELECT DISTINCT ON (n.bucket_start) n.*
            FROM analytics.v_energy_consumption_native n
            JOIN import_windows w
              ON w.device_id = n.device_id
             AND n.bucket_start < w.window_to
             AND n.bucket_start + make_interval(secs => n.native_resolution_seconds) > w.window_from
            ORDER BY n.bucket_start, w.window_from DESC
        ),
        export_rows AS (
            SELECT DISTINCT ON (n.bucket_start) n.*
            FROM analytics.v_energy_consumption_native n
            JOIN export_windows w
              ON w.device_id = n.device_id
             AND n.bucket_start < w.window_to
             AND n.bucket_start + make_interval(secs => n.native_resolution_seconds) > w.window_from
            ORDER BY n.bucket_start, w.window_from DESC
        )
        SELECT
            p_requested_resolution,
            'native'::TEXT,
            v_capture_interval_seconds,
            COALESCE(i.bucket_start, e.bucket_start),
            COALESCE(i.bucket_start, e.bucket_start)
                + make_interval(secs => COALESCE(i.native_resolution_seconds, e.native_resolution_seconds)),
            v_device_id,
            v_device_name,

            i.import_consumption_kwh,
            e.export_consumption_kwh,

            CASE
                WHEN i.bucket_start IS NULL THEN NULL
                WHEN NOT i.is_measured_interval AND i.import_reconstruction_role IS NULL THEN 'INVALID_INTERVALS'
                WHEN NOT i.import_is_valid THEN 'INVALID_INTERVALS'
                WHEN i.import_reset_detected THEN 'RESET_DETECTED'
                WHEN i.import_quality_code = 'GAP' THEN 'GAPS_DETECTED'
                WHEN i.import_reconstruction_role IS NOT NULL THEN 'RECONSTRUCTED_TIMING'
                WHEN i.import_rollover_detected THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,
            CASE
                WHEN e.bucket_start IS NULL THEN NULL
                WHEN NOT e.is_measured_interval AND e.export_reconstruction_role IS NULL THEN 'INVALID_INTERVALS'
                WHEN NOT e.export_is_valid THEN 'INVALID_INTERVALS'
                WHEN e.export_reset_detected THEN 'RESET_DETECTED'
                WHEN e.export_quality_code = 'GAP' THEN 'GAPS_DETECTED'
                WHEN e.export_reconstruction_role IS NOT NULL THEN 'RECONSTRUCTED_TIMING'
                WHEN e.export_rollover_detected THEN 'ROLLOVER_DETECTED'
                ELSE 'GOOD'
            END,

            CASE WHEN i.bucket_start IS NOT NULL THEN i.is_measured_interval::INT::BIGINT ELSE NULL END,
            (i.import_is_valid AND i.is_measured_interval AND NOT i.import_is_interior)::INT::BIGINT,
            (NOT i.import_is_valid AND i.is_measured_interval AND NOT i.import_is_interior)::INT::BIGINT,
            (e.export_is_valid AND e.is_measured_interval AND NOT e.export_is_interior)::INT::BIGINT,
            (NOT e.export_is_valid AND e.is_measured_interval AND NOT e.export_is_interior)::INT::BIGINT,
            CASE WHEN i.bucket_start IS NULL THEN NULL WHEN i.is_measured_interval THEN 1.0::NUMERIC ELSE 0.0::NUMERIC END,

            (i.gap_detected AND i.is_measured_interval)::INT::BIGINT,
            (i.reset_detected AND i.is_measured_interval)::INT::BIGINT,
            (i.rollover_detected AND i.is_measured_interval)::INT::BIGINT,
            i.invalid_detected::INT::BIGINT,

            i.bucket_start,
            i.bucket_start,
            FALSE,

            v_fallback_applied,
            v_fallback_reason

        FROM import_rows i
        FULL OUTER JOIN export_rows e ON e.bucket_start = i.bucket_start
        ORDER BY COALESCE(i.bucket_start, e.bucket_start);
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 5m / 15m: analytics.v_energy_reporting_5min / _15min. Already
    -- tenant-scoped (security_barrier views joined to
    -- grafana_organization_map). Import/Export resolved and combined per
    -- bucket exactly as the native tier above.
    -- ------------------------------------------------------------------

    IF v_actual IN ('5m', '15m') THEN
        RETURN QUERY
        WITH import_windows AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_IMPORT_TOTAL', v_effective_from, p_to)
        ),
        export_windows AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_EXPORT_TOTAL', v_effective_from, p_to)
        ),
        base AS (
            SELECT * FROM analytics.v_energy_reporting_5min WHERE v_actual = '5m'
            UNION ALL
            SELECT * FROM analytics.v_energy_reporting_15min WHERE v_actual = '15m'
        ),
        import_rows AS (
            -- Overlap-based against the source window (see the native
            -- tier's comment above for why), with DISTINCT ON preventing
            -- a mid-bucket replacement cutover from fanning out into two
            -- rows for the same bucket_start.
            SELECT DISTINCT ON (r.bucket_start) r.*
            FROM base r
            JOIN import_windows w
              ON w.device_id = r.device_id
             AND r.bucket_start < w.window_to
             AND r.bucket_start + (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END) > w.window_from
            WHERE r.grafana_org_id = p_grafana_org_id
              AND r.bucket_start >= date_bin(
                      (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END),
                      v_effective_from,
                      TIMESTAMPTZ '2000-01-01 00:00:00+00'
                  )
              AND r.bucket_start < p_to
            ORDER BY r.bucket_start, w.window_from DESC
        ),
        export_rows AS (
            SELECT DISTINCT ON (r.bucket_start) r.*
            FROM base r
            JOIN export_windows w
              ON w.device_id = r.device_id
             AND r.bucket_start < w.window_to
             AND r.bucket_start + (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END) > w.window_from
            WHERE r.grafana_org_id = p_grafana_org_id
              AND r.bucket_start >= date_bin(
                      (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END),
                      v_effective_from,
                      TIMESTAMPTZ '2000-01-01 00:00:00+00'
                  )
              AND r.bucket_start < p_to
            ORDER BY r.bucket_start, w.window_from DESC
        )
        SELECT
            p_requested_resolution,
            v_actual,
            v_capture_interval_seconds,
            COALESCE(i.bucket_start, e.bucket_start),
            COALESCE(i.bucket_start, e.bucket_start) + (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END),
            v_device_id,
            v_device_name,

            i.import_consumption_kwh,
            e.export_consumption_kwh,

            CASE
                WHEN i.bucket_start IS NULL THEN NULL
                WHEN i.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN i.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN i.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN i.import_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN i.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                WHEN i.valid_import_intervals = 0 AND i.invalid_import_intervals = 0 AND i.import_reconstructed_intervals = 0 THEN 'INVALID_INTERVALS'
                ELSE 'GOOD'
            END,
            CASE
                WHEN e.bucket_start IS NULL THEN NULL
                WHEN e.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN e.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN e.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN e.export_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN e.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                WHEN e.valid_export_intervals = 0 AND e.invalid_export_intervals = 0 AND e.export_reconstructed_intervals = 0 THEN 'INVALID_INTERVALS'
                ELSE 'GOOD'
            END,

            i.source_interval_count,
            i.valid_import_intervals,
            i.invalid_import_intervals,
            e.valid_export_intervals,
            e.invalid_export_intervals,

            (
                i.source_interval_count::NUMERIC
                / NULLIF(
                    (CASE WHEN v_actual = '5m' THEN 300 ELSE 900 END) / v_capture_interval_seconds,
                    0
                )
            ),

            i.gap_interval_count,
            i.reset_interval_count,
            i.rollover_interval_count,
            i.invalid_interval_count,

            i.first_native_bucket_start,
            i.last_native_bucket_start,

            CASE WHEN i.bucket_start IS NULL THEN NULL ELSE (
                i.source_interval_count < (CASE WHEN v_actual = '5m' THEN 300 ELSE 900 END) / v_capture_interval_seconds
                OR i.bucket_start < v_effective_from
                OR i.bucket_start + (CASE WHEN v_actual = '5m' THEN INTERVAL '5 minutes' ELSE INTERVAL '15 minutes' END) > p_to
            ) END,

            v_fallback_applied,
            v_fallback_reason

        FROM import_rows i
        FULL OUTER JOIN export_rows e ON e.bucket_start = i.bucket_start
        ORDER BY COALESCE(i.bucket_start, e.bucket_start);
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 1h: analytics.v_energy_reporting_hourly. Already tenant-scoped,
    -- site-timezone-aware. Source-window matching is strict start-
    -- containment (never overlap) to prevent one coarse bucket from
    -- matching two different devices' windows across a mid-bucket source
    -- replacement -- see migration 263 header. The original request-
    -- boundary overlap filter against [v_effective_from, p_to) is kept
    -- unchanged in addition.
    -- ------------------------------------------------------------------

    IF v_actual = '1h' THEN
        RETURN QUERY
        WITH import_windows AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_IMPORT_TOTAL', v_effective_from, p_to)
        ),
        export_windows AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_EXPORT_TOTAL', v_effective_from, p_to)
        ),
        import_rows AS (
            -- Overlap-based against the source window, DISTINCT ON
            -- preventing fan-out on a mid-bucket cutover -- see the native
            -- tier's comment above.
            SELECT DISTINCT ON (h.bucket_start) h.*
            FROM analytics.v_energy_reporting_hourly h
            JOIN import_windows w
              ON w.device_id = h.device_id
             AND h.bucket_start < w.window_to
             AND h.bucket_start + INTERVAL '1 hour' > w.window_from
            WHERE h.grafana_org_id = p_grafana_org_id
              AND h.bucket_start < p_to
              AND h.bucket_start + INTERVAL '1 hour' > v_effective_from
            ORDER BY h.bucket_start, w.window_from DESC
        ),
        export_rows AS (
            SELECT DISTINCT ON (h.bucket_start) h.*
            FROM analytics.v_energy_reporting_hourly h
            JOIN export_windows w
              ON w.device_id = h.device_id
             AND h.bucket_start < w.window_to
             AND h.bucket_start + INTERVAL '1 hour' > w.window_from
            WHERE h.grafana_org_id = p_grafana_org_id
              AND h.bucket_start < p_to
              AND h.bucket_start + INTERVAL '1 hour' > v_effective_from
            ORDER BY h.bucket_start, w.window_from DESC
        )
        SELECT
            p_requested_resolution,
            '1h'::TEXT,
            v_capture_interval_seconds,
            COALESCE(i.bucket_start, e.bucket_start),
            COALESCE(i.bucket_start, e.bucket_start) + INTERVAL '1 hour',
            v_device_id,
            v_device_name,

            i.import_consumption_kwh,
            e.export_consumption_kwh,

            CASE
                WHEN i.bucket_start IS NULL THEN NULL
                WHEN i.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN i.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN i.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN i.import_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN i.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                WHEN i.valid_import_intervals = 0 AND i.invalid_import_intervals = 0 AND i.import_reconstructed_intervals = 0 THEN 'INVALID_INTERVALS'
                ELSE 'GOOD'
            END,
            CASE
                WHEN e.bucket_start IS NULL THEN NULL
                WHEN e.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN e.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN e.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN e.export_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN e.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                WHEN e.valid_export_intervals = 0 AND e.invalid_export_intervals = 0 AND e.export_reconstructed_intervals = 0 THEN 'INVALID_INTERVALS'
                ELSE 'GOOD'
            END,

            i.source_interval_count::BIGINT,
            i.valid_import_intervals::BIGINT,
            i.invalid_import_intervals::BIGINT,
            e.valid_export_intervals::BIGINT,
            e.invalid_export_intervals::BIGINT,

            (i.source_interval_count::NUMERIC / NULLIF(3600 / v_capture_interval_seconds, 0)),

            i.gap_interval_count::BIGINT,
            i.reset_interval_count::BIGINT,
            i.rollover_interval_count::BIGINT,
            i.invalid_interval_count::BIGINT,

            i.first_native_bucket_start,
            i.last_native_bucket_start,

            CASE WHEN i.bucket_start IS NULL THEN NULL ELSE (
                i.source_interval_count < 3600 / v_capture_interval_seconds
                OR i.bucket_start < v_effective_from
                OR i.bucket_start + INTERVAL '1 hour' > p_to
            ) END,

            v_fallback_applied,
            v_fallback_reason

        FROM import_rows i
        FULL OUTER JOIN export_rows e ON e.bucket_start = i.bucket_start
        ORDER BY COALESCE(i.bucket_start, e.bucket_start);
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 1d: analytics.v_energy_reporting_daily. Site-timezone-aware; joined
    -- on the resolved site-local-day instant (not the raw DATE) so Import
    -- and Export rows line up even if resolved independently. Same
    -- start-containment source-window matching as every other tier.
    -- ------------------------------------------------------------------

    IF v_actual = '1d' THEN
        RETURN QUERY
        WITH import_windows AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_IMPORT_TOTAL', v_effective_from, p_to)
        ),
        export_windows AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_EXPORT_TOTAL', v_effective_from, p_to)
        ),
        import_rows AS (
            -- Overlap-based against the source window, DISTINCT ON
            -- preventing fan-out on a mid-bucket cutover -- see the native
            -- tier's comment above.
            SELECT DISTINCT ON (day_start)
                d.*,
                (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) AS day_start
            FROM analytics.v_energy_reporting_daily d
            JOIN import_windows w
              ON w.device_id = d.device_id
             AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) < w.window_to
             AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day' > w.window_from
            WHERE d.grafana_org_id = p_grafana_org_id
              AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) < p_to
              AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day' > v_effective_from
            ORDER BY day_start, w.window_from DESC
        ),
        export_rows AS (
            SELECT DISTINCT ON (day_start)
                d.*,
                (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) AS day_start
            FROM analytics.v_energy_reporting_daily d
            JOIN export_windows w
              ON w.device_id = d.device_id
             AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) < w.window_to
             AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day' > w.window_from
            WHERE d.grafana_org_id = p_grafana_org_id
              AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) < p_to
              AND (d.consumption_date::TIMESTAMP AT TIME ZONE d.site_timezone) + INTERVAL '1 day' > v_effective_from
            ORDER BY day_start, w.window_from DESC
        )
        SELECT
            p_requested_resolution,
            '1d'::TEXT,
            v_capture_interval_seconds,
            COALESCE(i.day_start, e.day_start),
            COALESCE(i.day_start, e.day_start) + INTERVAL '1 day',
            v_device_id,
            v_device_name,

            i.import_consumption_kwh,
            e.export_consumption_kwh,

            CASE
                WHEN i.day_start IS NULL THEN NULL
                WHEN i.invalid_import_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN i.import_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN i.import_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN i.import_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN i.import_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                WHEN i.valid_import_intervals = 0 AND i.invalid_import_intervals = 0 AND i.import_reconstructed_intervals = 0 THEN 'INVALID_INTERVALS'
                ELSE 'GOOD'
            END,
            CASE
                WHEN e.day_start IS NULL THEN NULL
                WHEN e.invalid_export_intervals > 0 THEN 'INVALID_INTERVALS'
                WHEN e.export_reset_intervals > 0 THEN 'RESET_DETECTED'
                WHEN e.export_gap_intervals > 0 THEN 'GAPS_DETECTED'
                WHEN e.export_reconstructed_intervals > 0 THEN 'RECONSTRUCTED_TIMING'
                WHEN e.export_rollover_intervals > 0 THEN 'ROLLOVER_DETECTED'
                WHEN e.valid_export_intervals = 0 AND e.invalid_export_intervals = 0 AND e.export_reconstructed_intervals = 0 THEN 'INVALID_INTERVALS'
                ELSE 'GOOD'
            END,

            i.source_interval_count::BIGINT,
            i.valid_import_intervals::BIGINT,
            i.invalid_import_intervals::BIGINT,
            e.valid_export_intervals::BIGINT,
            e.invalid_export_intervals::BIGINT,

            -- Nominal 86400s day length; does not correct for DST transitions.
            (i.source_interval_count::NUMERIC / NULLIF(86400 / v_capture_interval_seconds, 0)),

            i.gap_interval_count::BIGINT,
            i.reset_interval_count::BIGINT,
            i.rollover_interval_count::BIGINT,
            i.invalid_interval_count::BIGINT,

            i.first_native_bucket_start,
            i.last_native_bucket_start,

            CASE WHEN i.day_start IS NULL THEN NULL ELSE (
                i.source_interval_count < 86400 / v_capture_interval_seconds
                OR i.day_start < v_effective_from
                OR i.day_start + INTERVAL '1 day' > p_to
            ) END,

            v_fallback_applied,
            v_fallback_reason

        FROM import_rows i
        FULL OUTER JOIN export_rows e ON e.day_start = i.day_start
        ORDER BY COALESCE(i.day_start, e.day_start);
        RETURN;
    END IF;

    RAISE EXCEPTION
        'unhandled actual_resolution %; canonical reader has no dispatch '
        'branch for this resolution tier',
        v_actual;
END;
$function$;

-- Ownership and grants (ems_admin owner; EXECUTE to grafana_reader) are
-- preserved as-is by CREATE OR REPLACE FUNCTION -- not touched here.


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)';
    v_body TEXT;
BEGIN
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
        RAISE EXCEPTION 'Migration 263 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 263 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('grafana_reader', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 263 postcondition failed: % is no longer executable by grafana_reader (grant not preserved).', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 263 postcondition failed: the canonical energy read function contains a write statement.';
    END IF;

    IF position('primary_meter' IN v_body) > 0
       OR position('asset_devices' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 263 postcondition failed: the canonical energy read function must no longer reference PRIMARY_METER or asset_devices -- attribution must come from metadata.asset_points only.';
    END IF;

    -- The rewritten function delegates attribution to the shared helper
    -- (which itself reads metadata.asset_points -- checked separately
    -- below) rather than spelling "asset_points" inline, so the guard here
    -- checks for the helper call.
    IF position('resolve_asset_energy_source_windows' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 263 postcondition failed: the canonical energy read function must resolve attribution via analytics.resolve_asset_energy_source_windows.';
    END IF;

    IF position('asset_points' IN lower(pg_get_functiondef('analytics.resolve_asset_energy_source_windows(uuid, text, timestamptz, timestamptz)'::regprocedure))) = 0 THEN
        RAISE EXCEPTION 'Migration 263 postcondition failed: analytics.resolve_asset_energy_source_windows must read via metadata.asset_points.';
    END IF;

    -- The five underlying aggregate views must remain untouched (still
    -- referenced by name, unchanged) rather than replaced by a new object.
    IF position('v_energy_consumption_native' IN v_body) = 0
       OR position('v_energy_reporting_5min' IN v_body) = 0
       OR position('v_energy_reporting_15min' IN v_body) = 0
       OR position('v_energy_reporting_hourly' IN v_body) = 0
       OR position('v_energy_reporting_daily' IN v_body) = 0
    THEN
        RAISE EXCEPTION 'Migration 263 postcondition failed: the canonical energy read function must still dispatch to all five existing aggregate views.';
    END IF;

    -- ADR-020 / migration 269 semantics re-applied in every tier.
    IF (length(v_body) - length(replace(v_body, 'reconstructed_timing', ''))) / length('reconstructed_timing') <> 8
       OR (length(v_body) - length(replace(v_body, 'reconstructed_intervals = 0 then ''invalid_intervals''', ''))) / length('reconstructed_intervals = 0 then ''invalid_intervals''') <> 6
       OR (length(v_body) - length(replace(v_body, 'reconstruction_role is null then ''invalid_intervals''', ''))) / length('reconstruction_role is null then ''invalid_intervals''') <> 2
       OR position('i.is_measured_interval::int::bigint' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 263 postcondition failed: the migration-269 measured-vs-reconstructed handling is not present in every tier.';
    END IF;

    RAISE NOTICE 'Migration 263: all postconditions passed (canonical energy read function migrated to asset_points-based, per-direction attribution; PRIMARY_METER/asset_devices no longer referenced; all five resolution tiers and the five underlying aggregate views preserved).';
END;
$post$;
