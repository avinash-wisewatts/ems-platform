-- ============================================================================
-- Migration 270
-- Canonical Energy read performance: selective device reads.
--
-- Performance-only fix for analytics.get_canonical_energy_read after
-- migration 263. Attribution, output and the migration-269
-- measured/reconstructed semantics are unchanged.
--
-- Measured cause (staging, read-only EXPLAIN (ANALYZE, BUFFERS), one asset,
-- 3-day window):
--   * 263 restricts each direction's devices only by joining the tier view
--     to the analytics.resolve_asset_energy_source_windows(...) function
--     scan. A join qual cannot be pushed into a grouped or security_barrier
--     view, so every tier aggregated ALL devices and all time before the
--     join discarded the rest: native 3.9 s, 15m 14.2 s (the 5m/15m `base`
--     CTE is referenced twice and was materialized: ~1.73M native rows,
--     116,881 groups, 42k temp blocks), 1h 3.7 s, 1d 4.5 s. The 162
--     asset x tier fingerprint reads took 25 min 46 s.
--   * The pre-263 read filtered by a constant device_id, which PostgreSQL
--     pushes onto the views' device_id grouping column and on to the
--     compressed-segment indexes (organization_id, site_id, device_id) and
--     the energy_consumption_1min primary key (device_id, bucket_start).
--
-- Change (additive predicates only; nothing removed):
--   1. v_import_devices / v_export_devices: each direction's device set,
--      resolved once from the same asset_points windows
--      (resolve_asset_energy_source_windows over [v_effective_from, p_to)).
--   2. Every import_rows / export_rows read (native, 5m/15m, 1h, 1d) adds
--      device_id = ANY(v_import_devices) / ANY(v_export_devices). This is
--      implied by the existing window join (w.device_id = <row>.device_id),
--      so no row can change; the join still does per-window clipping,
--      overlap matching and DISTINCT ON (the incoming source wins a
--      straddling bucket). No binding -> NULL array -> matches nothing,
--      exactly like the empty join. Import and Export stay independent.
--   3. The 5m/15m base CTE is NOT MATERIALIZED so the device and time
--      predicates reach v_energy_reporting_5min / _15min.
--   4. Native tier: bucket_start >= v_effective_from - INTERVAL '5 minutes'
--      AND bucket_start < p_to. Also implied by the join: windows lie within
--      [v_effective_from, p_to) and the overlap test is
--      bucket_start + native_resolution_seconds > window_from, with
--      native_resolution_seconds at most 300 (60 for energy_consumption_1min,
--      300 for energy_consumption_5min). The 5-minute margin keeps the bucket
--      that contains a non-minute-aligned v_effective_from.
--
-- Not changed: signature, RETURNS TABLE, owner/grants/search_path, the five
-- views, resolve_asset_energy_source_windows, every status CASE, counter,
-- coverage and register expression (migration 269), tenant filtering. No
-- index, no persisted-table substitution. The postcondition proves that
-- removing exactly these additions reproduces migration 263's body
-- byte-for-byte.
--
-- Rollback: re-apply migration 263's CREATE OR REPLACE FUNCTION
-- analytics.get_canonical_energy_read block (the output is identical; only
-- the speed changes).
--
-- Tests: scripts/test/assert_canonical_energy_read_selective_device_reads.sh
-- (golden equality against the migration 263 body, including a
-- non-minute-aligned p_from, missing Import/Export bindings and a source
-- switch inside a bucket, plus a plan-shape check that every tier's reads
-- carry the device predicate and no aggregate spans other devices).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Preconditions: the deployed function is exactly migration 263's body.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('analytics.resolve_asset_energy_source_windows(uuid, text, timestamptz, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 270 precondition failed: analytics.resolve_asset_energy_source_windows is missing (migration 263).';
    END IF;

    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)'::regprocedure)
       IS DISTINCT FROM 'b47c9a953bab9d2fabdf4546ddcd12d1' THEN
        RAISE EXCEPTION 'Migration 270 precondition failed: analytics.get_canonical_energy_read differs from the expected (migration 263) body.';
    END IF;
END
$pre$;


-- ----------------------------------------------------------------------------
-- 2. analytics.get_canonical_energy_read: migration 263's body with only the
--    Migration 270 additions (see header). Signature, RETURNS TABLE, owner,
--    grants and search_path are preserved by CREATE OR REPLACE.
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

    -- Migration 270: each direction's asset_points source device set, used
    -- only as a pushable device_id filter on the tier reads below.
    v_import_devices             UUID[];
    v_export_devices             UUID[];
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
    -- Migration 270: resolve each direction's source device set once, from
    -- the same asset_points windows every tier joins against. It is used
    -- only as a device_id = ANY(...) predicate the planner can push into
    -- the grouped / security_barrier views (a join to the window function
    -- scan cannot be pushed down, which made every tier aggregate all
    -- devices). The window joins still decide attribution -- clipping,
    -- overlap and DISTINCT ON are unchanged. A direction with no binding
    -- gets NULL, and = ANY(NULL) matches nothing, exactly like its empty
    -- window join.
    -- ------------------------------------------------------------------

    SELECT array_agg(DISTINCT w.device_id)
    INTO v_import_devices
    FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_IMPORT_TOTAL', v_effective_from, p_to) AS w;

    SELECT array_agg(DISTINCT w.device_id)
    INTO v_export_devices
    FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_EXPORT_TOTAL', v_effective_from, p_to) AS w;

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
            -- Migration 270: pushable bounds implied by the window join
            -- (windows lie within [v_effective_from, p_to); native buckets
            -- are at most 5 minutes wide).
            WHERE n.device_id = ANY(v_import_devices)
              AND n.bucket_start >= v_effective_from - INTERVAL '5 minutes'
              AND n.bucket_start < p_to
            ORDER BY n.bucket_start, w.window_from DESC
        ),
        export_rows AS (
            SELECT DISTINCT ON (n.bucket_start) n.*
            FROM analytics.v_energy_consumption_native n
            JOIN export_windows w
              ON w.device_id = n.device_id
             AND n.bucket_start < w.window_to
             AND n.bucket_start + make_interval(secs => n.native_resolution_seconds) > w.window_from
            -- Migration 270: pushable bounds implied by the window join
            -- (windows lie within [v_effective_from, p_to); native buckets
            -- are at most 5 minutes wide).
            WHERE n.device_id = ANY(v_export_devices)
              AND n.bucket_start >= v_effective_from - INTERVAL '5 minutes'
              AND n.bucket_start < p_to
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
        base AS NOT MATERIALIZED (
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
              AND r.device_id = ANY(v_import_devices)
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
              AND r.device_id = ANY(v_export_devices)
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
              AND h.device_id = ANY(v_import_devices)
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
              AND h.device_id = ANY(v_export_devices)
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
              AND d.device_id = ANY(v_import_devices)
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
              AND d.device_id = ANY(v_export_devices)
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


-- ----------------------------------------------------------------------------
-- 3. Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)';
    v_src  TEXT;
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
        RAISE EXCEPTION 'Migration 270 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 270 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('grafana_reader', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 270 postcondition failed: % is no longer executable by grafana_reader.', v_sig;
    END IF;

    SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc WHERE oid = v_sig::regprocedure;
    v_body := lower(v_src);

    -- Every import_rows / export_rows read carries its own direction's
    -- device filter (native, 5m/15m, 1h, 1d), never the other direction's.
    IF (length(v_body) - length(replace(v_body, '= any(v_import_devices)', ''))) / length('= any(v_import_devices)') <> 4
       OR (length(v_body) - length(replace(v_body, '= any(v_export_devices)', ''))) / length('= any(v_export_devices)') <> 4 THEN
        RAISE EXCEPTION 'Migration 270 postcondition failed: expected exactly 4 import and 4 export device_id = ANY(...) filters.';
    END IF;

    IF position('base as not materialized (' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 270 postcondition failed: the 5m/15m base CTE is not NOT MATERIALIZED.';
    END IF;

    IF (length(v_body) - length(replace(v_body, 'n.bucket_start >= v_effective_from - interval ''5 minutes''', ''))) / length('n.bucket_start >= v_effective_from - interval ''5 minutes''') <> 2 THEN
        RAISE EXCEPTION 'Migration 270 postcondition failed: the native tier time bounds are missing.';
    END IF;

    -- Removing exactly the Migration 270 additions reproduces migration
    -- 263's body byte-for-byte: attribution, window joins, DISTINCT ON,
    -- FULL OUTER JOIN and the migration-269 measured/reconstructed status,
    -- counter and register logic are untouched.
    IF md5(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(v_src, $m270$
    -- Migration 270: each direction's asset_points source device set, used
    -- only as a pushable device_id filter on the tier reads below.
    v_import_devices             UUID[];
    v_export_devices             UUID[];
$m270$, ''), $m270$
    -- ------------------------------------------------------------------
    -- Migration 270: resolve each direction's source device set once, from
    -- the same asset_points windows every tier joins against. It is used
    -- only as a device_id = ANY(...) predicate the planner can push into
    -- the grouped / security_barrier views (a join to the window function
    -- scan cannot be pushed down, which made every tier aggregate all
    -- devices). The window joins still decide attribution -- clipping,
    -- overlap and DISTINCT ON are unchanged. A direction with no binding
    -- gets NULL, and = ANY(NULL) matches nothing, exactly like its empty
    -- window join.
    -- ------------------------------------------------------------------

    SELECT array_agg(DISTINCT w.device_id)
    INTO v_import_devices
    FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_IMPORT_TOTAL', v_effective_from, p_to) AS w;

    SELECT array_agg(DISTINCT w.device_id)
    INTO v_export_devices
    FROM analytics.resolve_asset_energy_source_windows(p_asset_id, 'ENERGY_EXPORT_TOTAL', v_effective_from, p_to) AS w;
$m270$, ''), $m270$            -- Migration 270: pushable bounds implied by the window join
            -- (windows lie within [v_effective_from, p_to); native buckets
            -- are at most 5 minutes wide).
            WHERE n.device_id = ANY(v_import_devices)
              AND n.bucket_start >= v_effective_from - INTERVAL '5 minutes'
              AND n.bucket_start < p_to
$m270$, ''), $m270$            -- Migration 270: pushable bounds implied by the window join
            -- (windows lie within [v_effective_from, p_to); native buckets
            -- are at most 5 minutes wide).
            WHERE n.device_id = ANY(v_export_devices)
              AND n.bucket_start >= v_effective_from - INTERVAL '5 minutes'
              AND n.bucket_start < p_to
$m270$, ''), $m270$              AND r.device_id = ANY(v_import_devices)
$m270$, ''), $m270$              AND r.device_id = ANY(v_export_devices)
$m270$, ''), $m270$              AND h.device_id = ANY(v_import_devices)
$m270$, ''), $m270$              AND h.device_id = ANY(v_export_devices)
$m270$, ''), $m270$              AND d.device_id = ANY(v_import_devices)
$m270$, ''), $m270$              AND d.device_id = ANY(v_export_devices)
$m270$, ''), 'base AS NOT MATERIALIZED (', 'base AS (')) <> 'b47c9a953bab9d2fabdf4546ddcd12d1' THEN
        RAISE EXCEPTION 'Migration 270 postcondition failed: the function changed outside the Migration 270 additions.';
    END IF;

    RAISE NOTICE 'Migration 270: all postconditions passed (per-direction device_id = ANY(...) filters in every tier, NOT MATERIALIZED 5m/15m base, native time bounds; body otherwise identical to migration 263).';
END
$post$;
