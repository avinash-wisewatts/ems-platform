-- 017_asset_demand_automatic_decoupling.sql
-- Decouple automatic ASSET demand analytics from user-managed SITE demand monitoring.
--
-- SITE demand remains opt-in and configurable.
-- ASSET demand is platform-managed: PRIMARY_METER + 15-minute ACTIVE_POWER_KW.
-- No per-asset enable switch is introduced.

-- ---------------------------------------------------------------------------
-- 1. Extend the existing policy carrier with an explicit scope.
--    Keeping one policy-id namespace preserves demand_state/demand_intervals
--    referential integrity and historical auditability.
-- ---------------------------------------------------------------------------

ALTER TABLE config.site_demand_policies
    ADD COLUMN IF NOT EXISTS policy_scope TEXT NOT NULL DEFAULT 'SITE';

ALTER TABLE config.site_demand_policies
    DROP CONSTRAINT IF EXISTS site_demand_policy_scope_chk;

ALTER TABLE config.site_demand_policies
    ADD CONSTRAINT site_demand_policy_scope_chk
    CHECK (policy_scope IN ('SITE','ASSET'));

ALTER TABLE config.site_demand_policies
    ALTER COLUMN site_demand_source_role DROP NOT NULL;

ALTER TABLE config.site_demand_policies
    DROP CONSTRAINT IF EXISTS ex_site_demand_policy_no_overlap;

ALTER TABLE config.site_demand_policies
    ADD CONSTRAINT ex_site_demand_policy_no_overlap
    EXCLUDE USING gist (
        site_id WITH =,
        policy_scope WITH =,
        effective_range WITH &&
    );

CREATE INDEX IF NOT EXISTS ix_site_demand_policies_site_scope
    ON config.site_demand_policies(site_id, policy_scope, effective_from DESC);

COMMENT ON COLUMN config.site_demand_policies.policy_scope IS
'Policy scope. SITE rows are user-managed site-demand settings; ASSET rows are platform-managed defaults for automatic asset demand analytics.';

COMMENT ON TABLE config.site_demand_policies IS
'Effective-dated demand policy carrier. SITE rows are user-managed. ASSET rows are platform-managed automatic 15-minute active-power demand policies inherited by assets with a PRIMARY_METER.';

-- ---------------------------------------------------------------------------
-- 2. Scope-aware validation. ASSET policy values are system invariants.
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
    NEW.policy_scope := upper(btrim(COALESCE(NEW.policy_scope,'SITE')));
    NEW.demand_basis := upper(btrim(NEW.demand_basis));

    IF NEW.policy_scope = 'ASSET' THEN
        NEW.is_enabled := TRUE;
        NEW.demand_interval_seconds := 900;
        NEW.demand_basis := 'ACTIVE_POWER_KW';
        NEW.site_demand_source_role := NULL;
        NEW.alignment_mode := 'WALL_CLOCK';
        NEW.minimum_coverage_percent := 90.00;
        NEW.late_arrival_tolerance_seconds := 30;
    ELSE
        NEW.site_demand_source_role := upper(btrim(NEW.site_demand_source_role));

        SELECT r.is_active, r.is_demand_source_eligible
        INTO v_role_active, v_role_eligible
        FROM config.site_energy_roles AS r
        WHERE r.role_code = NEW.site_demand_source_role;

        IF NOT FOUND OR NOT v_role_active OR NOT v_role_eligible THEN
            RAISE EXCEPTION
                'Select an active site energy role that is eligible for demand monitoring.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    SELECT s.lifecycle_status INTO v_site_status
    FROM metadata.sites AS s
    WHERE s.id = NEW.site_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Site was not found.' USING ERRCODE = '23514';
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

-- ---------------------------------------------------------------------------
-- 3. SITE resolver is explicitly SITE-only. ASSET gets a separate resolver.
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
  AND p.policy_scope = 'SITE'
  AND p_at >= p.effective_from
  AND (p.effective_to IS NULL OR p_at < p.effective_to)
ORDER BY p.effective_from DESC, p.id DESC
LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION config.resolve_asset_demand_policy(
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
    TRUE,
    p.demand_interval_seconds,
    p.demand_basis,
    NULL::TEXT,
    p.alignment_mode,
    p.minimum_coverage_percent,
    p.late_arrival_tolerance_seconds,
    p.effective_from,
    p.effective_to
FROM config.site_demand_policies AS p
WHERE p.site_id = p_site_id
  AND p.policy_scope = 'ASSET'
  AND p_at >= p.effective_from
  AND (p.effective_to IS NULL OR p_at < p.effective_to)
ORDER BY p.effective_from DESC, p.id DESC
LIMIT 1;
$function$;

COMMENT ON FUNCTION config.resolve_asset_demand_policy(UUID,TIMESTAMPTZ) IS
'Resolves the platform-managed ASSET demand policy. Canonical default is automatic 15-minute ACTIVE_POWER_KW demand; source is resolved separately from the asset PRIMARY_METER.';

-- ---------------------------------------------------------------------------
-- 4. Seed one automatic ASSET policy for every existing active site.
-- ---------------------------------------------------------------------------

INSERT INTO config.site_demand_policies (
    site_id, policy_scope, is_enabled, demand_interval_seconds, demand_basis,
    site_demand_source_role, alignment_mode, minimum_coverage_percent,
    late_arrival_tolerance_seconds, effective_from, effective_to
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
WHERE COALESCE(s.lifecycle_status,'ACTIVE') <> 'DECOMMISSIONED'
  AND NOT EXISTS (
      SELECT 1
      FROM config.site_demand_policies AS p
      WHERE p.site_id=s.id
        AND p.policy_scope='ASSET'
        AND p.effective_to IS NULL
  );

-- Automatically establish the same system policy for future sites.
CREATE OR REPLACE FUNCTION config.ensure_asset_demand_policy_for_site()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, config, metadata
AS $function$
BEGIN
    IF COALESCE(NEW.lifecycle_status,'ACTIVE') <> 'DECOMMISSIONED'
       AND NOT EXISTS (
           SELECT 1 FROM config.site_demand_policies p
           WHERE p.site_id=NEW.id
             AND p.policy_scope='ASSET'
             AND p.effective_to IS NULL
       ) THEN
        INSERT INTO config.site_demand_policies (
            site_id, policy_scope, is_enabled, demand_interval_seconds,
            demand_basis, site_demand_source_role, alignment_mode,
            minimum_coverage_percent, late_arrival_tolerance_seconds,
            effective_from, effective_to
        ) VALUES (
            NEW.id, 'ASSET', TRUE, 900, 'ACTIVE_POWER_KW', NULL,
            'WALL_CLOCK', 90.00, 30,
            TIMESTAMPTZ '2000-01-01 00:00:00+00', NULL
        );
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_ensure_asset_demand_policy_for_site ON metadata.sites;
CREATE TRIGGER trg_ensure_asset_demand_policy_for_site
AFTER INSERT ON metadata.sites
FOR EACH ROW
EXECUTE FUNCTION config.ensure_asset_demand_policy_for_site();

-- ---------------------------------------------------------------------------
-- 5. Keep admin SITE writes isolated from system ASSET policy rows.
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
      AND p.policy_scope = 'SITE'
      AND p.effective_from > v_effective_from;

    -- Close whichever policy owns the requested effective timestamp.
    UPDATE config.site_demand_policies AS p
    SET
        effective_to = v_effective_from,
        updated_at = clock_timestamp()
    WHERE p.site_id = p_site_id
      AND p.policy_scope = 'SITE'
      AND p.effective_from < v_effective_from
      AND (
          p.effective_to IS NULL
          OR p.effective_to > v_effective_from
      );

    -- If a policy starts at exactly the requested timestamp, replace it.
    DELETE FROM config.site_demand_policies AS p
    WHERE p.site_id = p_site_id
      AND p.policy_scope = 'SITE'
      AND p.effective_from = v_effective_from;

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
    VALUES (
        p_site_id,
        'SITE',
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
-- 6. Capability resolution: ASSET ignores SITE demand enablement and uses
--    PRIMARY_METER + automatic asset policy.
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
site_policy AS (
    SELECT *
    FROM config.resolve_site_demand_policy(p_site_id, p_at)
),
asset_policy AS (
    SELECT *
    FROM config.resolve_asset_demand_policy(p_site_id, p_at)
),
policy AS (
    SELECT sp.* FROM site_policy AS sp
    JOIN requested AS rq ON rq.scope_type = 'SITE'
    UNION ALL
    SELECT ap.* FROM asset_policy AS ap
    JOIN requested AS rq ON rq.scope_type = 'ASSET'
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
    CASE
        WHEN rq.scope_type = 'ASSET' THEN COALESCE(r.capability_ready, FALSE)
        ELSE COALESCE(p.is_enabled, FALSE) AND COALESCE(r.capability_ready, FALSE)
    END,
    CASE
        WHEN rq.scope_type NOT IN ('SITE', 'ASSET')
            THEN 'INVALID_SCOPE'
        WHEN p.policy_id IS NULL
            THEN 'NOT_CONFIGURED'
        WHEN rq.scope_type = 'SITE' AND NOT p.is_enabled
            THEN 'DISABLED'
        WHEN rq.scope_type = 'ASSET' AND p_asset_id IS NULL
            THEN 'ASSET_NOT_SPECIFIED'
        WHEN rq.scope_type = 'ASSET' AND s.device_id IS NULL
            THEN 'NO_PRIMARY_METER'
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
'Resolves SITE demand from the user-managed site policy and ASSET demand from the platform-managed automatic asset policy. ASSET source is always PRIMARY_METER and does not depend on SITE demand enablement.';


-- ---------------------------------------------------------------------------
-- 7. Calculation and refresh processor.
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

    IF upper(btrim(p_scope_type)) = 'ASSET' THEN
        SELECT * INTO v_policy
        FROM config.resolve_asset_demand_policy(
            p_site_id,
            p_interval_start + INTERVAL '1 microsecond'
        );
    ELSE
        SELECT * INTO v_policy
        FROM config.resolve_site_demand_policy(
            p_site_id,
            p_interval_start + INTERVAL '1 microsecond'
        );
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
$function$;COMMENT ON FUNCTION analytics.calculate_demand_window(UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN) IS
'Calculates one canonical demand window. SITE scope uses the user-managed site policy; ASSET scope uses the platform-managed automatic 15-minute kW policy and PRIMARY_METER capability.';

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
    v_site_policy RECORD;
    v_asset_policy RECORD;
    v_current RECORD;
    v_n INTEGER;
    v_max_n INTEGER;
BEGIN
    IF p_lookback IS NULL OR p_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_lookback must be positive.';
    END IF;

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

        -- Remove stale asset state when a PRIMARY_METER relationship has been removed.
        DELETE FROM analytics.demand_state AS ds
        WHERE ds.site_id = v_site.site_id
          AND ds.scope_type = 'ASSET'
          AND NOT EXISTS (
              SELECT 1
              FROM metadata.asset_devices AS ad
              JOIN metadata.assets AS a ON a.id = ad.asset_id
              WHERE a.site_id = v_site.site_id
                AND ad.asset_id = ds.asset_id
                AND ad.relationship_type = 'PRIMARY_METER'
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

            SELECT 'ASSET'::TEXT,
                   ad.asset_id,
                   v_asset_policy.policy_id,
                   v_asset_policy.demand_interval_seconds,
                   v_asset_policy.effective_from,
                   v_asset_policy.effective_to,
                   v_asset_policy.late_arrival_tolerance_seconds
            FROM metadata.asset_devices AS ad
            JOIN metadata.assets AS a ON a.id = ad.asset_id
            WHERE a.site_id = v_site.site_id
              AND ad.relationship_type = 'PRIMARY_METER'
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
                extract(epoch FROM p_lookback) / v_policy.demand_interval_seconds
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

            -- Finalized historical intervals. Ten-minute processing grace remains
            -- separate from the policy late-arrival allowance.
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
'Refreshes opt-in SITE demand and automatic ASSET demand. ASSET scope is driven by PRIMARY_METER plus the platform-managed 15-minute kW policy and is independent of SITE demand enablement.';


-- ---------------------------------------------------------------------------
-- 8. Rebuild Grafana asset-demand history view against explicit ASSET policy.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_grafana_asset_demand_intervals
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    di.organization_id,
    di.site_id,
    s.name AS site_name,
    di.asset_id,
    a.name AS asset_name,
    di.demand_policy_id,
    p.demand_interval_seconds,
    p.demand_basis,
    CASE p.demand_basis
        WHEN 'ACTIVE_POWER_KW' THEN 'kW'
        WHEN 'APPARENT_POWER_KVA' THEN 'kVA'
        ELSE NULL::TEXT
    END AS demand_unit,
    di.source_device_id,
    d.name AS source_device_name,
    di.interval_start,
    di.interval_end,
    di.demand_kw,
    di.demand_kva,
    CASE p.demand_basis
        WHEN 'ACTIVE_POWER_KW' THEN di.demand_kw
        WHEN 'APPARENT_POWER_KVA' THEN di.demand_kva
        ELSE NULL::DOUBLE PRECISION
    END AS demand_value,
    di.peak_power_kw,
    di.energy_kwh,
    di.source_method,
    di.expected_observations,
    di.observed_observations,
    di.coverage_percent,
    di.quality_status,
    di.finalized_at
FROM metadata.grafana_organization_map AS gom
JOIN analytics.demand_intervals AS di
  ON di.organization_id = gom.organization_id
 AND di.scope_type = 'ASSET'
JOIN metadata.assets AS a ON a.id = di.asset_id
JOIN metadata.sites AS s ON s.id = di.site_id
JOIN config.site_demand_policies AS p
  ON p.id = di.demand_policy_id
 AND p.policy_scope = 'ASSET'
LEFT JOIN metadata.devices AS d ON d.id = di.source_device_id
WHERE gom.is_active = TRUE;

COMMENT ON VIEW analytics.v_grafana_asset_demand_intervals IS
'Grafana-safe finalized automatic ASSET demand intervals. ASSET policy is platform-managed 15-minute kW and independent of SITE demand enablement.';

ALTER VIEW analytics.v_grafana_asset_demand_intervals OWNER TO ems_admin;
REVOKE ALL ON analytics.v_grafana_asset_demand_intervals FROM PUBLIC;
GRANT SELECT ON analytics.v_grafana_asset_demand_intervals TO ems_app,ems_readonly,grafana_reader;

-- ---------------------------------------------------------------------------
-- 9. Ownership / least-privilege boundaries.
-- ---------------------------------------------------------------------------

ALTER FUNCTION config.validate_site_demand_policy() OWNER TO ems_admin;
ALTER FUNCTION config.resolve_site_demand_policy(UUID,TIMESTAMPTZ) OWNER TO ems_admin;
ALTER FUNCTION config.resolve_asset_demand_policy(UUID,TIMESTAMPTZ) OWNER TO ems_admin;
ALTER FUNCTION config.ensure_asset_demand_policy_for_site() OWNER TO ems_admin;
ALTER FUNCTION admin.set_site_demand_policy(BIGINT,UUID,BOOLEAN,INTEGER,TEXT,TEXT,NUMERIC,INTEGER,TEXT,TIMESTAMPTZ) OWNER TO ems_admin;
ALTER FUNCTION analytics.resolve_demand_capability(UUID,TEXT,UUID,TIMESTAMPTZ) OWNER TO ems_admin;
ALTER FUNCTION analytics.calculate_demand_window(UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN) OWNER TO ems_admin;
ALTER PROCEDURE analytics.refresh_demand_analytics(TIMESTAMPTZ,INTERVAL) OWNER TO ems_admin;

REVOKE ALL ON FUNCTION config.resolve_asset_demand_policy(UUID,TIMESTAMPTZ) FROM PUBLIC,ems_app;
GRANT EXECUTE ON FUNCTION config.resolve_asset_demand_policy(UUID,TIMESTAMPTZ) TO ems_readonly,grafana_reader;

REVOKE ALL ON FUNCTION analytics.resolve_demand_capability(UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,ems_app;
GRANT EXECUTE ON FUNCTION analytics.resolve_demand_capability(UUID,TEXT,UUID,TIMESTAMPTZ) TO ems_readonly,grafana_reader;

REVOKE ALL ON FUNCTION analytics.calculate_demand_window(UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.calculate_demand_window(UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN) TO ems_readonly;

-- Migration ledger entry is handled by scripts/apply_migrations.sh.
