-- ============================================================================
-- Migration 246
-- Asset View -- portal-user-scoped Asset Power Trend for the /api/v1
-- Analytics API's new GET /sites/{site_id}/assets/{asset_id}/power-trend
-- endpoint.
--
-- Source of record: investigation of the existing Site Power Trend /
-- electrical-telemetry read path prior to this migration.
--
-- Findings:
--   * "Power Trend" (instantaneous active power over time, distinct from
--     Demand's interval-averaged kW) already exists as a Grafana concept:
--     the asset-overview dashboard's "Active Power Trend" panel, and the
--     richer analytics.get_grafana_asset_electrical_trend(bigint, uuid,
--     timestamptz, timestamptz) function (migration 046), which reads
--     analytics.v_grafana_asset_electrical_samples (migration 015/134) for
--     <=24h ranges, falling back to the 15-minute/hourly rollup views for
--     longer ranges. Both are grafana_org_id-scoped and read from the
--     asset's PRIMARY_METER device.
--   * v_grafana_asset_electrical_samples itself reads directly from
--     telemetry.energy_measurements (active_power_total_w, quality_code,
--     is_estimated), joined to the asset via metadata.asset_devices WHERE
--     relationship_type = 'PRIMARY_METER' -- the same resolution path
--     every other asset-scoped function in this codebase already uses
--     (admin.get_portal_asset_live_state, analytics.get_portal_asset_
--     energy_intervals's grafana bridge, v_grafana_asset_electrical_samples
--     itself). telemetry.energy_measurements.active_power_total_w is a
--     plain stored column -- no meter-role resolution, no register-delta
--     classification, no derived calculation -- unlike Energy consumption's
--     get_canonical_energy_read, there is no non-trivial business logic to
--     re-derive or risk disagreeing with here.
--   * An index already exists for exactly this access pattern:
--     energy_measurements_device_bucket_start_idx ON telemetry.
--     energy_measurements(device_id, bucket_start DESC) (migration 019/138).
--
-- Decision: this migration reads telemetry.energy_measurements DIRECTLY,
-- resolved via metadata.asset_devices (PRIMARY_METER) and gated by the
-- already-existing admin.portal_user_can_access_asset(bigint, uuid)
-- (migration 022, already used by the live-state/energy-consumption/demand
-- asset routes) -- exactly like Asset Demand (migration 245) reads
-- analytics.demand_intervals/demand_state directly. It does NOT wrap
-- analytics.get_grafana_asset_electrical_trend or bridge to a
-- grafana_org_id, because no grafana_org_id resolution is needed at all:
-- unlike Asset Energy (migration 244), which had to bridge because its
-- only correct source (get_canonical_energy_read) has real business logic
-- only implemented behind that Grafana-scoped envelope, Power Trend's
-- source data has no such logic and is read the same way Demand already
-- reads its own canonical tables -- directly, with the portal's own
-- authorization function.
--
-- Genuine gap, not resolved here (flagged per instruction not to invent a
-- customer-facing mapping that does not exist): telemetry.energy_
-- measurements.quality_code is a raw internal SMALLINT with no established
-- customer-facing translation anywhere in this codebase (unlike Demand's
-- own quality_status string enum, or metadata.normalized_points' already-
-- text quality_code). This migration exposes is_estimated (a plain
-- boolean, self-describing, safe to expose) as the data-state signal, and
-- deliberately does NOT expose quality_code -- inventing a translation for
-- it is a product/design decision, not something to assume here.
--
-- What this migration does (ADDITIVE ONLY, same pattern as migration 245):
--   One new function in schema analytics:
--
--   analytics.get_portal_asset_power_trend(bigint, uuid, timestamptz,
--     timestamptz) RETURNS TABLE(sample_time, active_power_kw,
--     is_estimated) -- named sample_time, not interval_start, because this
--     is a raw point-in-time sample series (like live-state's event_time),
--     not an aggregated interval with a start and end (like Demand/Energy).
--
--     * SECURITY DEFINER, STABLE, pinned SET search_path,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope via admin.portal_user_can_access_asset(bigint, uuid),
--       re-derived server-side -- no grafana_org_id anywhere in this
--       function.
--
-- What this migration does NOT do:
--   * Does NOT modify analytics.get_grafana_asset_electrical_trend,
--     analytics.v_grafana_asset_electrical_samples, any Grafana dashboard,
--     or any object either reads.
--   * Does NOT add a resolution parameter or dynamic routing -- native
--     sample grain only. (No application-layer window cap either -- see
--     the accompanying application-layer change removing the equivalent
--     artificial cap from Demand; the same reasoning applies here: no
--     evidence of a real retention/performance boundary at this window
--     size, so none is invented.)
--   * Does NOT touch telemetry.energy_measurements, metadata.asset_devices,
--     or any existing table/view/job.
--   * Does NOT expose quality_code, device_id, or device_name.
--
-- Rollback: DROP FUNCTION analytics.get_portal_asset_power_trend(bigint,
-- uuid, timestamptz, timestamptz); safe, no existing object is altered by
-- this migration.
--
-- New tests:
--   app/tests/test_analytics_api_v1_asset_power_trend_routes.py (HTTP
--   contract, mocked service boundary).
--   scripts/test/assert_asset_power_trend_portal_read.sh (data-driven,
--   real disposable-DB rows seeded directly into telemetry.energy_
--   measurements).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_asset(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 246 precondition failed: admin.portal_user_can_access_asset(bigint, uuid) is missing (migration 022).';
    END IF;

    IF to_regclass('telemetry.energy_measurements') IS NULL THEN
        RAISE EXCEPTION 'Migration 246 precondition failed: telemetry.energy_measurements is missing.';
    END IF;

    IF to_regclass('metadata.asset_devices') IS NULL THEN
        RAISE EXCEPTION 'Migration 246 precondition failed: metadata.asset_devices is missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'telemetry' AND table_name = 'energy_measurements'
          AND column_name = 'bucket_start'
    ) THEN
        RAISE EXCEPTION 'Migration 246 precondition failed: telemetry.energy_measurements.bucket_start is missing (migration 112 rename).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'telemetry' AND table_name = 'energy_measurements'
          AND column_name = 'active_power_total_w'
    ) THEN
        RAISE EXCEPTION 'Migration 246 precondition failed: telemetry.energy_measurements.active_power_total_w is missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_asset_power_trend(bigint, uuid, timestamptz, timestamptz)
--    Raw instantaneous active-power samples for one asset's PRIMARY_METER
--    device. Empty for an inaccessible or unknown asset, or an asset with
--    no PRIMARY_METER device / no telemetry in the window.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_asset_power_trend
(
    p_portal_user_id BIGINT,
    p_asset_id       UUID,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ
)
RETURNS TABLE
(
    sample_time    TIMESTAMPTZ,
    active_power_kw DOUBLE PRECISION,
    is_estimated   BOOLEAN
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata, telemetry
AS $function$
    WITH primary_meter AS (
        SELECT ad.device_id
        FROM metadata.asset_devices AS ad
        WHERE ad.asset_id = p_asset_id
          AND ad.relationship_type = 'PRIMARY_METER'
        LIMIT 1
    )
    SELECT
        em.bucket_start,
        em.active_power_total_w / 1000.0,
        em.is_estimated
    FROM primary_meter AS pm
    JOIN telemetry.energy_measurements AS em
      ON em.device_id = pm.device_id
     AND em.bucket_start >= p_from
     AND em.bucket_start < p_to
    WHERE admin.portal_user_can_access_asset(p_portal_user_id, p_asset_id)
    ORDER BY em.bucket_start;
$function$;

ALTER FUNCTION analytics.get_portal_asset_power_trend(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_asset_power_trend(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_asset_power_trend(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions -- ownership/grant hygiene, read-only-body proof, and the
-- architectural guard that this function never adopts the Grafana
-- authorization envelope or touches a Grafana object.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_asset_power_trend(bigint, uuid, timestamptz, timestamptz)';
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
        RAISE EXCEPTION 'Migration 246 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 246 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 246 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 246 postcondition failed: the power-trend read function contains a write statement.';
    END IF;

    IF position('grafana_org_id' IN v_body) > 0
       OR position('grafana_organization_map' IN v_body) > 0
       OR position('get_grafana_' IN v_body) > 0
       OR position('v_grafana_' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 246 postcondition failed: the power-trend read function must not reuse the Grafana authorization envelope or any Grafana-facing view/function -- this API is portal_user_id-scoped, not grafana_org_id-scoped.';
    END IF;

    RAISE NOTICE 'Migration 246: all postconditions passed (portal-scoped asset power trend read function created; read-only; reads telemetry.energy_measurements directly via the PRIMARY_METER relationship; no Grafana envelope referenced).';
END;
$post$;
