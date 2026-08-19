-- 012_demand_capability_resolution.sql
--
-- Add the vendor-neutral demand capability and method-resolution layer that
-- sits between meter/profile semantics and the demand calculation processor.
--
-- This migration intentionally does NOT calculate or finalize demand values.
-- It resolves which trustworthy calculation method is available for a source
-- device and demand basis. The processor is introduced separately.


-- ---------------------------------------------------------------------------
-- 1. Repair demand-interval idempotency for nullable SITE asset_id.
-- ---------------------------------------------------------------------------

ALTER TABLE analytics.demand_intervals
    DROP CONSTRAINT IF EXISTS
    demand_intervals_interval_start_scope_type_site_id_asset_id_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_demand_intervals_site_scope
    ON analytics.demand_intervals(
        site_id,
        interval_start,
        demand_policy_id
    )
    WHERE scope_type = 'SITE';

CREATE UNIQUE INDEX IF NOT EXISTS uq_demand_intervals_asset_scope
    ON analytics.demand_intervals(
        asset_id,
        interval_start,
        demand_policy_id
    )
    WHERE scope_type = 'ASSET';

COMMENT ON INDEX analytics.uq_demand_intervals_site_scope IS
'Idempotency key for finalized SITE demand intervals; avoids nullable asset_id uniqueness gaps.';

COMMENT ON INDEX analytics.uq_demand_intervals_asset_scope IS
'Idempotency key for finalized ASSET demand intervals.';


-- ---------------------------------------------------------------------------
-- 2. Native meter-demand semantics.
--
-- Native demand registers need more than a generic point mapping: their basis,
-- interval and alignment semantics must be explicit before the platform may use
-- them as billing-style demand. No profile is seeded here; profiles opt in only
-- after vendor documentation/commissioning confirms the register semantics.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.demand_register_semantics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    profile_id UUID NOT NULL
        REFERENCES config.device_profiles(id)
        ON DELETE CASCADE,

    logical_point_id UUID NOT NULL
        REFERENCES metadata.logical_points(id),

    demand_basis TEXT NOT NULL,

    native_interval_seconds INTEGER NOT NULL,

    alignment_mode TEXT NOT NULL DEFAULT 'WALL_CLOCK',

    source_unit_symbol TEXT NOT NULL,

    normalized_unit_symbol TEXT NOT NULL,

    scale_to_normalized_unit NUMERIC(24,9) NOT NULL DEFAULT 1.0,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_demand_register_semantics_profile_point
        UNIQUE (profile_id, logical_point_id),

    CONSTRAINT demand_register_semantics_basis_chk
        CHECK (demand_basis IN ('ACTIVE_POWER_KW', 'APPARENT_POWER_KVA')),

    CONSTRAINT demand_register_semantics_interval_chk
        CHECK (native_interval_seconds IN (900, 1800)),

    CONSTRAINT demand_register_semantics_alignment_chk
        CHECK (alignment_mode = 'WALL_CLOCK'),

    CONSTRAINT demand_register_semantics_scale_chk
        CHECK (scale_to_normalized_unit > 0),

    CONSTRAINT demand_register_semantics_units_chk
        CHECK (
            btrim(source_unit_symbol) <> ''
            AND btrim(normalized_unit_symbol) <> ''
        ),

    CONSTRAINT demand_register_semantics_normalized_unit_chk
        CHECK (
            (demand_basis = 'ACTIVE_POWER_KW' AND normalized_unit_symbol = 'kW')
            OR
            (demand_basis = 'APPARENT_POWER_KVA' AND normalized_unit_symbol = 'kVA')
        )
);

CREATE INDEX IF NOT EXISTS ix_demand_register_semantics_profile
    ON config.demand_register_semantics(profile_id)
    WHERE is_active;

COMMENT ON TABLE config.demand_register_semantics IS
'Profile-specific semantics for true meter-native demand registers. Presence of a raw field alone is insufficient; native interval and basis must be explicitly certified.';


-- ---------------------------------------------------------------------------
-- 3. Per-device demand-method capability resolver.
--
-- Capability is derived from the assigned device profile and canonical logical
-- point mappings. It is NOT inferred from whichever telemetry columns happen to
-- be non-NULL at query time.
--
-- Method priority:
--   1. METER_NATIVE           when explicitly certified and interval-compatible
--   2. ENERGY_COUNTER_DELTA   when canonical cumulative energy semantics exist
--   3. TIME_WEIGHTED_POWER    when canonical instantaneous power is mapped
--
-- Runtime telemetry sufficiency/coverage remains the processor's concern.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION config.resolve_device_demand_method(
    p_device_id UUID,
    p_demand_basis TEXT,
    p_demand_interval_seconds INTEGER
)
RETURNS TABLE (
    device_id UUID,
    profile_id UUID,
    profile_code TEXT,
    demand_basis TEXT,
    demand_interval_seconds INTEGER,
    selected_method TEXT,
    capability_ready BOOLEAN,
    readiness_status TEXT,
    source_logical_point_id UUID,
    source_logical_point_name TEXT,
    fallback_logical_point_id UUID,
    fallback_logical_point_name TEXT
)
LANGUAGE SQL
STABLE
SET search_path TO pg_catalog, config, metadata
AS $function$
WITH requested AS (
    SELECT
        upper(btrim(p_demand_basis)) AS demand_basis,
        p_demand_interval_seconds AS demand_interval_seconds
),
device_profile AS (
    SELECT
        d.id AS device_id,
        dp.id AS profile_id,
        dp.profile_code
    FROM metadata.devices AS d
    LEFT JOIN config.device_profiles AS dp
      ON dp.id = d.profile_id
     AND dp.is_active
    WHERE d.id = p_device_id
),
configured_points AS (
    SELECT DISTINCT
        dp.profile_id,
        dpc.logical_point_id,
        lp.name AS logical_point_name
    FROM device_profile AS dp
    JOIN config.device_point_configuration AS dpc
      ON dpc.device_id = dp.device_id
     AND dpc.is_enabled
    JOIN metadata.logical_points AS lp
      ON lp.id = dpc.logical_point_id
    WHERE EXISTS (
        SELECT 1
        FROM config.profile_field_mapping AS pfm
        WHERE pfm.profile_id = dp.profile_id
          AND pfm.logical_point_id = dpc.logical_point_id
    )
    OR EXISTS (
        SELECT 1
        FROM metadata.device_field_mapping AS dfm
        WHERE dfm.device_id = dp.device_id
          AND dfm.logical_point_id = dpc.logical_point_id
    )
),
profile_points AS (
    SELECT DISTINCT
        pfm.profile_id,
        pfm.logical_point_id,
        lp.name AS logical_point_name
    FROM device_profile AS dp
    JOIN config.profile_field_mapping AS pfm
      ON pfm.profile_id = dp.profile_id
    JOIN metadata.logical_points AS lp
      ON lp.id = pfm.logical_point_id
),
native_candidate AS (
    SELECT
        drs.logical_point_id,
        mp.logical_point_name
    FROM requested AS rq
    JOIN device_profile AS dp ON TRUE
    JOIN config.demand_register_semantics AS drs
      ON drs.profile_id = dp.profile_id
     AND drs.is_active
     AND drs.demand_basis = rq.demand_basis
     AND drs.native_interval_seconds = rq.demand_interval_seconds
     AND drs.alignment_mode = 'WALL_CLOCK'
    JOIN configured_points AS mp
      ON mp.logical_point_id = drs.logical_point_id
    ORDER BY mp.logical_point_name, drs.logical_point_id
    LIMIT 1
),
counter_candidate AS (
    SELECT
        ers.logical_point_id,
        mp.logical_point_name
    FROM requested AS rq
    JOIN device_profile AS dp ON TRUE
    JOIN config.energy_register_semantics AS ers
      ON ers.profile_id = dp.profile_id
     AND ers.is_active
    JOIN configured_points AS mp
      ON mp.logical_point_id = ers.logical_point_id
    WHERE
        (
            rq.demand_basis = 'ACTIVE_POWER_KW'
            AND mp.logical_point_name = 'ENERGY_IMPORT_TOTAL'
            AND ers.normalized_unit_symbol = 'Wh'
        )
        OR
        (
            rq.demand_basis = 'APPARENT_POWER_KVA'
            AND mp.logical_point_name = 'ENERGY_APPARENT_ENERGY_TOTAL'
            AND ers.normalized_unit_symbol = 'VAh'
        )
    ORDER BY mp.logical_point_name, ers.logical_point_id
    LIMIT 1
),
power_candidate AS (
    SELECT
        mp.logical_point_id,
        mp.logical_point_name
    FROM requested AS rq
    JOIN configured_points AS mp ON TRUE
    WHERE
        (
            rq.demand_basis = 'ACTIVE_POWER_KW'
            AND mp.logical_point_name = 'ENERGY_ACTIVE_POWER_TOTAL'
        )
        OR
        (
            rq.demand_basis = 'APPARENT_POWER_KVA'
            AND mp.logical_point_name = 'ENERGY_APPARENT_POWER_TOTAL'
        )
    ORDER BY mp.logical_point_name, mp.logical_point_id
    LIMIT 1
),
profile_basis_capability AS (
    SELECT EXISTS (
        SELECT 1
        FROM requested AS rq
        JOIN profile_points AS pp ON TRUE
        WHERE
            (
                rq.demand_basis = 'ACTIVE_POWER_KW'
                AND pp.logical_point_name IN (
                    'ENERGY_IMPORT_TOTAL',
                    'ENERGY_ACTIVE_POWER_TOTAL'
                )
            )
            OR
            (
                rq.demand_basis = 'APPARENT_POWER_KVA'
                AND pp.logical_point_name IN (
                    'ENERGY_APPARENT_ENERGY_TOTAL',
                    'ENERGY_APPARENT_POWER_TOTAL'
                )
            )
    ) AS profile_supports_basis
)
SELECT
    dp.device_id,
    dp.profile_id,
    dp.profile_code,
    rq.demand_basis,
    rq.demand_interval_seconds,
    CASE
        WHEN rq.demand_basis NOT IN ('ACTIVE_POWER_KW', 'APPARENT_POWER_KVA')
            THEN NULL::TEXT
        WHEN rq.demand_interval_seconds NOT IN (900, 1800)
            THEN NULL::TEXT
        WHEN dp.device_id IS NULL OR dp.profile_id IS NULL
            THEN NULL::TEXT
        WHEN nc.logical_point_id IS NOT NULL
            THEN 'METER_NATIVE'
        WHEN cc.logical_point_id IS NOT NULL
            THEN 'ENERGY_COUNTER_DELTA'
        WHEN pc.logical_point_id IS NOT NULL
            THEN 'TIME_WEIGHTED_POWER'
        ELSE NULL::TEXT
    END AS selected_method,
    CASE
        WHEN rq.demand_basis NOT IN ('ACTIVE_POWER_KW', 'APPARENT_POWER_KVA')
            THEN FALSE
        WHEN rq.demand_interval_seconds NOT IN (900, 1800)
            THEN FALSE
        WHEN dp.device_id IS NULL OR dp.profile_id IS NULL
            THEN FALSE
        WHEN nc.logical_point_id IS NOT NULL
          OR cc.logical_point_id IS NOT NULL
          OR pc.logical_point_id IS NOT NULL
            THEN TRUE
        ELSE FALSE
    END AS capability_ready,
    CASE
        WHEN rq.demand_basis NOT IN ('ACTIVE_POWER_KW', 'APPARENT_POWER_KVA')
            THEN 'INVALID_DEMAND_BASIS'
        WHEN rq.demand_interval_seconds NOT IN (900, 1800)
            THEN 'INVALID_DEMAND_INTERVAL'
        WHEN dp.device_id IS NULL
            THEN 'SOURCE_DEVICE_NOT_FOUND'
        WHEN dp.profile_id IS NULL
            THEN 'SOURCE_PROFILE_NOT_CONFIGURED'
        WHEN nc.logical_point_id IS NOT NULL
          OR cc.logical_point_id IS NOT NULL
          OR pc.logical_point_id IS NOT NULL
            THEN 'READY'
        WHEN pbc.profile_supports_basis
            THEN 'SOURCE_POINT_NOT_ENABLED'
        ELSE 'BASIS_NOT_SUPPORTED'
    END AS readiness_status,
    COALESCE(nc.logical_point_id, cc.logical_point_id, pc.logical_point_id),
    COALESCE(nc.logical_point_name, cc.logical_point_name, pc.logical_point_name),
    CASE
        WHEN nc.logical_point_id IS NOT NULL AND cc.logical_point_id IS NOT NULL
            THEN cc.logical_point_id
        WHEN nc.logical_point_id IS NOT NULL AND pc.logical_point_id IS NOT NULL
            THEN pc.logical_point_id
        WHEN cc.logical_point_id IS NOT NULL AND pc.logical_point_id IS NOT NULL
            THEN pc.logical_point_id
        ELSE NULL::UUID
    END,
    CASE
        WHEN nc.logical_point_id IS NOT NULL AND cc.logical_point_id IS NOT NULL
            THEN cc.logical_point_name
        WHEN nc.logical_point_id IS NOT NULL AND pc.logical_point_id IS NOT NULL
            THEN pc.logical_point_name
        WHEN cc.logical_point_id IS NOT NULL AND pc.logical_point_id IS NOT NULL
            THEN pc.logical_point_name
        ELSE NULL::TEXT
    END
FROM requested AS rq
LEFT JOIN device_profile AS dp ON TRUE
LEFT JOIN native_candidate AS nc ON TRUE
LEFT JOIN counter_candidate AS cc ON TRUE
LEFT JOIN power_candidate AS pc ON TRUE
LEFT JOIN profile_basis_capability AS pbc ON TRUE;
$function$;

COMMENT ON FUNCTION config.resolve_device_demand_method(UUID, TEXT, INTEGER) IS
'Resolves the best trustworthy demand method from the active device profile, enabled device-point configuration and semantic contracts without inspecting current telemetry values.';


-- ---------------------------------------------------------------------------
-- 4. Scope-aware demand capability resolver.
--
-- SITE: source comes only from the policy-selected authoritative site role.
-- ASSET: source comes only from the asset PRIMARY_METER relationship.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.resolve_demand_capability(
    p_site_id UUID,
    p_scope_type TEXT,
    p_asset_id UUID DEFAULT NULL,
    p_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE (
    site_id UUID,
    scope_type TEXT,
    asset_id UUID,
    demand_policy_id UUID,
    demand_monitoring_enabled BOOLEAN,
    demand_interval_seconds INTEGER,
    demand_basis TEXT,
    source_role TEXT,
    source_device_id UUID,
    source_device_name TEXT,
    source_profile_id UUID,
    source_profile_code TEXT,
    selected_method TEXT,
    capability_ready BOOLEAN,
    readiness_status TEXT,
    source_logical_point_id UUID,
    source_logical_point_name TEXT,
    fallback_logical_point_id UUID,
    fallback_logical_point_name TEXT
)
LANGUAGE SQL
STABLE
SET search_path TO pg_catalog, analytics, config, metadata
AS $function$
WITH requested AS (
    SELECT upper(btrim(p_scope_type)) AS scope_type
),
policy AS (
    SELECT *
    FROM config.resolve_site_demand_policy(p_site_id, p_at)
),
site_source AS (
    SELECT
        r.device_id,
        d.name AS device_name
    FROM policy AS p
    JOIN config.site_energy_meter_roles AS r
      ON r.site_id = p.site_id
     AND r.meter_role = p.site_demand_source_role
     AND r.is_active
     AND r.is_authoritative
     AND p_at >= r.effective_from
     AND (r.effective_to IS NULL OR p_at < r.effective_to)
    JOIN metadata.devices AS d
      ON d.id = r.device_id
    ORDER BY r.effective_from DESC, r.created_at DESC, r.id DESC
    LIMIT 1
),
asset_source AS (
    SELECT
        ad.device_id,
        d.name AS device_name
    FROM metadata.assets AS a
    JOIN metadata.asset_devices AS ad
      ON ad.asset_id = a.id
     AND ad.relationship_type = 'PRIMARY_METER'
    JOIN metadata.devices AS d
      ON d.id = ad.device_id
    WHERE a.id = p_asset_id
      AND a.site_id = p_site_id
    LIMIT 1
),
source AS (
    SELECT
        rq.scope_type,
        CASE
            WHEN rq.scope_type = 'SITE' THEN ss.device_id
            WHEN rq.scope_type = 'ASSET' THEN aus.device_id
            ELSE NULL::UUID
        END AS device_id,
        CASE
            WHEN rq.scope_type = 'SITE' THEN ss.device_name
            WHEN rq.scope_type = 'ASSET' THEN aus.device_name
            ELSE NULL::TEXT
        END AS device_name
    FROM requested AS rq
    LEFT JOIN site_source AS ss ON TRUE
    LEFT JOIN asset_source AS aus ON TRUE
),
resolved AS (
    SELECT r.*
    FROM policy AS p
    JOIN source AS s ON s.device_id IS NOT NULL
    CROSS JOIN LATERAL config.resolve_device_demand_method(
        s.device_id,
        p.demand_basis,
        p.demand_interval_seconds
    ) AS r
)
SELECT
    p_site_id,
    rq.scope_type,
    CASE WHEN rq.scope_type = 'ASSET' THEN p_asset_id ELSE NULL::UUID END,
    p.policy_id,
    COALESCE(p.is_enabled, FALSE),
    p.demand_interval_seconds,
    p.demand_basis,
    CASE WHEN rq.scope_type = 'SITE' THEN p.site_demand_source_role ELSE 'PRIMARY_METER' END,
    s.device_id,
    s.device_name,
    r.profile_id,
    r.profile_code,
    r.selected_method,
    COALESCE(p.is_enabled, FALSE)
        AND COALESCE(r.capability_ready, FALSE),
    CASE
        WHEN rq.scope_type NOT IN ('SITE', 'ASSET')
            THEN 'INVALID_SCOPE'
        WHEN p.policy_id IS NULL
            THEN 'NOT_CONFIGURED'
        WHEN NOT p.is_enabled
            THEN 'DISABLED'
        WHEN rq.scope_type = 'ASSET' AND p_asset_id IS NULL
            THEN 'ASSET_NOT_SPECIFIED'
        WHEN s.device_id IS NULL
            THEN 'SOURCE_NOT_CONFIGURED'
        WHEN NOT COALESCE(r.capability_ready, FALSE)
            THEN COALESCE(r.readiness_status, 'BASIS_NOT_SUPPORTED')
        ELSE 'READY'
    END,
    r.source_logical_point_id,
    r.source_logical_point_name,
    r.fallback_logical_point_id,
    r.fallback_logical_point_name
FROM requested AS rq
LEFT JOIN policy AS p ON TRUE
LEFT JOIN source AS s ON TRUE
LEFT JOIN resolved AS r ON TRUE;
$function$;

COMMENT ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ) IS
'Resolves policy, authoritative source and vendor-neutral demand method for SITE or ASSET scope. Does not inspect transient telemetry availability.';


-- ---------------------------------------------------------------------------
-- 5. Make the existing admin readiness status capability-aware without
-- changing its user-facing return contract.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.get_site_demand_readiness(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID
)
RETURNS TABLE (
    policy_configured BOOLEAN,
    demand_monitoring_enabled BOOLEAN,
    demand_interval_seconds INTEGER,
    demand_basis TEXT,
    site_demand_source_role TEXT,
    source_device_id UUID,
    source_device_name TEXT,
    source_ready BOOLEAN,
    readiness_status TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, analytics, config, metadata
AS $function$
BEGIN
    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        p_site_id
    ) THEN
        RAISE EXCEPTION
            'Site is outside the actor access scope.'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        (c.demand_policy_id IS NOT NULL) AS policy_configured,
        c.demand_monitoring_enabled,
        c.demand_interval_seconds,
        c.demand_basis,
        c.source_role,
        c.source_device_id,
        c.source_device_name,
        c.capability_ready AS source_ready,
        c.readiness_status
    FROM analytics.resolve_demand_capability(
        p_site_id,
        'SITE',
        NULL,
        clock_timestamp()
    ) AS c;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 6. Ownership and access boundaries.
-- ---------------------------------------------------------------------------

ALTER TABLE config.demand_register_semantics OWNER TO ems_admin;

ALTER FUNCTION config.resolve_device_demand_method(UUID, TEXT, INTEGER)
    OWNER TO ems_admin;

ALTER FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
    OWNER TO ems_admin;

ALTER FUNCTION admin.get_site_demand_readiness(BIGINT, UUID)
    OWNER TO ems_admin;

REVOKE ALL ON config.demand_register_semantics
FROM PUBLIC, ems_app;

REVOKE ALL ON FUNCTION config.resolve_device_demand_method(UUID, TEXT, INTEGER)
FROM PUBLIC, ems_app;

REVOKE ALL ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
FROM PUBLIC, ems_app;

REVOKE ALL ON FUNCTION admin.get_site_demand_readiness(BIGINT, UUID)
FROM PUBLIC;

GRANT SELECT ON config.demand_register_semantics
TO ems_readonly, grafana_reader;

GRANT EXECUTE ON FUNCTION config.resolve_device_demand_method(UUID, TEXT, INTEGER)
TO ems_readonly, grafana_reader;

GRANT EXECUTE ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
TO ems_readonly, grafana_reader;

GRANT EXECUTE ON FUNCTION admin.get_site_demand_readiness(BIGINT, UUID)
TO ems_app;
