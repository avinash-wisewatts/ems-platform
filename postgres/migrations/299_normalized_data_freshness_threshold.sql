-- ============================================================================
-- Migration 299
-- Dedicated, configurable freshness threshold for NORMALIZED telemetry
-- (staging optimization plan, run 18, decision D-019). Prerequisite of
-- migration 300 (normalization every 5 minutes).
--
-- WHY
--   Three readers judge "fresh / validated" telemetry from the normalized
--   device state (telemetry.device_telemetry_state.latest_valid_received_
--   timestamp, written by the normalization job):
--     * analytics.get_portal_site_telemetry_freshness   (portal Energy /
--       Demand / Power Quality freshness; migration 237)
--     * analytics.get_grafana_asset_telemetry_context   (Grafana asset
--       telemetry state; migration 019)
--     * analytics.v_device_telemetry_availability       (admin telemetry
--       validation, commissioning, v_grafana_active_alarms /
--       v_grafana_asset_devices; migration 003)
--   They share config.telemetry_availability_policy.receiving_threshold_
--   seconds (300 s) with readers of RAW receipt and LIVE state, which do not
--   depend on normalization. With normalization every 5 minutes (migration
--   300) the newest normalized sample is up to ~7 min 40 s old just before
--   each batch (a run at :x2:40 finalizes buckets through the minute that
--   started at :x0:00; the next run is 5 minutes later), so at 300 s these
--   three readers would report STALE / RECEIVING for roughly a third of every
--   cycle while the device is healthy. Today (1-minute normalization) the
--   steady-state maximum is ~3 min 41 s.
--
-- WHAT
--   1. config.telemetry_availability_policy gains
--        normalized_receiving_threshold_seconds INTEGER NOT NULL DEFAULT 600
--      CHECK (> 0 AND < stale_threshold_seconds). 600 s = the ~460 s
--      steady-state maximum plus ~140 s for one missed device sample or one
--      retried normalization run (today: 221 s maximum vs 300 s, 79 s spare).
--   2. The three readers above read that column instead of
--      receiving_threshold_seconds. Each changes in ONE place (the policy
--      read); every CASE branch, the stale (900 s) and silent (3600 s)
--      thresholds, signatures, security, grants and comments are unchanged.
--      v_device_telemetry_availability keeps its column list: its
--      receiving_threshold_seconds column now reports the threshold the view
--      applies (shown on the admin telemetry-validation page).
--      get_grafana_asset_telemetry_context's no-policy-row fallback becomes
--      600 s (was 180 s), matching the new column default.
--
-- NOT CHANGED (keep 300 s, proven by the postconditions below)
--   receiving_threshold_seconds itself, and every reader that is not fed by
--   normalization: analytics.get_grafana_asset_connectivity_context (raw
--   receipt, job 1076), analytics.get_grafana_asset_live_state and
--   admin.get_portal_asset_live_state (live path), and gateway online status
--   (config.gateway_connectivity_policy). A device that stops sending is
--   still reported STALE by raw connectivity within 5 minutes.
--
-- Behaviour change (customer-visible): a device whose normalized data stops
-- is reported FRESH / VALIDATED for up to 10 minutes after its last valid
-- reading was received (was 5). Stale (900 s) and no-data (3600 s) are
-- unchanged.
--
-- Rollback (no data loss):
--   UPDATE config.telemetry_availability_policy
--      SET normalized_receiving_threshold_seconds = receiving_threshold_seconds;
--   restores today's behaviour without a schema change. Full reversal: re-run
--   the three definitions from migrations 237 / 019 / 003, then
--   ALTER TABLE config.telemetry_availability_policy
--     DROP COLUMN normalized_receiving_threshold_seconds;
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('config.telemetry_availability_policy') IS NULL THEN
        RAISE EXCEPTION 'Migration 299: config.telemetry_availability_policy is missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM config.telemetry_availability_policy WHERE policy_key = 'DEFAULT') THEN
        RAISE EXCEPTION 'Migration 299: config.telemetry_availability_policy has no DEFAULT row';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'config' AND table_name = 'telemetry_availability_policy'
          AND column_name = 'normalized_receiving_threshold_seconds'
    ) THEN
        RAISE EXCEPTION 'Migration 299: normalized_receiving_threshold_seconds already exists';
    END IF;
    IF EXISTS (
        SELECT 1 FROM config.telemetry_availability_policy WHERE stale_threshold_seconds <= 600
    ) THEN
        RAISE EXCEPTION 'Migration 299: a policy row has stale_threshold_seconds <= 600; the 600 s default would violate the new CHECK';
    END IF;
    IF to_regprocedure('analytics.get_portal_site_telemetry_freshness(bigint,uuid,timestamptz)') IS NULL
       OR to_regprocedure('analytics.get_grafana_asset_telemetry_context(bigint,uuid,timestamptz)') IS NULL
       OR to_regclass('analytics.v_device_telemetry_availability') IS NULL THEN
        RAISE EXCEPTION 'Migration 299: one of the three normalized-data freshness readers is missing';
    END IF;
END
$pre$;

CREATE TEMP TABLE m299_before ON COMMIT DROP AS
SELECT policy_key, receiving_threshold_seconds, stale_threshold_seconds, silent_threshold_seconds
FROM config.telemetry_availability_policy;

CREATE TEMP TABLE m299_untouched_before ON COMMIT DROP AS
SELECT p.oid::regprocedure::text AS sig, md5(p.prosrc) AS body_md5
FROM pg_proc p
WHERE p.oid IN (
    'analytics.get_grafana_asset_connectivity_context(bigint,uuid,timestamptz)'::regprocedure,
    'analytics.get_grafana_asset_live_state(bigint,uuid,timestamptz)'::regprocedure,
    'admin.get_portal_asset_live_state(bigint,uuid,timestamptz)'::regprocedure
);

-- ----------------------------------------------------------------------------
-- 1. The threshold
-- ----------------------------------------------------------------------------
ALTER TABLE config.telemetry_availability_policy
    ADD COLUMN normalized_receiving_threshold_seconds INTEGER NOT NULL DEFAULT 600;

ALTER TABLE config.telemetry_availability_policy
    ADD CONSTRAINT telemetry_availability_policy_normalized_receiving_check
    CHECK (normalized_receiving_threshold_seconds > 0
           AND normalized_receiving_threshold_seconds < stale_threshold_seconds);

COMMENT ON COLUMN config.telemetry_availability_policy.normalized_receiving_threshold_seconds IS
'Freshness threshold for NORMALIZED telemetry (device_telemetry_state.latest_valid_received_timestamp): FRESH / VALIDATED while the newest valid normalized sample was received within this many seconds. Used by analytics.get_portal_site_telemetry_freshness, analytics.get_grafana_asset_telemetry_context and analytics.v_device_telemetry_availability. Must cover the normalization batch cadence (5 minutes, migration 300) plus capture finalization (~2 min 40 s). Raw-receipt and live-state readers keep receiving_threshold_seconds. Migration 299.';

-- ----------------------------------------------------------------------------
-- 2. analytics.get_portal_site_telemetry_freshness (migration 237 body; only
--    the policy read changes)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_telemetry_freshness
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_at             TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE
(
    site_id             UUID,
    energy_state        TEXT,
    energy_as_of        TIMESTAMPTZ,
    demand_state        TEXT,
    demand_as_of        TIMESTAMPTZ,
    power_quality_state TEXT,
    power_quality_as_of TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, config, telemetry
AS $function$
DECLARE
    v_site_consumption_device_id UUID;
    v_demand_device_id           UUID;
    v_demand_source_role         TEXT;
    v_receiving_seconds          INTEGER;
    v_stale_seconds              INTEGER;
    v_silent_seconds             INTEGER;
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    -- Migration 299: normalized-data freshness uses its own threshold
    -- (normalization runs every 5 minutes); raw/live readers keep 300 s.
    SELECT p.normalized_receiving_threshold_seconds, p.stale_threshold_seconds, p.silent_threshold_seconds
      INTO v_receiving_seconds, v_stale_seconds, v_silent_seconds
    FROM config.telemetry_availability_policy AS p
    WHERE p.policy_key = 'DEFAULT'
    LIMIT 1;

    -- Energy and Power Quality: the same SITE_CONSUMPTION meter
    -- analytics.get_portal_site_power_quality_series (migration 234) already
    -- resolves PQ from. Energy's use of it is an approved approximation
    -- (decision pack Sec 5a) -- a site without this meter yields UNKNOWN for
    -- Energy here, honestly, not a guess.
    SELECT mr.device_id
      INTO v_site_consumption_device_id
    FROM config.site_energy_meter_roles AS mr
    WHERE mr.site_id = p_site_id
      AND mr.meter_role = 'SITE_CONSUMPTION'
      AND mr.is_active
      AND p_at <@ mr.effective_range
    LIMIT 1;

    -- Demand: the currently-effective SITE-scope policy only -- the
    -- customer-facing site Demand figure is always scope_type = 'SITE'
    -- (get_portal_site_demand_series / get_portal_site_current_demand).
    SELECT sp.site_demand_source_role
      INTO v_demand_source_role
    FROM config.resolve_site_demand_policy(p_site_id, p_at) AS sp
    WHERE sp.is_enabled;

    IF v_demand_source_role IS NOT NULL THEN
        SELECT mr.device_id
          INTO v_demand_device_id
        FROM config.site_energy_meter_roles AS mr
        WHERE mr.site_id = p_site_id
          AND mr.meter_role = v_demand_source_role
          AND mr.is_active
          AND mr.is_authoritative
          AND p_at <@ mr.effective_range
        LIMIT 1;
    END IF;

    RETURN QUERY
    WITH consumption_freshness AS (
        SELECT
            CASE
                WHEN v_site_consumption_device_id IS NULL
                    THEN 'UNKNOWN'                                          -- no SITE_CONSUMPTION device configured
                WHEN ts.latest_received_timestamp IS NULL
                    THEN 'NO_DATA'                                          -- internal: NEVER_SEEN
                WHEN ts.latest_received_timestamp
                     < p_at - make_interval(secs => v_silent_seconds)
                    THEN 'NO_DATA'                                          -- internal: SILENT
                WHEN ts.latest_valid_source_timestamp IS NULL
                    THEN 'STALE'                                            -- internal: RECEIVING
                WHEN ts.latest_valid_source_timestamp
                     < p_at - make_interval(secs => v_stale_seconds)
                    THEN 'STALE'                                            -- internal: STALE
                WHEN ts.latest_valid_received_timestamp
                     >= p_at - make_interval(secs => v_receiving_seconds)
                    THEN 'FRESH'                                            -- internal: VALIDATED
                ELSE 'STALE'                                                -- internal: RECEIVING (fallthrough)
            END AS state,
            ts.latest_received_timestamp AS as_of
        FROM (SELECT v_site_consumption_device_id AS device_id) AS d
        LEFT JOIN telemetry.device_telemetry_state AS ts ON ts.device_id = d.device_id
    ),
    demand_freshness AS (
        SELECT
            CASE
                WHEN v_demand_device_id IS NULL
                    THEN 'UNKNOWN'                                          -- no SITE-scope demand device resolved
                WHEN ts.latest_received_timestamp IS NULL
                    THEN 'NO_DATA'
                WHEN ts.latest_received_timestamp
                     < p_at - make_interval(secs => v_silent_seconds)
                    THEN 'NO_DATA'
                WHEN ts.latest_valid_source_timestamp IS NULL
                    THEN 'STALE'
                WHEN ts.latest_valid_source_timestamp
                     < p_at - make_interval(secs => v_stale_seconds)
                    THEN 'STALE'
                WHEN ts.latest_valid_received_timestamp
                     >= p_at - make_interval(secs => v_receiving_seconds)
                    THEN 'FRESH'
                ELSE 'STALE'
            END AS state,
            ts.latest_received_timestamp AS as_of
        FROM (SELECT v_demand_device_id AS device_id) AS d
        LEFT JOIN telemetry.device_telemetry_state AS ts ON ts.device_id = d.device_id
    )
    SELECT
        p_site_id,
        cf.state, cf.as_of,
        df.state, df.as_of,
        cf.state, cf.as_of   -- Power Quality: identical resolution to Energy (same SITE_CONSUMPTION device)
    FROM consumption_freshness AS cf, demand_freshness AS df;
END;
$function$;

ALTER FUNCTION analytics.get_portal_site_telemetry_freshness(BIGINT, UUID, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_telemetry_freshness(BIGINT, UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_telemetry_freshness(BIGINT, UUID, TIMESTAMPTZ) TO ems_app;

-- ----------------------------------------------------------------------------
-- 3. analytics.get_grafana_asset_telemetry_context (migration 019 body; only
--    the policy read and its no-row fallback change)
-- ----------------------------------------------------------------------------
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
    v_receiving_seconds INTEGER := 600;
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

    -- Migration 299: normalized-data freshness uses its own threshold
    -- (normalization runs every 5 minutes); raw/live readers keep 300 s.
    SELECT
        COALESCE(p.normalized_receiving_threshold_seconds, v_receiving_seconds),
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

-- ----------------------------------------------------------------------------
-- 4. analytics.v_device_telemetry_availability (migration 003 body; only the
--    policy CTE changes -- its receiving_threshold_seconds column now carries
--    the normalized-data threshold the view applies)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_device_telemetry_availability
WITH (security_barrier = TRUE)
AS
WITH policy AS (
    SELECT normalized_receiving_threshold_seconds AS receiving_threshold_seconds,
           stale_threshold_seconds, silent_threshold_seconds
    FROM config.telemetry_availability_policy
    WHERE policy_key='DEFAULT'
),
profile_mapping AS (
    SELECT profile_id,
           count(*) AS mapped_point_count,
           count(*) FILTER (WHERE is_required) AS required_point_count
    FROM config.profile_field_mapping
    GROUP BY profile_id
),
asset_association AS (
    SELECT ad.device_id,
           string_agg(DISTINCT a.name, ', ' ORDER BY a.name) AS associated_asset_names
    FROM metadata.asset_devices ad
    JOIN metadata.assets a ON a.id=ad.asset_id
    GROUP BY ad.device_id
)
SELECT
    d.organization_id,
    g.site_id,
    s.name AS site_name,
    g.id AS gateway_id,
    g.name AS gateway_name,
    d.id AS device_id,
    d.name AS device_name,
    d.external_id,
    d.lifecycle_status,
    d.profile_id,
    dp.profile_code,
    coalesce(aa.associated_asset_names,'—') AS associated_asset_names,
    CASE
        WHEN d.profile_id IS NULL OR d.device_model_id IS NULL THEN 'INVALID_PROFILE'
        WHEN NOT EXISTS (
            SELECT 1 FROM config.device_profile_categories dpc
            JOIN metadata.device_models dm ON dm.id=d.device_model_id
            WHERE dpc.profile_id=d.profile_id
              AND dpc.device_category_id=dm.device_category_id
        ) THEN 'INVALID_PROFILE'
        WHEN coalesce(pm.mapped_point_count,0)=0 THEN 'UNMAPPED'
        ELSE 'VALIDATED'
    END AS configuration_state,
    CASE
        WHEN ts.latest_received_timestamp IS NULL THEN 'NEVER_SEEN'
        WHEN ts.latest_received_timestamp < now()-make_interval(secs=>p.silent_threshold_seconds) THEN 'SILENT'
        WHEN d.profile_id IS NULL OR d.device_model_id IS NULL OR coalesce(pm.mapped_point_count,0)=0
          OR NOT EXISTS (
              SELECT 1 FROM config.device_profile_categories dpc
              JOIN metadata.device_models dm ON dm.id=d.device_model_id
              WHERE dpc.profile_id=d.profile_id
                AND dpc.device_category_id=dm.device_category_id
          ) THEN 'INVALID_PROFILE'
        WHEN d.operational_policy='ASSET_ASSIGNED'
         AND NOT EXISTS (SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id=d.id)
        THEN 'UNMAPPED'
        WHEN ts.latest_valid_source_timestamp IS NULL THEN 'RECEIVING'
        WHEN ts.latest_valid_source_timestamp < now()-make_interval(secs=>p.stale_threshold_seconds) THEN 'STALE'
        WHEN ts.latest_valid_received_timestamp >= now()-make_interval(secs=>p.receiving_threshold_seconds) THEN 'VALIDATED'
        ELSE 'RECEIVING'
    END AS telemetry_state,
    ts.latest_source_timestamp,
    ts.latest_received_timestamp,
    ts.latest_valid_source_timestamp,
    ts.latest_valid_received_timestamp,
    CASE
        WHEN d.profile_id IS NULL THEN 'PROFILE_MISSING'
        WHEN d.device_model_id IS NULL THEN 'DEVICE_MODEL_MISSING'
        WHEN NOT EXISTS (
            SELECT 1 FROM config.device_profile_categories dpc
            JOIN metadata.device_models dm ON dm.id=d.device_model_id
            WHERE dpc.profile_id=d.profile_id
              AND dpc.device_category_id=dm.device_category_id
        ) THEN 'PROFILE_CATEGORY_INCOMPATIBLE'
        WHEN coalesce(pm.mapped_point_count,0)=0 THEN 'PROFILE_UNMAPPED'
        ELSE 'PROFILE_VALID'
    END AS profile_validation_result,
    coalesce(pm.mapped_point_count,0)::BIGINT AS mapped_point_count,
    coalesce(pm.required_point_count,0)::BIGINT AS required_point_count,
    p.receiving_threshold_seconds,
    p.stale_threshold_seconds,
    p.silent_threshold_seconds
FROM metadata.devices d
JOIN metadata.gateways g ON g.id=d.gateway_id
JOIN metadata.sites s ON s.id=g.site_id
LEFT JOIN config.device_profiles dp ON dp.id=d.profile_id
LEFT JOIN profile_mapping pm ON pm.profile_id=d.profile_id
LEFT JOIN telemetry.device_telemetry_state ts ON ts.device_id=d.id
LEFT JOIN asset_association aa ON aa.device_id=d.id
CROSS JOIN policy p;

-- ----------------------------------------------------------------------------
-- Postconditions
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_bad text;
    v_def text;
BEGIN
    -- Every policy row: new column = 600; existing thresholds unchanged.
    SELECT string_agg(a.policy_key, ', ') INTO v_bad
    FROM config.telemetry_availability_policy a
    JOIN m299_before b USING (policy_key)
    WHERE a.normalized_receiving_threshold_seconds <> 600
       OR (a.receiving_threshold_seconds, a.stale_threshold_seconds, a.silent_threshold_seconds)
          IS DISTINCT FROM (b.receiving_threshold_seconds, b.stale_threshold_seconds, b.silent_threshold_seconds);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 299: policy rows changed unexpectedly: %', v_bad;
    END IF;

    -- The three normalized-data readers use the new column for the decision.
    v_def := pg_get_functiondef('analytics.get_portal_site_telemetry_freshness(bigint,uuid,timestamptz)'::regprocedure);
    IF position('p.normalized_receiving_threshold_seconds' IN v_def) = 0
       OR position('p.receiving_threshold_seconds' IN v_def) > 0 THEN
        RAISE EXCEPTION 'Migration 299: get_portal_site_telemetry_freshness does not read the normalized threshold';
    END IF;
    v_def := pg_get_functiondef('analytics.get_grafana_asset_telemetry_context(bigint,uuid,timestamptz)'::regprocedure);
    IF position('p.normalized_receiving_threshold_seconds' IN v_def) = 0
       OR position('p.receiving_threshold_seconds' IN v_def) > 0 THEN
        RAISE EXCEPTION 'Migration 299: get_grafana_asset_telemetry_context does not read the normalized threshold';
    END IF;
    v_def := pg_get_viewdef('analytics.v_device_telemetry_availability'::regclass);
    IF position('normalized_receiving_threshold_seconds' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 299: v_device_telemetry_availability does not read the normalized threshold';
    END IF;

    -- Raw-receipt and live-state readers are byte-for-byte unchanged and still
    -- use receiving_threshold_seconds.
    SELECT string_agg(b.sig, ', ') INTO v_bad
    FROM m299_untouched_before b
    JOIN pg_proc p ON p.oid = b.sig::regprocedure
    WHERE md5(p.prosrc) <> b.body_md5
       OR position('receiving_threshold_seconds' IN p.prosrc) = 0
       OR position('normalized_receiving_threshold_seconds' IN p.prosrc) > 0;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 299: raw/live readers changed: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM m299_untouched_before) <> 3 THEN
        RAISE EXCEPTION 'Migration 299: expected 3 raw/live readers, found %', (SELECT count(*) FROM m299_untouched_before);
    END IF;

    -- Security posture of the site freshness function (as migration 237).
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        WHERE p.oid = 'analytics.get_portal_site_telemetry_freshness(bigint,uuid,timestamptz)'::regprocedure
          AND p.prosecdef AND p.provolatile = 's'
          AND pg_get_userbyid(p.proowner) = 'ems_admin'
          AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 299: get_portal_site_telemetry_freshness lost SECURITY DEFINER / STABLE / owner / search_path';
    END IF;

    RAISE NOTICE 'Migration 299: normalized_receiving_threshold_seconds = 600 s; 3 normalized-data readers switched; raw/live readers unchanged (300 s)';
END
$post$;
