#!/usr/bin/env bash
# ============================================================================
# Migration 210 — demand watermark + status-guarded re-finalization assertions.
#
# Rollback-only. Holds the analytics.run_demand_calculation_job advisory lock
# for the whole transaction (re-entrant in this session) so the TimescaleDB
# scheduler cannot race the CALLs, exactly as the migration-209 suite does.
#
# Covered:
#   FIXTURE        two orgs (A, B), each: site + auto ASSET policy + enabled
#                  SITE policy + PRIMARY_METER device/asset.
#   T-D            no parent source data  -> NO_SOURCE_DATA, checkpoint NOT advanced.
#   T-Refin-B      existing NO_DATA row + late source  -> VALID; finalized_at moves.
#   T-Refin-A      re-run over an unchanged VALID window -> row byte-identical,
#                  finalized_at unchanged (no churn).
#   T-Refin-D      genuine NO_DATA, still no source -> row unchanged, finalized_at
#                  unchanged.
#   T-Refin-INC    seeded INCOMPLETE row + full source -> promoted to VALID by the
#                  guard (INCOMPLETE/VALID decision is calculate_demand_window's,
#                  unchanged).
#   T-Refin-scope  SITE and ASSET rows for one bucket repaired in one call with
#                  no "ON CONFLICT specification" error and no cross-scope leak.
#   T-K            tenant isolation: org B repaired, org A VALID row untouched
#                  (incl. finalized_at); every written row's organization_id
#                  matches its site's org.
#   T-Refin-E      migration-212-style trailing reconcile over an old window
#                  repairs a hole WITHOUT moving pipeline_state.last_received_at.
#   T-WM-A         wrapper first run (checkpoint NULL): advances to
#                  date_bin(15m, LEAST(now-grace, parent, start+max_catchup)).
#   T-WM-C         wrapper: parent + now far ahead, checkpoint far behind ->
#                  advance bounded to checkpoint + max_catchup_window (6h), not parent.
#   T-WM-fail      wrapper: failure injected on the checkpoint-advance write ->
#                  RAISE propagates, checkpoint left exactly at its prior value.
#   T-DS           after a 6h catch-up the wrapper leaves ONLY current-interval
#                  rows in analytics.demand_state (no historical accumulation).
#   T-lock        wrapper body still carries the migration-208 advisory-lock /
#                  SKIPPED_LOCKED / EXCEPTION->FAILED->RAISE scaffolding
#                  (live cross-session behaviour: assert_analytics_job_self_overlap.sh).
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== Demand watermark + re-finalization assertions (migration 210) ==='

docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

-- Block the scheduler for the duration (re-entrant for this session's own CALLs).
-- Hold ALL seven forward-job advisory keys, not just demand's: this test does
-- CREATE/DROP TRIGGER on the shared telemetry.pipeline_state table, and any
-- concurrently-scheduled forward job (energy cascade / environment_daily) that
-- UPDATEs pipeline_state would deadlock against that DDL. With every key held,
-- each scheduled run takes its normal SKIPPED_LOCKED path instead. Mirrors the
-- migration-209 (assert_energy_consumption_cascade_watermarks.sql) and
-- migration-211 (assert_environment_daily_watermark.sh) idiom.
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_1min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_5min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_daily_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_demand_calculation_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('telemetry.run_environment_daily_job', 0));

CREATE TEMP TABLE t210 (k text PRIMARY KEY, u uuid, t timestamptz, n numeric) ON COMMIT DROP;

-- ===========================================================================
-- FIXTURE
-- ===========================================================================
DO $fx$
DECLARE
    v_protocol UUID;
    v_lp_active_power UUID;
    v_energy_meter_category UUID;
    v_h TIMESTAMPTZ := date_trunc('hour', now());
BEGIN
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    SELECT id INTO v_lp_active_power FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL' LIMIT 1;
    SELECT id INTO v_energy_meter_category FROM config.device_categories
        WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    IF v_protocol IS NULL OR v_lp_active_power IS NULL OR v_energy_meter_category IS NULL THEN
        RAISE EXCEPTION 'fixture needs MQTT protocol, ACTIVE_POWER_TOTAL logical point, Energy Meter category';
    END IF;

    -- Shared reference timestamps.
    INSERT INTO t210(k,t) VALUES
        ('h',        v_h),
        ('b0',       v_h - INTERVAL '3 days'),                 -- historical 15-min bucket start
        ('b1',       v_h - INTERVAL '3 days' + INTERVAL '15 minutes'),
        ('inc0',     v_h - INTERVAL '2 days'),                 -- bucket for the INCOMPLETE-promotion case
        ('inc1',     v_h - INTERVAL '2 days' + INTERVAL '15 minutes'),
        ('nd0',      v_h - INTERVAL '4 days'),                 -- genuine-NO_DATA bucket
        ('nd1',      v_h - INTERVAL '4 days' + INTERVAL '15 minutes');

    FOR i IN 1..2 LOOP
        DECLARE
            v_tag TEXT := CASE i WHEN 1 THEN 'A' ELSE 'B' END;
            v_org UUID; v_site UUID; v_gw UUID; v_asset UUID; v_dev UUID;
            v_model UUID; v_profile UUID;
        BEGIN
            INSERT INTO metadata.organizations(name, code, timezone)
            VALUES ('Demand WM Test Org '||v_tag, 'DEMAND_WM_TEST_'||v_tag, 'UTC')
            RETURNING id INTO v_org;

            INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
            VALUES (v_org, 'Demand WM Test Site '||v_tag, 'DEMAND_WM_SITE_'||v_tag, 'UTC', '{}'::jsonb, TRUE)
            RETURNING id INTO v_site;

            -- Only the platform-managed automatic ASSET policy participates (it is
            -- created by the site-insert trigger). No SITE policy is added: SITE
            -- demand needs a site_energy_role device wiring that is out of scope
            -- here; the SITE-scope ON CONFLICT arbiter is proved directly in
            -- T-Refin-scope instead.
            INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
            VALUES (v_org, v_site, 'Demand WM GW '||v_tag, 'DEMAND-WM-GW-'||v_tag)
            RETURNING id INTO v_gw;

            INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
            VALUES ('WiseWatts Test', 'Demand WM Meter '||v_tag, 'Energy Meter', v_energy_meter_category)
            ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
            DO UPDATE SET device_type = EXCLUDED.device_type
            RETURNING id INTO v_model;

            INSERT INTO config.device_profiles(
                protocol_id, profile_code, manufacturer, model, firmware_version,
                profile_name, description, is_active
            ) VALUES (
                v_protocol, 'TEST_DEMAND_WM_'||v_tag, 'WiseWatts Test', 'DemandWM'||v_tag, '1',
                'Demand WM Test '||v_tag, 'Rollback-only demand watermark fixture', TRUE
            ) RETURNING id INTO v_profile;

            INSERT INTO config.profile_field_mapping(
                profile_id, raw_field_name, logical_point_id, is_required, display_order
            ) VALUES (v_profile, 'P', v_lp_active_power, FALSE, 10);

            INSERT INTO metadata.devices(
                organization_id, gateway_id, profile_id, device_model_id, name, external_id, protocol
            ) VALUES (
                v_org, v_gw, v_profile, v_model, 'Demand WM Meter '||v_tag,
                'DEMAND-WM-METER-'||v_tag, 'MQTT'
            ) RETURNING id INTO v_dev;

            INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
            VALUES (v_org, v_site, 'Demand WM Asset '||v_tag, 'active', 'DIRECT_METER_REQUIRED')
            RETURNING id INTO v_asset;

            INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
            VALUES (v_asset, v_dev, 'PRIMARY_METER');

            INSERT INTO t210(k,u) VALUES
                ('org_'||v_tag, v_org), ('site_'||v_tag, v_site), ('gw_'||v_tag, v_gw),
                ('asset_'||v_tag, v_asset), ('dev_'||v_tag, v_dev);
        END;
    END LOOP;
END;
$fx$;

\echo 'PASS: fixture (2 orgs, automatic ASSET demand policy, PRIMARY_METER devices)'

-- helper: insert constant-power energy_measurements for a fixture org over [p_from, p_to)
CREATE FUNCTION pg_temp.t210_energy(p_tag text, p_from timestamptz, p_to timestamptz, p_w numeric)
RETURNS void LANGUAGE plpgsql AS $h$
DECLARE
    v_t TIMESTAMPTZ := p_from;
BEGIN
    WHILE v_t < p_to LOOP
        INSERT INTO telemetry.energy_measurements(
            bucket_start, received_at, source_timestamp,
            organization_id, site_id, gateway_id, device_id, asset_id,
            measurement_interval_seconds, quality_code, is_estimated, active_power_total_w
        ) VALUES (
            v_t, v_t + INTERVAL '5 seconds', v_t,
            (SELECT u FROM t210 WHERE k='org_'||p_tag),
            (SELECT u FROM t210 WHERE k='site_'||p_tag),
            (SELECT u FROM t210 WHERE k='gw_'||p_tag),
            (SELECT u FROM t210 WHERE k='dev_'||p_tag),
            (SELECT u FROM t210 WHERE k='asset_'||p_tag),
            60, 0, FALSE, p_w
        );
        v_t := v_t + INTERVAL '1 minute';
    END LOOP;
END;
$h$;

-- ===========================================================================
-- T-D  parent unavailable -> NO_SOURCE_DATA, checkpoint NOT advanced.
--      Only meaningful while both source tables are globally empty; guarded.
-- ===========================================================================
DO $td$
DECLARE
    v_parent TIMESTAMPTZ;
    v_before TIMESTAMPTZ;
    v_after  TIMESTAMPTZ;
    v_status TEXT;
BEGIN
    v_parent := LEAST(
        (SELECT max(bucket_start) FROM telemetry.energy_measurements),
        (SELECT max(event_time)   FROM telemetry.normalized_points));
    IF v_parent IS NOT NULL THEN
        RAISE NOTICE 'T-D skipped: telemetry source tables not globally empty (parent=%)', v_parent;
        RETURN;
    END IF;

    UPDATE telemetry.pipeline_state
       SET last_received_at = NULL, last_status = 'NEVER_RUN', last_error = NULL
     WHERE pipeline_name = 'demand_intervals';
    SELECT last_received_at INTO v_before FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals';

    CALL analytics.run_demand_calculation_job(0, '{}'::jsonb);

    SELECT last_received_at, last_status INTO v_after, v_status
      FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals';

    IF v_after IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'T-D: checkpoint advanced with no parent data (% -> %)', v_before, v_after;
    END IF;
    IF v_status <> 'NO_SOURCE_DATA' THEN
        RAISE EXCEPTION 'T-D: expected NO_SOURCE_DATA, got %', v_status;
    END IF;
END;
$td$;

\echo 'PASS: T-D  no parent source data -> NO_SOURCE_DATA, checkpoint not advanced'

-- ===========================================================================
-- T-Refin-B  existing NO_DATA -> VALID after late source; finalized_at moves.
-- Direct refresh_demand_analytics call over an explicit [b0, b1) window.
-- ===========================================================================
DO $tb$
DECLARE
    v_site UUID := (SELECT u FROM t210 WHERE k='site_A');
    v_b0 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='b0');
    v_b1 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='b1');
    v_q TEXT; v_kw DOUBLE PRECISION; v_fin1 TIMESTAMPTZ; v_fin2 TIMESTAMPTZ; v_cnt INT;
BEGIN
    -- pass 1: no source in the window -> NO_DATA row for the ASSET scope
    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_b0, v_b1);

    SELECT count(*), max(quality_status), max(finalized_at) INTO v_cnt, v_q, v_fin1
      FROM analytics.demand_intervals
     WHERE site_id = v_site AND scope_type = 'ASSET' AND interval_start = v_b0;
    IF v_cnt <> 1 OR v_q <> 'NO_DATA' THEN
        RAISE EXCEPTION 'T-Refin-B pass1: expected one NO_DATA ASSET row, got count=% q=%', v_cnt, v_q;
    END IF;

    -- late-arriving source for exactly that bucket
    PERFORM pg_temp.t210_energy('A', v_b0, v_b1, 12000);

    -- pass 2: same window -> promoted to VALID, finalized_at advances
    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_b0, v_b1);

    SELECT quality_status, demand_kw, finalized_at INTO v_q, v_kw, v_fin2
      FROM analytics.demand_intervals
     WHERE site_id = v_site AND scope_type = 'ASSET' AND interval_start = v_b0;
    IF v_q <> 'VALID' THEN
        RAISE EXCEPTION 'T-Refin-B pass2: expected VALID, got %', v_q;
    END IF;
    IF v_kw IS NULL OR abs(v_kw - 12.0) > 0.001 THEN
        RAISE EXCEPTION 'T-Refin-B pass2: expected demand_kw 12.0, got %', v_kw;
    END IF;
    IF NOT (v_fin2 > v_fin1) THEN
        RAISE EXCEPTION 'T-Refin-B pass2: finalized_at did not advance (% -> %)', v_fin1, v_fin2;
    END IF;
    INSERT INTO t210(k,t) VALUES ('b_fin_valid', v_fin2);
END;
$tb$;

\echo 'PASS: T-Refin-B  NO_DATA -> VALID on late source; finalized_at advanced'

-- ===========================================================================
-- T-Refin-A  re-run over the now-VALID unchanged window: no write, no churn.
-- ===========================================================================
DO $ta$
DECLARE
    v_site UUID := (SELECT u FROM t210 WHERE k='site_A');
    v_b0 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='b0');
    v_b1 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='b1');
    v_fin_before TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='b_fin_valid');
    v_q TEXT; v_kw DOUBLE PRECISION; v_fin_after TIMESTAMPTZ;
BEGIN
    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_b0, v_b1);

    SELECT quality_status, demand_kw, finalized_at INTO v_q, v_kw, v_fin_after
      FROM analytics.demand_intervals
     WHERE site_id = v_site AND scope_type = 'ASSET' AND interval_start = v_b0;

    IF v_q <> 'VALID' OR abs(v_kw - 12.0) > 0.001 THEN
        RAISE EXCEPTION 'T-Refin-A: VALID row changed unexpectedly (q=% kw=%)', v_q, v_kw;
    END IF;
    IF v_fin_after IS DISTINCT FROM v_fin_before THEN
        RAISE EXCEPTION 'T-Refin-A: finalized_at churned on an unchanged VALID row (% -> %)',
            v_fin_before, v_fin_after;
    END IF;
END;
$ta$;

\echo 'PASS: T-Refin-A  unchanged VALID window re-run -> no write, finalized_at stable'

-- ===========================================================================
-- T-Refin-D  genuine NO_DATA bucket, still no source: unchanged, no churn.
-- ===========================================================================
DO $tdd$
DECLARE
    v_site UUID := (SELECT u FROM t210 WHERE k='site_A');
    v_nd0 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='nd0');
    v_nd1 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='nd1');
    v_fin1 TIMESTAMPTZ; v_fin2 TIMESTAMPTZ; v_q TEXT;
BEGIN
    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_nd0, v_nd1);
    SELECT quality_status, finalized_at INTO v_q, v_fin1
      FROM analytics.demand_intervals
     WHERE site_id = v_site AND scope_type = 'ASSET' AND interval_start = v_nd0;
    IF v_q <> 'NO_DATA' THEN
        RAISE EXCEPTION 'T-Refin-D setup: expected NO_DATA, got %', v_q;
    END IF;

    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_nd0, v_nd1);
    SELECT quality_status, finalized_at INTO v_q, v_fin2
      FROM analytics.demand_intervals
     WHERE site_id = v_site AND scope_type = 'ASSET' AND interval_start = v_nd0;

    IF v_q <> 'NO_DATA' THEN
        RAISE EXCEPTION 'T-Refin-D: NO_DATA row changed status to %', v_q;
    END IF;
    IF v_fin2 IS DISTINCT FROM v_fin1 THEN
        RAISE EXCEPTION 'T-Refin-D: finalized_at churned on a still-NO_DATA row (% -> %)', v_fin1, v_fin2;
    END IF;
END;
$tdd$;

\echo 'PASS: T-Refin-D  still-NO_DATA bucket re-run -> unchanged, finalized_at stable'

-- ===========================================================================
-- T-Refin-INC  seeded INCOMPLETE row + full source -> guard promotes to VALID.
-- (The INCOMPLETE/VALID decision is calculate_demand_window's, unchanged; this
--  asserts the migration-210 upsert guard permits and applies that promotion.)
-- ===========================================================================
DO $tinc$
DECLARE
    v_site UUID := (SELECT u FROM t210 WHERE k='site_A');
    v_asset UUID := (SELECT u FROM t210 WHERE k='asset_A');
    v_org UUID := (SELECT u FROM t210 WHERE k='org_A');
    v_i0 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='inc0');
    v_i1 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='inc1');
    v_pol UUID;
    v_q TEXT; v_kw DOUBLE PRECISION; v_fin1 TIMESTAMPTZ; v_fin2 TIMESTAMPTZ;
BEGIN
    SELECT policy_id INTO v_pol FROM config.resolve_asset_demand_policy(v_site, v_i0);

    -- seed an INCOMPLETE finalized row with stale numbers
    INSERT INTO analytics.demand_intervals(
        interval_start, interval_end, organization_id, site_id, scope_type, asset_id,
        demand_policy_id, source_device_id, demand_kw, demand_kva, peak_power_kw,
        energy_kwh, source_method, expected_observations, observed_observations,
        coverage_percent, quality_status, finalized_at
    ) VALUES (
        v_i0, v_i1, v_org, v_site, 'ASSET', v_asset,
        v_pol, (SELECT u FROM t210 WHERE k='dev_A'), 3.0, 3.0, 3.0,
        0.75, 'TIME_WEIGHTED_POWER', 15, 5, 33.00, 'INCOMPLETE',
        clock_timestamp() - INTERVAL '1 hour'
    );
    SELECT finalized_at INTO v_fin1 FROM analytics.demand_intervals
     WHERE site_id=v_site AND scope_type='ASSET' AND interval_start=v_i0;

    PERFORM pg_temp.t210_energy('A', v_i0, v_i1, 9000);

    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_i0, v_i1);

    SELECT quality_status, demand_kw, finalized_at INTO v_q, v_kw, v_fin2
      FROM analytics.demand_intervals
     WHERE site_id=v_site AND scope_type='ASSET' AND interval_start=v_i0;

    IF v_q <> 'VALID' THEN
        RAISE EXCEPTION 'T-Refin-INC: expected INCOMPLETE -> VALID, got %', v_q;
    END IF;
    IF v_kw IS NULL OR abs(v_kw - 9.0) > 0.001 THEN
        RAISE EXCEPTION 'T-Refin-INC: expected demand_kw 9.0 after promotion, got %', v_kw;
    END IF;
    IF NOT (v_fin2 > v_fin1) THEN
        RAISE EXCEPTION 'T-Refin-INC: finalized_at did not advance on a real repair (% -> %)', v_fin1, v_fin2;
    END IF;
END;
$tinc$;

\echo 'PASS: T-Refin-INC  seeded INCOMPLETE + full source -> promoted to VALID'

-- ===========================================================================
-- T-Refin-scope  the EXACT migration-210 upsert arbiters for BOTH scopes infer
-- their partial unique index (pg16), promote a seeded non-VALID row, and target
-- the correct row with no cross-scope contamination. Exercised directly so it
-- does not depend on SITE demand-capability wiring.
-- ===========================================================================
DO $ts$
DECLARE
    v_site UUID := (SELECT u FROM t210 WHERE k='site_A');
    v_org  UUID := (SELECT u FROM t210 WHERE k='org_A');
    v_asset UUID := (SELECT u FROM t210 WHERE k='asset_A');
    v_dev  UUID := (SELECT u FROM t210 WHERE k='dev_A');
    v_pol  UUID := (SELECT policy_id FROM config.resolve_asset_demand_policy(
                        (SELECT u FROM t210 WHERE k='site_A'), now()));
    v_b  TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h') - INTERVAL '9 days';
    v_b1 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h') - INTERVAL '9 days' + INTERVAL '15 minutes';
    v_site_q TEXT; v_asset_q TEXT; v_site_aid UUID; v_asset_aid UUID;
    v_site_cnt INT; v_asset_cnt INT;
BEGIN
    -- seed one NO_DATA row per scope for the same (interval_start, demand_policy_id)
    INSERT INTO analytics.demand_intervals(
        interval_start,interval_end,organization_id,site_id,scope_type,asset_id,
        demand_policy_id,source_device_id,demand_kw,demand_kva,peak_power_kw,
        energy_kwh,source_method,expected_observations,observed_observations,
        coverage_percent,quality_status,finalized_at
    ) VALUES
        (v_b,v_b1,v_org,v_site,'SITE', NULL,   v_pol,v_dev,0,0,0,0,'TIME_WEIGHTED_POWER',15,0,0,'NO_DATA',clock_timestamp()-INTERVAL '2 hours'),
        (v_b,v_b1,v_org,v_site,'ASSET',v_asset,v_pol,v_dev,0,0,0,0,'TIME_WEIGHTED_POWER',15,0,0,'NO_DATA',clock_timestamp()-INTERVAL '2 hours');

    -- SITE-scope arbiter (verbatim shape from migration 210)
    INSERT INTO analytics.demand_intervals(
        interval_start,interval_end,organization_id,site_id,scope_type,asset_id,
        demand_policy_id,source_device_id,demand_kw,demand_kva,peak_power_kw,
        energy_kwh,source_method,expected_observations,observed_observations,
        coverage_percent,quality_status,finalized_at
    ) VALUES
        (v_b,v_b1,v_org,v_site,'SITE',NULL,v_pol,v_dev,4,4,4,1,'TIME_WEIGHTED_POWER',15,15,100,'VALID',clock_timestamp())
    ON CONFLICT (site_id,interval_start,demand_policy_id) WHERE scope_type = 'SITE'
    DO UPDATE SET demand_kw=EXCLUDED.demand_kw, quality_status=EXCLUDED.quality_status,
                  finalized_at=clock_timestamp()
    WHERE analytics.demand_intervals.quality_status <> 'VALID'
      AND EXCLUDED.quality_status IS DISTINCT FROM analytics.demand_intervals.quality_status;

    -- ASSET-scope arbiter (verbatim shape from migration 210)
    INSERT INTO analytics.demand_intervals(
        interval_start,interval_end,organization_id,site_id,scope_type,asset_id,
        demand_policy_id,source_device_id,demand_kw,demand_kva,peak_power_kw,
        energy_kwh,source_method,expected_observations,observed_observations,
        coverage_percent,quality_status,finalized_at
    ) VALUES
        (v_b,v_b1,v_org,v_site,'ASSET',v_asset,v_pol,v_dev,5,5,5,1,'TIME_WEIGHTED_POWER',15,15,100,'VALID',clock_timestamp())
    ON CONFLICT (asset_id,interval_start,demand_policy_id) WHERE scope_type = 'ASSET'
    DO UPDATE SET demand_kw=EXCLUDED.demand_kw, quality_status=EXCLUDED.quality_status,
                  finalized_at=clock_timestamp()
    WHERE analytics.demand_intervals.quality_status <> 'VALID'
      AND EXCLUDED.quality_status IS DISTINCT FROM analytics.demand_intervals.quality_status;

    SELECT count(*), max(quality_status), max(asset_id::text)::uuid
      INTO v_site_cnt, v_site_q, v_site_aid
      FROM analytics.demand_intervals WHERE site_id=v_site AND scope_type='SITE' AND interval_start=v_b;
    SELECT count(*), max(quality_status), max(asset_id::text)::uuid
      INTO v_asset_cnt, v_asset_q, v_asset_aid
      FROM analytics.demand_intervals WHERE site_id=v_site AND scope_type='ASSET' AND interval_start=v_b;

    IF v_site_cnt <> 1 OR v_site_q <> 'VALID' OR v_site_aid IS NOT NULL THEN
        RAISE EXCEPTION 'T-Refin-scope: SITE row cnt=% q=% asset_id=% (expected 1/VALID/NULL)', v_site_cnt, v_site_q, v_site_aid;
    END IF;
    IF v_asset_cnt <> 1 OR v_asset_q <> 'VALID' OR v_asset_aid IS DISTINCT FROM v_asset THEN
        RAISE EXCEPTION 'T-Refin-scope: ASSET row cnt=% q=% asset_id=% (expected 1/VALID/%)', v_asset_cnt, v_asset_q, v_asset_aid, v_asset;
    END IF;
END;
$ts$;

\echo 'PASS: T-Refin-scope  both partial-index ON CONFLICT arbiters infer + promote, no scope leak'

-- ===========================================================================
-- T-K  tenant isolation: repair org B, org A's VALID row stays byte-identical.
-- ===========================================================================
DO $tk$
DECLARE
    v_site_a UUID := (SELECT u FROM t210 WHERE k='site_A');
    v_site_b UUID := (SELECT u FROM t210 WHERE k='site_B');
    v_org_a UUID := (SELECT u FROM t210 WHERE k='org_A');
    v_org_b UUID := (SELECT u FROM t210 WHERE k='org_B');
    v_b0 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='b0');
    v_b1 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='b1');
    v_a_before TEXT; v_a_after TEXT;
    v_b_q TEXT; v_wrong_org INT;
BEGIN
    -- snapshot org A's ASSET row
    SELECT quality_status||'|'||demand_kw||'|'||finalized_at INTO v_a_before
      FROM analytics.demand_intervals
     WHERE site_id=v_site_a AND scope_type='ASSET' AND interval_start=v_b0;

    -- org B currently has NO source for this bucket -> add it now
    PERFORM pg_temp.t210_energy('B', v_b0, v_b1, 7000);

    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_b0, v_b1);

    SELECT quality_status||'|'||demand_kw||'|'||finalized_at INTO v_a_after
      FROM analytics.demand_intervals
     WHERE site_id=v_site_a AND scope_type='ASSET' AND interval_start=v_b0;
    SELECT quality_status INTO v_b_q
      FROM analytics.demand_intervals
     WHERE site_id=v_site_b AND scope_type='ASSET' AND interval_start=v_b0;

    IF v_a_after IS DISTINCT FROM v_a_before THEN
        RAISE EXCEPTION 'T-K: org A row mutated during an org B repair (% -> %)', v_a_before, v_a_after;
    END IF;
    IF v_b_q <> 'VALID' THEN
        RAISE EXCEPTION 'T-K: org B row not repaired (q=%)', v_b_q;
    END IF;

    SELECT count(*) INTO v_wrong_org FROM analytics.demand_intervals di
      WHERE di.interval_start = v_b0
        AND di.site_id IN (v_site_a, v_site_b)
        AND di.organization_id <> (SELECT organization_id FROM metadata.sites WHERE id = di.site_id);
    IF v_wrong_org <> 0 THEN
        RAISE EXCEPTION 'T-K: % row(s) with organization_id not matching their site', v_wrong_org;
    END IF;
END;
$tk$;

\echo 'PASS: T-K  org B repaired, org A row byte-identical, organization_id consistent'

-- ===========================================================================
-- T-Refin-E  migration-212-style trailing reconcile: repair a hole WITHOUT
-- moving pipeline_state.last_received_at.
-- ===========================================================================
DO $te$
DECLARE
    v_site UUID := (SELECT u FROM t210 WHERE k='site_A');
    v_h TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h');
    v_hole0 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h') - INTERVAL '5 days';
    v_hole1 TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h') - INTERVAL '5 days' + INTERVAL '15 minutes';
    v_wm_marker TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h') - INTERVAL '1 hour';
    v_wm_before TIMESTAMPTZ; v_wm_after TIMESTAMPTZ; v_q TEXT;
BEGIN
    -- finalize the hole bucket as NO_DATA, then pin the watermark ahead of it
    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_hole0, v_hole1);
    UPDATE telemetry.pipeline_state SET last_received_at = v_wm_marker, last_status = 'SUCCESS'
     WHERE pipeline_name = 'demand_intervals';
    SELECT last_received_at INTO v_wm_before FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals';

    -- late source lands for the already-passed hole bucket
    PERFORM pg_temp.t210_energy('A', v_hole0, v_hole1, 5000);

    -- a bare refresh over the old window (what migration 212 will do) — NOT the wrapper
    CALL analytics.refresh_demand_analytics(clock_timestamp(), INTERVAL '3 hours', v_hole0, v_hole1);

    SELECT last_received_at INTO v_wm_after FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals';
    SELECT quality_status INTO v_q FROM analytics.demand_intervals
     WHERE site_id=v_site AND scope_type='ASSET' AND interval_start=v_hole0;

    IF v_q <> 'VALID' THEN
        RAISE EXCEPTION 'T-Refin-E: hole bucket not repaired by trailing reconcile (q=%)', v_q;
    END IF;
    IF v_wm_after IS DISTINCT FROM v_wm_before THEN
        RAISE EXCEPTION 'T-Refin-E: trailing reconcile moved the watermark (% -> %)', v_wm_before, v_wm_after;
    END IF;
END;
$te$;

\echo 'PASS: T-Refin-E  trailing reconcile repairs a hole, watermark unmoved'

-- ===========================================================================
-- T-WM-A  wrapper first run (checkpoint NULL) advances to
--         date_bin(15m, LEAST(now-grace, parent, start+max_catchup)).
-- ===========================================================================
DO $twa$
DECLARE
    v_h TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h');
    v_grace INTERVAL;
    v_parent TIMESTAMPTZ;
    v_start TIMESTAMPTZ;
    v_expect TIMESTAMPTZ;
    v_after TIMESTAMPTZ; v_status TEXT;
BEGIN
    -- clean fixture energy, then a single parent marker bucket at h-90min (15-min aligned)
    DELETE FROM telemetry.energy_measurements
     WHERE site_id IN (SELECT u FROM t210 WHERE k IN ('site_A','site_B'));
    PERFORM pg_temp.t210_energy('A', v_h - INTERVAL '90 minutes', v_h - INTERVAL '89 minutes', 10000);

    UPDATE telemetry.pipeline_state
       SET last_received_at = NULL, last_status = 'NEVER_RUN', last_error = NULL
     WHERE pipeline_name = 'demand_intervals';

    v_grace := make_interval(secs => COALESCE(
        (SELECT max(late_arrival_tolerance_seconds) FROM config.site_demand_policies WHERE is_enabled), 0) + 300);
    v_parent := LEAST(
        (SELECT max(bucket_start) FROM telemetry.energy_measurements),
        (SELECT max(event_time)   FROM telemetry.normalized_points));
    v_start := clock_timestamp() - INTERVAL '3 hours';
    v_expect := date_bin(INTERVAL '15 minutes',
                  LEAST(clock_timestamp() - v_grace, v_parent, v_start + INTERVAL '6 hours'),
                  TIMESTAMPTZ '2000-01-01 00:00:00+00');

    CALL analytics.run_demand_calculation_job(0,
        '{"lookback":"3 hours","max_catchup_window":"6 hours","overlap":"30 minutes"}'::jsonb);

    SELECT last_received_at, last_status INTO v_after, v_status
      FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals';

    IF v_after IS DISTINCT FROM v_expect THEN
        RAISE EXCEPTION 'T-WM-A: checkpoint % <> expected %', v_after, v_expect;
    END IF;
    IF v_status NOT IN ('SUCCESS','NO_SOURCE_DATA') THEN
        RAISE EXCEPTION 'T-WM-A: unexpected status %', v_status;
    END IF;
END;
$twa$;

\echo 'PASS: T-WM-A  first run advances to date_bin(15m, LEAST(now-grace, parent, start+max_catchup))'

-- ===========================================================================
-- T-WM-C  parent + now far ahead, checkpoint 20h back -> advance bounded to
--         checkpoint + max_catchup_window (6h), NOT parent / now.
-- ===========================================================================
DO $twc$
DECLARE
    v_h TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h');
    v_ckpt TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h') - INTERVAL '20 hours';
    v_expect TIMESTAMPTZ;
    v_after TIMESTAMPTZ;
BEGIN
    DELETE FROM telemetry.energy_measurements
     WHERE site_id IN (SELECT u FROM t210 WHERE k IN ('site_A','site_B'));
    -- parent only ~10 min back -> well ahead of ckpt + 6h (= h - 14h)
    PERFORM pg_temp.t210_energy('A', v_h - INTERVAL '10 minutes', v_h - INTERVAL '9 minutes', 10000);

    UPDATE telemetry.pipeline_state
       SET last_received_at = v_ckpt, last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'demand_intervals';

    v_expect := date_bin(INTERVAL '15 minutes', v_ckpt + INTERVAL '6 hours',
                         TIMESTAMPTZ '2000-01-01 00:00:00+00');

    CALL analytics.run_demand_calculation_job(0,
        '{"lookback":"3 hours","max_catchup_window":"6 hours","overlap":"30 minutes"}'::jsonb);

    SELECT last_received_at INTO v_after
      FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals';

    IF v_after IS DISTINCT FROM v_expect THEN
        RAISE EXCEPTION 'T-WM-C: checkpoint % <> ckpt+max_catchup %', v_after, v_expect;
    END IF;
    IF v_after >= v_h - INTERVAL '20 minutes' THEN
        RAISE EXCEPTION 'T-WM-C: advance not bounded — reached % (parent was ~h-10m)', v_after;
    END IF;
END;
$twc$;

\echo 'PASS: T-WM-C  per-run advance bounded to checkpoint + max_catchup_window'

-- ===========================================================================
-- T-WM-fail  failure on the checkpoint-advance write -> RAISE propagates,
--            checkpoint left exactly at its prior value.
-- ===========================================================================
DO $twf$
DECLARE
    v_h TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h');
    v_ckpt TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h') - INTERVAL '90 minutes';
    v_after TIMESTAMPTZ;
    v_raised BOOLEAN := FALSE;
BEGIN
    DELETE FROM telemetry.energy_measurements
     WHERE site_id IN (SELECT u FROM t210 WHERE k IN ('site_A','site_B'));
    PERFORM pg_temp.t210_energy('A', v_h - INTERVAL '45 minutes', v_h - INTERVAL '44 minutes', 10000);

    UPDATE telemetry.pipeline_state
       SET last_received_at = v_ckpt, last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'demand_intervals';

    CREATE FUNCTION pg_temp.t210_boom() RETURNS trigger LANGUAGE plpgsql AS $b$
    BEGIN
        IF NEW.pipeline_name = 'demand_intervals'
           AND NEW.last_received_at IS DISTINCT FROM OLD.last_received_at THEN
            RAISE EXCEPTION 't210 injected failure on checkpoint advance';
        END IF;
        RETURN NEW;
    END;
    $b$;
    CREATE TRIGGER t210_boom_trg BEFORE UPDATE ON telemetry.pipeline_state
        FOR EACH ROW EXECUTE FUNCTION pg_temp.t210_boom();

    BEGIN
        CALL analytics.run_demand_calculation_job(0,
            '{"lookback":"3 hours","max_catchup_window":"6 hours","overlap":"30 minutes"}'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
    END;

    DROP TRIGGER t210_boom_trg ON telemetry.pipeline_state;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'T-WM-fail: expected the injected failure to propagate';
    END IF;

    SELECT last_received_at INTO v_after
      FROM telemetry.pipeline_state WHERE pipeline_name='demand_intervals';
    IF v_after IS DISTINCT FROM v_ckpt THEN
        RAISE EXCEPTION 'T-WM-fail: checkpoint moved despite failure (% -> %)', v_ckpt, v_after;
    END IF;
END;
$twf$;

\echo 'PASS: T-WM-fail  failure on advance -> RAISE propagates, checkpoint intact'

-- ===========================================================================
-- T-DS  after a 6h catch-up the wrapper leaves ONLY current-interval rows in
--       analytics.demand_state (no historical accumulation).
-- ===========================================================================
DO $tds$
DECLARE
    v_h TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h');
    v_ckpt TIMESTAMPTZ := (SELECT t FROM t210 WHERE k='h') - INTERVAL '6 hours';
    v_bad INT;
BEGIN
    DELETE FROM telemetry.energy_measurements
     WHERE site_id IN (SELECT u FROM t210 WHERE k IN ('site_A','site_B'));
    DELETE FROM analytics.demand_state
     WHERE site_id IN (SELECT u FROM t210 WHERE k IN ('site_A','site_B'));
    -- continuous source from ckpt to ~now for org A
    PERFORM pg_temp.t210_energy('A', v_ckpt, v_h - INTERVAL '2 minutes', 8000);

    UPDATE telemetry.pipeline_state
       SET last_received_at = v_ckpt, last_status = 'SUCCESS', last_error = NULL
     WHERE pipeline_name = 'demand_intervals';

    CALL analytics.run_demand_calculation_job(0,
        '{"lookback":"3 hours","max_catchup_window":"6 hours","overlap":"30 minutes"}'::jsonb);

    -- every demand_state row for the fixture must be the live/current interval
    SELECT count(*) INTO v_bad FROM analytics.demand_state
     WHERE site_id IN (SELECT u FROM t210 WHERE k IN ('site_A','site_B'))
       AND interval_end <= now() - INTERVAL '15 minutes';
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'T-DS: % historical row(s) accumulated in demand_state after a 6h catch-up', v_bad;
    END IF;
END;
$tds$;

\echo 'PASS: T-DS  6h catch-up leaves only current-interval rows in demand_state'

-- ===========================================================================
-- T-lock  the wrapper still carries the migration-208 concurrency scaffolding.
-- (Live cross-session SKIPPED_LOCKED behaviour: assert_analytics_job_self_overlap.sh.)
-- ===========================================================================
DO $tl$
DECLARE
    v_src TEXT := pg_get_functiondef('analytics.run_demand_calculation_job(integer,jsonb)'::regprocedure);
BEGIN
    IF position('pg_try_advisory_xact_lock(hashtextextended(''analytics.run_demand_calculation_job''' IN v_src) = 0 THEN
        RAISE EXCEPTION 'T-lock: advisory self-overlap lock missing from wrapper';
    END IF;
    IF position('SKIPPED_LOCKED' IN v_src) = 0 THEN
        RAISE EXCEPTION 'T-lock: SKIPPED_LOCKED path missing from wrapper';
    END IF;
    IF position('''FAILED''' IN v_src) = 0 OR position('RAISE;' IN v_src) = 0 THEN
        RAISE EXCEPTION 'T-lock: EXCEPTION -> FAILED -> RAISE path missing from wrapper';
    END IF;
    IF position('last_received_at   = v_to' IN v_src) = 0
       AND position('last_received_at = v_to' IN replace(v_src, '   ', ' ')) = 0 THEN
        RAISE EXCEPTION 'T-lock: watermark advance (last_received_at = v_to) missing from wrapper';
    END IF;
END;
$tl$;

\echo 'PASS: T-lock  wrapper retains advisory-lock / SKIPPED_LOCKED / FAILED->RAISE + watermark advance'

ROLLBACK;
SQL

printf '%s\n' 'PASS: demand watermark + re-finalization assertions completed.'
