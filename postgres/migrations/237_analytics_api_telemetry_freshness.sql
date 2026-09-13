-- ============================================================================
-- Migration 237
-- MVP-4 (Data Quality & Freshness) -- read-only, portal-user-scoped device
-- telemetry freshness for the /api/v1 Analytics API.
--
-- Source of record:
--   docs/00-governance/decision-packs/mvp-4-data-quality-and-freshness-decision-pack.md
--   Section 5 (freshness is a signal separate from the measurement-quality
--   lattice and from Demand's calculation-status vocabulary; informational
--   only -- never feeds Site Health or Energy Attention) and Section 5a
--   (metric-specific dependency: Power Quality and Energy resolve the same
--   SITE_CONSUMPTION meter; Demand resolves the currently-effective
--   SITE-scope policy's device; no blended site-wide verdict).
--
-- Verified source data (this session, direct DDL/migration read -- not
-- assumed):
--   telemetry.device_telemetry_state (migration 003/122) -- one row per
--   device_id, already populated by the existing ingestion/normalization
--   pipeline. No write path in this migration.
--
--   config.telemetry_availability_policy (migration 098) -- the existing
--   DEFAULT policy_key row (receiving/stale/silent thresholds) already used
--   by analytics.get_grafana_asset_telemetry_context (migration 138) and by
--   Admin Portal's device administration workspace
--   (analytics.v_device_telemetry_availability, migration 098/108/109).
--   Reused verbatim -- no new threshold introduced.
--
--   config.site_energy_meter_roles (migration 085/100) -- SITE_CONSUMPTION
--   is is_exclusive_per_site = TRUE ("the authoritative directly measured
--   total site consumption"). analytics.get_portal_site_power_quality_series
--   (migration 234) already resolves PQ's device through this exact JOIN;
--   this migration reuses the identical resolution for Energy (an approved
--   approximation, decision pack Sec 5a) and reuses it again for Demand's
--   SITE-scope source-role device.
--
--   config.resolve_site_demand_policy (migration 136) -- already resolves
--   the currently-effective SITE-scope config.site_demand_policies row for
--   a site (policy_scope = 'SITE', effective-date-windowed). Verified this
--   session: analytics.get_portal_site_demand_series /
--   get_portal_site_current_demand (migration 233) filter
--   scope_type = 'SITE' exclusively -- the customer-facing site Demand
--   figure is NEVER derived from an ASSET-scope policy. There is therefore
--   no live "ASSET scope" case for this migration to resolve: it uses
--   config.resolve_site_demand_policy (SITE-scope only) and nothing else.
--   A site whose only configured policy is ASSET-scope, or which has no
--   SITE-scope policy at all, correctly yields UNKNOWN here -- consistent
--   with that site having no SITE-scope Demand figure to be fresh or stale
--   about in the first place (get_portal_site_current_demand already
--   returns has_data = false for it).
--
-- What this migration does (ADDITIVE ONLY):
--   One new function in schema analytics:
--
--   analytics.get_portal_site_telemetry_freshness(bigint, uuid,
--     timestamptz DEFAULT clock_timestamp()) RETURNS TABLE(site_id,
--     energy_state, energy_as_of, demand_state, demand_as_of,
--     power_quality_state, power_quality_as_of)
--
--     * SECURITY DEFINER, STABLE, pinned SET search_path, no dynamic SQL,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope re-derived server-side via the established
--       admin.portal_user_can_access_site(bigint, uuid) function -- a
--       caller that cannot see the site gets ZERO ROWS, never an error,
--     * *_state is one of the four API-semantic values FRESH / STALE /
--       NO_DATA / UNKNOWN -- never the internal six-value
--       NEVER_SEEN/SILENT/RECEIVING/STALE/VALIDATED vocabulary, and never a
--       device_id, gateway_id, logical_point_id, or any other raw
--       identifier. The internal-to-API collapse is:
--         VALIDATED           -> FRESH
--         STALE               -> STALE
--         RECEIVING           -> STALE
--         SILENT              -> NO_DATA
--         NEVER_SEEN          -> NO_DATA
--         (no device resolved) -> UNKNOWN
--     * *_as_of is the resolved device's latest_received_timestamp (NULL
--       when no device was resolved) -- gives the caller a timestamp
--       without exposing which device it came from.
--
-- What this migration does NOT do:
--   * Does NOT modify, and does not reference for write, telemetry.device_
--     telemetry_state, config.site_energy_meter_roles,
--     config.site_demand_policies, or config.telemetry_availability_policy.
--     Read-only.
--   * Does NOT reference analytics.demand_intervals, analytics.demand_state,
--     or analytics.resolve_demand_capability -- Demand's own calculation-
--     status vocabulary (VALID/PROVISIONAL/INCOMPLETE/NO_DATA/
--     INVALID_SOURCE/INSUFFICIENT_SOURCE_RESOLUTION) is untouched and
--     unrelated to this function (postcondition-checked below).
--   * Does NOT touch web/src/components/QualityIndicator.tsx's lattice
--     (GOOD/GAP/ESTIMATED/INVALID/PARTIAL) -- this is a backend-only
--     migration; no frontend change in this tranche.
--   * Does NOT compute or return any blended/site-wide freshness verdict --
--     three independent per-domain fields only.
--   * Does NOT alter config.telemetry_availability_policy's threshold
--     values -- reused exactly as configured.
--   * No new table, hypertable, TimescaleDB job, trigger, or grant to
--     PUBLIC/grafana_reader. No write statement in the function body.
--
-- Transaction: NO BEGIN/COMMIT of its own -- scripts/apply_migrations.sh
--   wraps the file + the ledger INSERT in one transaction (matches
--   223-236).
--
-- Rollback: postgres/maintenance/237_analytics_api_telemetry_freshness_rollback.sql
--   -- dependency-checked, no CASCADE, safe if never applied.
--
-- NOT APPLIED as part of this implementation increment -- source-code /
-- migration-file change only. No remote or local database write occurs
-- from authoring this file. No deployment performed.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 237 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing (three-role scope model).';
    END IF;

    IF to_regclass('telemetry.device_telemetry_state') IS NULL THEN
        RAISE EXCEPTION 'Migration 237 precondition failed: telemetry.device_telemetry_state is missing (migration 003/122).';
    END IF;

    IF to_regclass('config.telemetry_availability_policy') IS NULL THEN
        RAISE EXCEPTION 'Migration 237 precondition failed: config.telemetry_availability_policy is missing (migration 098).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM config.telemetry_availability_policy WHERE policy_key = 'DEFAULT'
    ) THEN
        RAISE EXCEPTION 'Migration 237 precondition failed: config.telemetry_availability_policy has no DEFAULT policy_key row.';
    END IF;

    IF to_regclass('config.site_energy_meter_roles') IS NULL THEN
        RAISE EXCEPTION 'Migration 237 precondition failed: config.site_energy_meter_roles is missing (migration 085).';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM config.site_energy_roles WHERE role_code = 'SITE_CONSUMPTION') THEN
        RAISE EXCEPTION 'Migration 237 precondition failed: config.site_energy_roles has no SITE_CONSUMPTION row (migration 100).';
    END IF;

    IF to_regprocedure('config.resolve_site_demand_policy(uuid, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 237 precondition failed: config.resolve_site_demand_policy(uuid, timestamptz) is missing (migration 136).';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_site_telemetry_freshness(bigint, uuid, timestamptz)
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

    SELECT p.receiving_threshold_seconds, p.stale_threshold_seconds, p.silent_threshold_seconds
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
-- Postconditions -- ownership/grant hygiene, read-only-body proof, and the
-- mandatory architectural guards: freshness must not merge with Demand's
-- calculation-status vocabulary, and must resolve independently of it.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig           TEXT := 'analytics.get_portal_site_telemetry_freshness(bigint, uuid, timestamptz)';
    v_body          TEXT;
    v_function_body TEXT;
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
        RAISE EXCEPTION 'Migration 237 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 237 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 237 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0
       OR position('execute ' IN v_body) > 0
       OR position('format(' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 237 postcondition failed: the freshness function contains a write statement or dynamic SQL.';
    END IF;

    -- Isolate the executable body from the RETURNS TABLE column list before
    -- searching for a prohibited reference. This function's own output
    -- columns are legitimately named demand_state/demand_as_of (see
    -- SiteTelemetryFreshnessResponse in app/src/analytics_api_service.py),
    -- and pg_get_functiondef() includes that column list ahead of the body
    -- in its reconstructed text -- a plain substring search over the whole
    -- definition would false-positive on the function's own signature, not
    -- a real reference to a prohibited object. PostgreSQL reconstructs this
    -- function's body wrapped in a literal "$function$" dollar-quote tag
    -- (verified against this migration's own sibling functions); everything
    -- from just after that opening tag onward is the actual body, where a
    -- genuine reference would have to appear.
    v_function_body := substring(v_body FROM position('$function$' IN v_body) + length('$function$'));

    IF position('demand_intervals' IN v_function_body) > 0
       OR position('demand_state' IN v_function_body) > 0
       OR position('resolve_demand_capability' IN v_function_body) > 0 THEN
        RAISE EXCEPTION 'Migration 237 postcondition failed: the freshness function references Demand''s calculation-status path, which is prohibited -- freshness must remain independent of quality_status/coverage_percent.';
    END IF;

    IF position('device_telemetry_state' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 237 postcondition failed: the freshness function does not reference telemetry.device_telemetry_state -- the required source table is missing from the body.';
    END IF;

    IF position('site_energy_meter_roles' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 237 postcondition failed: the freshness function does not reference config.site_energy_meter_roles -- the required device-resolution JOIN is missing.';
    END IF;

    IF position('resolve_site_demand_policy' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 237 postcondition failed: the freshness function does not reference config.resolve_site_demand_policy -- the required SITE-scope Demand resolution is missing.';
    END IF;

    RAISE NOTICE 'Migration 237: all postconditions passed (portal telemetry freshness read function created; read-only; independent of Demand calculation-status path; device_telemetry_state confirmed as the sole freshness source).';
END;
$post$;
