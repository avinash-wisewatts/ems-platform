-- 011_site_demand_policy_contract.sql
--
-- Establish the canonical, effective-dated site demand policy and storage
-- contracts. This migration intentionally does NOT use the legacy fixed
-- telemetry.ca_energy_15min aggregate as the authoritative demand engine.
--
-- Demand calculation processors are introduced separately.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Mark site energy roles that are eligible to represent site demand.
-- ---------------------------------------------------------------------------

ALTER TABLE config.site_energy_roles
    ADD COLUMN IF NOT EXISTS is_demand_source_eligible BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE config.site_energy_roles
SET is_demand_source_eligible =
    role_code IN ('GRID_IMPORT', 'SITE_CONSUMPTION');

COMMENT ON COLUMN config.site_energy_roles.is_demand_source_eligible IS
'True when the controlled site energy role may be selected as the authoritative source for site demand monitoring.';


-- ---------------------------------------------------------------------------
-- 2. Effective-dated site demand policy.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.site_demand_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    site_id UUID NOT NULL
        REFERENCES metadata.sites(id)
        ON DELETE CASCADE,

    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,

    demand_interval_seconds INTEGER NOT NULL,

    demand_basis TEXT NOT NULL,

    site_demand_source_role TEXT NOT NULL
        REFERENCES config.site_energy_roles(role_code),

    alignment_mode TEXT NOT NULL DEFAULT 'WALL_CLOCK',

    minimum_coverage_percent NUMERIC(5,2) NOT NULL DEFAULT 90.00,

    late_arrival_tolerance_seconds INTEGER NOT NULL DEFAULT 30,

    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    effective_range TSTZRANGE
        GENERATED ALWAYS AS (
            tstzrange(
                effective_from,
                COALESCE(effective_to, 'infinity'::timestamptz),
                '[)'
            )
        ) STORED,

    CONSTRAINT site_demand_policy_interval_chk
        CHECK (demand_interval_seconds IN (900, 1800)),

    CONSTRAINT site_demand_policy_basis_chk
        CHECK (demand_basis IN ('ACTIVE_POWER_KW', 'APPARENT_POWER_KVA')),

    CONSTRAINT site_demand_policy_alignment_chk
        CHECK (alignment_mode = 'WALL_CLOCK'),

    CONSTRAINT site_demand_policy_coverage_chk
        CHECK (
            minimum_coverage_percent >= 0
            AND minimum_coverage_percent <= 100
        ),

    CONSTRAINT site_demand_policy_late_tolerance_chk
        CHECK (
            late_arrival_tolerance_seconds >= 0
            AND late_arrival_tolerance_seconds <= 3600
        ),

    CONSTRAINT site_demand_policy_effective_window_chk
        CHECK (
            effective_to IS NULL
            OR effective_to > effective_from
        )
);

CREATE INDEX IF NOT EXISTS ix_site_demand_policies_site
    ON config.site_demand_policies(site_id, effective_from DESC);


-- Prevent overlapping demand policy windows for one site.

ALTER TABLE config.site_demand_policies
    DROP CONSTRAINT IF EXISTS ex_site_demand_policy_no_overlap;

ALTER TABLE config.site_demand_policies
    ADD CONSTRAINT ex_site_demand_policy_no_overlap
    EXCLUDE USING gist (
        site_id WITH =,
        effective_range WITH &&
    );


COMMENT ON TABLE config.site_demand_policies IS
'Effective-dated site demand-monitoring configuration. Demand interval and demand calculation semantics are independent of normalized telemetry storage resolution.';


-- ---------------------------------------------------------------------------
-- 3. Validate demand source role.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION config.validate_site_demand_policy()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, config, metadata
AS $function$
DECLARE
    v_role_active BOOLEAN;
    v_role_eligible BOOLEAN;
    v_site_status TEXT;
BEGIN
    NEW.demand_basis := upper(btrim(NEW.demand_basis));
    NEW.site_demand_source_role :=
        upper(btrim(NEW.site_demand_source_role));

    SELECT
        r.is_active,
        r.is_demand_source_eligible
    INTO
        v_role_active,
        v_role_eligible
    FROM config.site_energy_roles AS r
    WHERE r.role_code = NEW.site_demand_source_role;

    IF NOT FOUND
       OR NOT v_role_active
       OR NOT v_role_eligible
    THEN
        RAISE EXCEPTION
            'Select an active site energy role that is eligible for demand monitoring.'
            USING ERRCODE = '23514';
    END IF;

    SELECT s.lifecycle_status
    INTO v_site_status
    FROM metadata.sites AS s
    WHERE s.id = NEW.site_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Site was not found.'
            USING ERRCODE = '23514';
    END IF;

    IF v_site_status = 'DECOMMISSIONED' THEN
        RAISE EXCEPTION
            'Demand monitoring cannot be configured for a decommissioned site.'
            USING ERRCODE = '23514';
    END IF;

    NEW.updated_at := clock_timestamp();

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS trg_validate_site_demand_policy
ON config.site_demand_policies;

CREATE TRIGGER trg_validate_site_demand_policy
BEFORE INSERT OR UPDATE
ON config.site_demand_policies
FOR EACH ROW
EXECUTE FUNCTION config.validate_site_demand_policy();


-- ---------------------------------------------------------------------------
-- 4. Finalized demand intervals.
--
-- asset_id IS NULL for SITE demand.
-- asset_id IS NOT NULL for ASSET demand.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS analytics.demand_intervals (
    interval_start TIMESTAMPTZ NOT NULL,
    interval_end TIMESTAMPTZ NOT NULL,

    organization_id UUID NOT NULL
        REFERENCES metadata.organizations(id),

    site_id UUID NOT NULL
        REFERENCES metadata.sites(id),

    scope_type TEXT NOT NULL,

    asset_id UUID
        REFERENCES metadata.assets(id),

    demand_policy_id UUID NOT NULL
        REFERENCES config.site_demand_policies(id),

    source_device_id UUID
        REFERENCES metadata.devices(id),

    demand_kw DOUBLE PRECISION,
    demand_kva DOUBLE PRECISION,

    peak_power_kw DOUBLE PRECISION,

    energy_kwh NUMERIC(20,6),

    source_method TEXT NOT NULL,

    expected_observations INTEGER,
    observed_observations INTEGER,

    coverage_percent NUMERIC(5,2),

    quality_status TEXT NOT NULL,

    finalized_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT demand_intervals_scope_chk
        CHECK (
            (scope_type = 'SITE' AND asset_id IS NULL)
            OR
            (scope_type = 'ASSET' AND asset_id IS NOT NULL)
        ),

    CONSTRAINT demand_intervals_window_chk
        CHECK (interval_end > interval_start),

    CONSTRAINT demand_intervals_source_method_chk
        CHECK (
            source_method IN (
                'METER_NATIVE',
                'ENERGY_COUNTER_DELTA',
                'TIME_WEIGHTED_POWER'
            )
        ),

    CONSTRAINT demand_intervals_quality_chk
        CHECK (
            quality_status IN (
                'VALID',
                'INCOMPLETE',
                'NO_DATA',
                'INVALID_SOURCE',
                'INSUFFICIENT_SOURCE_RESOLUTION'
            )
        ),

    CONSTRAINT demand_intervals_coverage_chk
        CHECK (
            coverage_percent IS NULL
            OR (
                coverage_percent >= 0
                AND coverage_percent <= 100
            )
        ),

    CONSTRAINT demand_intervals_observation_chk
        CHECK (
            expected_observations IS NULL
            OR expected_observations >= 0
        ),

    CONSTRAINT demand_intervals_observed_chk
        CHECK (
            observed_observations IS NULL
            OR observed_observations >= 0
        ),

    UNIQUE (
        interval_start,
        scope_type,
        site_id,
        asset_id,
        demand_policy_id
    )
);


CREATE INDEX IF NOT EXISTS ix_demand_intervals_site_time
    ON analytics.demand_intervals(site_id, interval_start DESC);

CREATE INDEX IF NOT EXISTS ix_demand_intervals_asset_time
    ON analytics.demand_intervals(asset_id, interval_start DESC)
    WHERE asset_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_demand_intervals_valid_peak
    ON analytics.demand_intervals(
        site_id,
        scope_type,
        interval_start DESC
    )
    WHERE quality_status = 'VALID';


COMMENT ON TABLE analytics.demand_intervals IS
'Canonical finalized demand intervals. Only quality_status=VALID intervals are eligible for peak-demand calculations.';


-- ---------------------------------------------------------------------------
-- 5. Current/open demand interval state.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS analytics.demand_state (
    site_id UUID NOT NULL
        REFERENCES metadata.sites(id)
        ON DELETE CASCADE,

    scope_type TEXT NOT NULL,

    asset_id UUID
        REFERENCES metadata.assets(id)
        ON DELETE CASCADE,

    demand_policy_id UUID NOT NULL
        REFERENCES config.site_demand_policies(id),

    source_device_id UUID
        REFERENCES metadata.devices(id),

    interval_start TIMESTAMPTZ NOT NULL,
    interval_end TIMESTAMPTZ NOT NULL,

    current_demand_kw DOUBLE PRECISION,
    current_demand_kva DOUBLE PRECISION,

    expected_observations INTEGER,
    observed_observations INTEGER,

    coverage_percent NUMERIC(5,2),

    quality_status TEXT NOT NULL,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT demand_state_scope_chk
        CHECK (
            (scope_type = 'SITE' AND asset_id IS NULL)
            OR
            (scope_type = 'ASSET' AND asset_id IS NOT NULL)
        ),

    CONSTRAINT demand_state_window_chk
        CHECK (interval_end > interval_start),

    CONSTRAINT demand_state_quality_chk
        CHECK (
            quality_status IN (
                'PROVISIONAL',
                'INCOMPLETE',
                'NO_DATA',
                'INVALID_SOURCE',
                'INSUFFICIENT_SOURCE_RESOLUTION'
            )
        ),

    CONSTRAINT demand_state_coverage_chk
        CHECK (
            coverage_percent IS NULL
            OR (
                coverage_percent >= 0
                AND coverage_percent <= 100
            )
        )
);


CREATE UNIQUE INDEX IF NOT EXISTS uq_demand_state_site_scope
    ON analytics.demand_state(site_id)
    WHERE scope_type = 'SITE';

CREATE UNIQUE INDEX IF NOT EXISTS uq_demand_state_asset_scope
    ON analytics.demand_state(asset_id)
    WHERE scope_type = 'ASSET';


COMMENT ON TABLE analytics.demand_state IS
'Current provisional demand-interval state. This is distinct from instantaneous electrical power.';


-- ---------------------------------------------------------------------------
-- 6. Effective policy resolver.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION config.resolve_site_demand_policy(
    p_site_id UUID,
    p_at TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS TABLE (
    policy_id UUID,
    site_id UUID,
    is_enabled BOOLEAN,
    demand_interval_seconds INTEGER,
    demand_basis TEXT,
    site_demand_source_role TEXT,
    alignment_mode TEXT,
    minimum_coverage_percent NUMERIC,
    late_arrival_tolerance_seconds INTEGER,
    effective_from TIMESTAMPTZ,
    effective_to TIMESTAMPTZ
)
LANGUAGE SQL
STABLE
SET search_path TO pg_catalog, config
AS $function$
SELECT
    p.id,
    p.site_id,
    p.is_enabled,
    p.demand_interval_seconds,
    p.demand_basis,
    p.site_demand_source_role,
    p.alignment_mode,
    p.minimum_coverage_percent,
    p.late_arrival_tolerance_seconds,
    p.effective_from,
    p.effective_to
FROM config.site_demand_policies AS p
WHERE p.site_id = p_site_id
  AND p_at >= p.effective_from
  AND (
      p.effective_to IS NULL
      OR p_at < p.effective_to
  )
ORDER BY p.effective_from DESC, p.id DESC
LIMIT 1;
$function$;


-- ---------------------------------------------------------------------------
-- 7. Admin read contract.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.get_site_demand_policy(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID
)
RETURNS TABLE (
    policy_id UUID,
    is_enabled BOOLEAN,
    demand_interval_seconds INTEGER,
    demand_basis TEXT,
    site_demand_source_role TEXT,
    alignment_mode TEXT,
    minimum_coverage_percent NUMERIC,
    late_arrival_tolerance_seconds INTEGER,
    effective_from TIMESTAMPTZ,
    effective_to TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
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
        p.policy_id,
        p.is_enabled,
        p.demand_interval_seconds,
        p.demand_basis,
        p.site_demand_source_role,
        p.alignment_mode,
        p.minimum_coverage_percent,
        p.late_arrival_tolerance_seconds,
        p.effective_from,
        p.effective_to
    FROM config.resolve_site_demand_policy(
        p_site_id,
        clock_timestamp()
    ) AS p;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 8. Admin write contract.
--
-- Effective-dated:
--   * closes a policy active at the new effective timestamp
--   * respects an already scheduled future policy
--   * inserts a new immutable historical policy row
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.set_site_demand_policy(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID,
    p_is_enabled BOOLEAN,
    p_demand_interval_seconds INTEGER,
    p_demand_basis TEXT,
    p_site_demand_source_role TEXT,
    p_minimum_coverage_percent NUMERIC,
    p_late_arrival_tolerance_seconds INTEGER,
    p_change_reason TEXT,
    p_effective_from TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_effective_from TIMESTAMPTZ :=
        COALESCE(p_effective_from, clock_timestamp());

    v_next_effective_from TIMESTAMPTZ;
    v_policy_id UUID;
    v_org UUID;
    v_tx UUID := gen_random_uuid();
    v_basis TEXT := upper(btrim(p_demand_basis));
    v_source_role TEXT := upper(btrim(p_site_demand_source_role));
BEGIN
    IF NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,
        'site.manage'
    ) THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to manage sites.'
            USING ERRCODE = '42501';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        p_site_id
    ) THEN
        RAISE EXCEPTION
            'Site is outside the actor access scope.'
            USING ERRCODE = '42501';
    END IF;

    SELECT s.organization_id
    INTO v_org
    FROM metadata.sites AS s
    WHERE s.id = p_site_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Site was not found.'
            USING ERRCODE = '22023';
    END IF;

    IF p_demand_interval_seconds NOT IN (900, 1800) THEN
        RAISE EXCEPTION
            'Demand interval must be 900 or 1800 seconds.'
            USING ERRCODE = '22023';
    END IF;

    IF v_basis NOT IN (
        'ACTIVE_POWER_KW',
        'APPARENT_POWER_KVA'
    ) THEN
        RAISE EXCEPTION
            'Demand basis must be ACTIVE_POWER_KW or APPARENT_POWER_KVA.'
            USING ERRCODE = '22023';
    END IF;

    IF p_minimum_coverage_percent < 0
       OR p_minimum_coverage_percent > 100
    THEN
        RAISE EXCEPTION
            'Minimum demand coverage must be between 0 and 100 percent.'
            USING ERRCODE = '22023';
    END IF;

    IF p_late_arrival_tolerance_seconds < 0
       OR p_late_arrival_tolerance_seconds > 3600
    THEN
        RAISE EXCEPTION
            'Demand late-data allowance must be between 0 and 3600 seconds.'
            USING ERRCODE = '22023';
    END IF;

    IF NULLIF(btrim(p_change_reason), '') IS NULL THEN
        RAISE EXCEPTION
            'Change reason is required.'
            USING ERRCODE = '22023';
    END IF;

    -- Determine the next already-scheduled policy, if one exists.
    SELECT min(p.effective_from)
    INTO v_next_effective_from
    FROM config.site_demand_policies AS p
    WHERE p.site_id = p_site_id
      AND p.effective_from > v_effective_from;

    -- Close whichever policy owns the requested effective timestamp.
    UPDATE config.site_demand_policies AS p
    SET
        effective_to = v_effective_from,
        updated_at = clock_timestamp()
    WHERE p.site_id = p_site_id
      AND p.effective_from < v_effective_from
      AND (
          p.effective_to IS NULL
          OR p.effective_to > v_effective_from
      );

    -- If a policy starts at exactly the requested timestamp, replace it.
    DELETE FROM config.site_demand_policies AS p
    WHERE p.site_id = p_site_id
      AND p.effective_from = v_effective_from;

    INSERT INTO config.site_demand_policies (
        site_id,
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
    VALUES (
        p_site_id,
        p_is_enabled,
        p_demand_interval_seconds,
        v_basis,
        v_source_role,
        'WALL_CLOCK',
        p_minimum_coverage_percent,
        p_late_arrival_tolerance_seconds,
        v_effective_from,
        v_next_effective_from
    )
    RETURNING id
    INTO v_policy_id;

    PERFORM admin.write_audit_event(
        v_tx,
        p_actor_portal_user_id,
        'SET_SITE_DEMAND_POLICY',
        'SITE_DEMAND_POLICY',
        v_policy_id,
        v_org,
        p_site_id,
        '{}'::jsonb,
        jsonb_build_object(
            'site_id', p_site_id,
            'is_enabled', p_is_enabled,
            'demand_interval_seconds', p_demand_interval_seconds,
            'demand_basis', v_basis,
            'site_demand_source_role', v_source_role,
            'alignment_mode', 'WALL_CLOCK',
            'minimum_coverage_percent', p_minimum_coverage_percent,
            'late_arrival_tolerance_seconds',
                p_late_arrival_tolerance_seconds,
            'effective_from', v_effective_from,
            'effective_to', v_next_effective_from,
            'change_reason', btrim(p_change_reason)
        ),
        'SUCCEEDED',
        NULL
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'entity_type', 'SITE_DEMAND_POLICY',
        'entity_id', v_policy_id,
        'policy_id', v_policy_id,
        'organization_id', v_org,
        'site_id', p_site_id,
        'audit_transaction_id', v_tx
    );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 9. Admin readiness contract.
--
-- Policy readiness and actual meter assignment are intentionally separate.
-- A site without an effective authoritative meter must NOT appear as 0 kW.
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
SET search_path TO pg_catalog, admin, config, metadata
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
    WITH policy AS (
        SELECT *
        FROM config.resolve_site_demand_policy(
            p_site_id,
            clock_timestamp()
        )
    ),
    source AS (
        SELECT
            r.device_id,
            d.name AS device_name
        FROM policy p
        JOIN config.site_energy_meter_roles r
          ON r.site_id = p.site_id
         AND r.meter_role = p.site_demand_source_role
         AND r.is_active
         AND r.is_authoritative
         AND clock_timestamp() >= r.effective_from
         AND (
             r.effective_to IS NULL
             OR clock_timestamp() < r.effective_to
         )
        JOIN metadata.devices d
          ON d.id = r.device_id
        ORDER BY
            r.effective_from DESC,
            r.created_at DESC
        LIMIT 1
    )
    SELECT
        (p.policy_id IS NOT NULL) AS policy_configured,
        COALESCE(p.is_enabled, FALSE),
        p.demand_interval_seconds,
        p.demand_basis,
        p.site_demand_source_role,
        s.device_id,
        s.device_name,
        (
            p.policy_id IS NOT NULL
            AND p.is_enabled
            AND s.device_id IS NOT NULL
        ) AS source_ready,
        CASE
            WHEN p.policy_id IS NULL
                THEN 'NOT_CONFIGURED'
            WHEN NOT p.is_enabled
                THEN 'DISABLED'
            WHEN s.device_id IS NULL
                THEN 'SOURCE_NOT_CONFIGURED'
            ELSE 'READY'
        END AS readiness_status
    FROM policy p
    LEFT JOIN source s ON TRUE

    UNION ALL

    SELECT
        FALSE,
        FALSE,
        NULL::INTEGER,
        NULL::TEXT,
        NULL::TEXT,
        NULL::UUID,
        NULL::TEXT,
        FALSE,
        'NOT_CONFIGURED'::TEXT
    WHERE NOT EXISTS (SELECT 1 FROM policy);
END;
$function$;


-- ---------------------------------------------------------------------------
-- 10. Ownership and privileges.
-- ---------------------------------------------------------------------------

ALTER TABLE config.site_demand_policies OWNER TO ems_admin;
ALTER TABLE analytics.demand_intervals OWNER TO ems_admin;
ALTER TABLE analytics.demand_state OWNER TO ems_admin;

ALTER FUNCTION config.validate_site_demand_policy()
    OWNER TO ems_admin;

ALTER FUNCTION config.resolve_site_demand_policy(UUID, TIMESTAMPTZ)
    OWNER TO ems_admin;

ALTER FUNCTION admin.get_site_demand_policy(BIGINT, UUID)
    OWNER TO ems_admin;

ALTER FUNCTION admin.set_site_demand_policy(
    BIGINT,
    UUID,
    BOOLEAN,
    INTEGER,
    TEXT,
    TEXT,
    NUMERIC,
    INTEGER,
    TEXT,
    TIMESTAMPTZ
)
    OWNER TO ems_admin;

ALTER FUNCTION admin.get_site_demand_readiness(BIGINT, UUID)
    OWNER TO ems_admin;


REVOKE ALL ON config.site_demand_policies
FROM PUBLIC, ems_app;

REVOKE ALL ON analytics.demand_intervals
FROM PUBLIC, ems_app;

REVOKE ALL ON analytics.demand_state
FROM PUBLIC, ems_app;

REVOKE ALL ON FUNCTION config.validate_site_demand_policy()
FROM PUBLIC, ems_app;

REVOKE ALL ON FUNCTION config.resolve_site_demand_policy(UUID, TIMESTAMPTZ)
FROM PUBLIC, ems_app;

REVOKE ALL ON FUNCTION admin.get_site_demand_policy(BIGINT, UUID)
FROM PUBLIC;

REVOKE ALL ON FUNCTION admin.set_site_demand_policy(
    BIGINT,
    UUID,
    BOOLEAN,
    INTEGER,
    TEXT,
    TEXT,
    NUMERIC,
    INTEGER,
    TEXT,
    TIMESTAMPTZ
)
FROM PUBLIC;

REVOKE ALL ON FUNCTION admin.get_site_demand_readiness(BIGINT, UUID)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION admin.get_site_demand_policy(BIGINT, UUID)
TO ems_app;

GRANT EXECUTE
ON FUNCTION admin.set_site_demand_policy(
    BIGINT,
    UUID,
    BOOLEAN,
    INTEGER,
    TEXT,
    TEXT,
    NUMERIC,
    INTEGER,
    TEXT,
    TIMESTAMPTZ
)
TO ems_app;

GRANT EXECUTE
ON FUNCTION admin.get_site_demand_readiness(BIGINT, UUID)
TO ems_app;


COMMENT ON FUNCTION admin.set_site_demand_policy(
    BIGINT,
    UUID,
    BOOLEAN,
    INTEGER,
    TEXT,
    TEXT,
    NUMERIC,
    INTEGER,
    TEXT,
    TIMESTAMPTZ
) IS
'Audited effective-dated site demand-policy administration contract. Does not calculate demand itself.';

COMMIT;
