#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== Portal-scoped Asset Demand read assertions (migration 245) ==='

# This exercises analytics.get_portal_asset_demand_series /
# analytics.get_portal_asset_current_demand directly -- not the calculation
# pipeline that populates analytics.demand_intervals/demand_state (that is
# already proven by assert_asset_demand_automatic_decoupling.sh). Rows are
# inserted directly here so this test is a precise, deterministic check of
# the READ path's own filtering/authorization/window logic, independent of
# telemetry/job timing.
docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

DO $test$
DECLARE
    v_org_a UUID;
    v_org_b UUID;
    v_site_a UUID;
    v_asset_metered UUID;
    v_asset_unmetered UUID;
    v_policy UUID;
    v_user_a BIGINT;
    v_user_b BIGINT;
    v_row RECORD;
    v_count INTEGER;
BEGIN
    -- ------------------------------------------------------------------
    -- Fixture: two tenants (org A has the metered/unmetered assets under
    -- test; org B exists only to prove cross-tenant denial), one portal
    -- user per tenant.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Asset Demand Portal Read Test Org A', 'ASSET_DEMAND_READ_TEST_ORG_A', 'UTC')
    RETURNING id INTO v_org_a;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Asset Demand Portal Read Test Org B', 'ASSET_DEMAND_READ_TEST_ORG_B', 'UTC')
    RETURNING id INTO v_org_b;

    INSERT INTO metadata.sites(
        organization_id, name, code, timezone, address, is_active
    ) VALUES (
        v_org_a, 'Asset Demand Portal Read Test Site', 'ASSET_DEMAND_READ_TEST_SITE',
        'UTC', '{}'::jsonb, TRUE
    ) RETURNING id INTO v_site_a;

    -- Migration 136's trigger auto-creates the platform-managed ASSET
    -- demand policy for every new site -- reuse it, do not invent one.
    SELECT p.id INTO v_policy
    FROM config.site_demand_policies AS p
    WHERE p.site_id = v_site_a
      AND p.policy_scope = 'ASSET'
      AND p.effective_to IS NULL
    ORDER BY p.effective_from DESC
    LIMIT 1;

    IF v_policy IS NULL THEN
        RAISE EXCEPTION 'Expected the automatic ASSET demand policy to already exist for a new site (migration 136).';
    END IF;

    INSERT INTO metadata.assets(
        organization_id, site_id, name, status, metering_requirement
    ) VALUES (
        v_org_a, v_site_a, 'Asset Demand Portal Read -- Metered Asset', 'active', 'DIRECT_METER_REQUIRED'
    ) RETURNING id INTO v_asset_metered;

    -- No PRIMARY_METER device, no demand rows ever inserted for it -- the
    -- realistic shape of "never processed by the demand job" (migration
    -- 132 only loops assets with a PRIMARY_METER relationship).
    INSERT INTO metadata.assets(
        organization_id, site_id, name, status, metering_requirement
    ) VALUES (
        v_org_a, v_site_a, 'Asset Demand Portal Read -- Unmetered Asset', 'active', 'NOT_REQUIRED'
    ) RETURNING id INTO v_asset_unmetered;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'asset-demand-read-test-user-a', 'Asset Demand Read Test User A',
        'not-a-real-hash', 'VIEWER', TRUE, 'ORGANIZATION', v_org_a, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_a;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'asset-demand-read-test-user-b', 'Asset Demand Read Test User B',
        'not-a-real-hash', 'VIEWER', TRUE, 'ORGANIZATION', v_org_b, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_b;

    -- ------------------------------------------------------------------
    -- One finalized (VALID) interval and one current (PROVISIONAL) state
    -- row for the metered asset, inserted directly -- known values.
    -- ------------------------------------------------------------------
    INSERT INTO analytics.demand_intervals(
        interval_start, interval_end, organization_id, site_id, scope_type,
        asset_id, demand_policy_id, demand_kw, demand_kva, peak_power_kw,
        source_method, coverage_percent, quality_status
    ) VALUES (
        TIMESTAMPTZ '2026-08-10 11:30:00+00', TIMESTAMPTZ '2026-08-10 11:45:00+00',
        v_org_a, v_site_a, 'ASSET', v_asset_metered, v_policy,
        12.0, 12.6, 15.5, 'METER_NATIVE', 98.5, 'VALID'
    );

    INSERT INTO analytics.demand_state(
        site_id, scope_type, asset_id, demand_policy_id,
        interval_start, interval_end, current_demand_kw, current_demand_kva,
        coverage_percent, quality_status
    ) VALUES (
        v_site_a, 'ASSET', v_asset_metered, v_policy,
        TIMESTAMPTZ '2026-08-10 12:00:00+00', TIMESTAMPTZ '2026-08-10 12:15:00+00',
        13.5, 14.0, 80.0, 'PROVISIONAL'
    );

    -- ------------------------------------------------------------------
    -- 1. Correct returned values for the authorized user.
    -- ------------------------------------------------------------------
    SELECT * INTO v_row
    FROM analytics.get_portal_asset_demand_series(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );

    IF v_row.demand_kw IS DISTINCT FROM 12.0
       OR v_row.peak_power_kw IS DISTINCT FROM 15.5
       OR v_row.quality_status IS DISTINCT FROM 'VALID'
       OR v_row.coverage_percent IS DISTINCT FROM 98.5 THEN
        RAISE EXCEPTION 'get_portal_asset_demand_series returned unexpected values: demand_kw=%, peak_power_kw=%, quality_status=%, coverage_percent=%',
            v_row.demand_kw, v_row.peak_power_kw, v_row.quality_status, v_row.coverage_percent;
    END IF;

    SELECT * INTO v_row
    FROM analytics.get_portal_asset_current_demand(v_user_a, v_asset_metered);

    IF v_row.current_demand_kw IS DISTINCT FROM 13.5
       OR v_row.current_demand_kva IS DISTINCT FROM 14.0
       OR v_row.quality_status IS DISTINCT FROM 'PROVISIONAL' THEN
        RAISE EXCEPTION 'get_portal_asset_current_demand returned unexpected values: current_demand_kw=%, current_demand_kva=%, quality_status=%',
            v_row.current_demand_kw, v_row.current_demand_kva, v_row.quality_status;
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Cross-tenant denial -- a portal user in a different organization
    --    gets zero rows, never an error and never another tenant's data.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_demand_series(
        v_user_b, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Cross-tenant caller unexpectedly saw % asset demand series row(s)', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_current_demand(v_user_b, v_asset_metered);
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Cross-tenant caller unexpectedly saw % asset current-demand row(s)', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- 3. No-data asset -- an authorized caller querying an asset that was
    --    never processed by the demand job (no PRIMARY_METER device) gets
    --    zero rows, not an error.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_demand_series(
        v_user_a, v_asset_unmetered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Unmetered asset unexpectedly returned % demand series row(s)', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_current_demand(v_user_a, v_asset_unmetered);
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Unmetered asset unexpectedly returned % current-demand row(s)', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- 4. Range/window boundary behavior -- [p_from, p_to) on interval_start.
    -- ------------------------------------------------------------------
    -- p_from at the interval's own end (11:45): interval_start (11:30) is
    -- before p_from, so it must be excluded.
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_demand_series(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 11:45:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected 0 rows when p_from excludes the interval (got %)', v_count;
    END IF;

    -- p_to exactly at the interval's own start (11:30): interval_start is
    -- NOT strictly less than p_to, so it must be excluded.
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_demand_series(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-10 11:30:00+00'
    );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected 0 rows when p_to equals interval_start (half-open window, got %)', v_count;
    END IF;

    -- p_to one second past the interval's own start: now included.
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_demand_series(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-10 11:30:01+00'
    );
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected exactly 1 row when p_to is past interval_start (got %)', v_count;
    END IF;
END;
$test$;

\echo 'PASS: authorized caller sees correct asset demand series and current-demand values'
\echo 'PASS: a caller in a different organization is denied (zero rows, no error)'
\echo 'PASS: an asset never processed by the demand job (no PRIMARY_METER) returns zero rows, not an error'
\echo 'PASS: [p_from, p_to) window boundaries on interval_start are enforced correctly'

ROLLBACK;
SQL

printf '%s\n' 'PASS: portal-scoped asset demand read assertions completed.'
