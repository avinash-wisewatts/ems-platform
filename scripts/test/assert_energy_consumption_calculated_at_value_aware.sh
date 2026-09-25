#!/usr/bin/env bash
# ============================================================================
# Migration 216 -- value-aware calculated_at for the energy_consumption cascade.
#
# Rollback-only. One BEGIN/ROLLBACK transaction. The seven FORWARD-job advisory
# keys are held for the whole transaction (re-entrant for this session) so the
# TimescaleDB scheduler cannot race the fixtures (same guard as
# assert_analytical_reconciliation.sh).
#
# Coverage
#   Part 1  STRUCTURAL (all 5 refresh functions): the ON CONFLICT DO UPDATE
#           assignment of calculated_at is the value-aware CASE; the CASE's
#           ROW(...) lists EVERY non-PK/non-calculated_at column of the tier
#           table on BOTH sides (completeness -> catches future column drift);
#           every such column is still assigned = EXCLUDED.<col> (value write
#           preserved -> GET DIAGNOSTICS ROW_COUNT / RETURN value unchanged ->
#           migration-208/209 wrapper NO_SOURCE_DATA-vs-SUCCESS contract intact);
#           the old unconditional "calculated_at = EXCLUDED.calculated_at" is
#           gone from every body.
#   Part 2  BEHAVIOURAL A-I (15min / hourly / daily -- the tiers the rollback-
#           only harness can drive; 1min/5min read TimescaleDB CAggs that cannot
#           be refreshed inside a transaction, the same boundary the repo's
#           assert_energy_consumption_semantic_contract / _cascade_watermarks
#           tests already draw).  A seed+refresh; B refresh again, unchanged
#           source; C calculated_at NOT advanced; D values identical; E change
#           the authoritative source; F refresh; G value changes; H calculated_at
#           advances; I the migration-213 downstream reconcile detects the
#           genuine change (and does NOT flag the no-op).
#   Part 3  1min/5min DO-UPDATE CASE mechanism, behavioural, on a throwaway
#           probe table using the exact SQL construct migration 216 applies:
#           NULL-safe (IS DISTINCT FROM), numeric-scale-safe, and -- critically --
#           a matched no-op row is STILL counted by ROW_COUNT (return-value
#           contract preserved).
#   Part 4  CASCADE FIXED POINT (Step 8):  1min -> 15min -> hourly -> daily.
#           A no-op upstream refresh advances NOTHING downstream and manufactures
#           NO reconciliation work on the next run; a genuine upstream change
#           propagates its calculated_at advance and IS detected.
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"

printf '%s\n' '=== energy_consumption calculated_at value-aware assertions (migration 216) ==='

psql_f() {
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb-test \
        psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test -f -
}

psql_f <<'SQL'
BEGIN;

-- Block the scheduler for the duration (re-entrant for this session's CALLs).
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_1min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_5min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
SELECT pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_daily_job', 0));

-- ======================================================================
-- PART 1 -- STRUCTURAL: the value-aware CASE, complete + value-write-safe.
-- ======================================================================
DO $t$
DECLARE
    v_tier   text;
    v_tbl    text;
    v_def    text;
    v_col    text;
    v_fail   text[] := ARRAY[]::text[];
BEGIN
    FOREACH v_tier IN ARRAY ARRAY['1min','5min','15min','hourly','daily'] LOOP
        v_tbl := 'energy_consumption_' || v_tier;
        v_def := pg_get_functiondef(('analytics.refresh_'||v_tbl||'(timestamptz,timestamptz)')::regprocedure);

        -- old unconditional bump must be gone
        IF v_def ~ 'calculated_at\s*=\s*EXCLUDED\.calculated_at' THEN
            v_fail := v_fail || (v_tbl || ': still has unconditional calculated_at = EXCLUDED.calculated_at');
        END IF;
        -- value-aware CASE must be present
        IF position('IS DISTINCT FROM ROW(' IN v_def) = 0
           OR position('THEN EXCLUDED.calculated_at' IN v_def) = 0
           OR position('ELSE '||v_tbl||'.calculated_at' IN v_def) = 0 THEN
            v_fail := v_fail || (v_tbl || ': value-aware calculated_at CASE not found');
        END IF;

        -- completeness + value-write: EVERY non-PK / non-calculated_at column of
        -- the tier table must appear as  <tbl>.<col>  AND  EXCLUDED.<col>
        -- (comparison, both sides) AND  <col> =  EXCLUDED.<col>  (value write).
        --
        -- Migration 268 (ADR-020 PR1) staged exception: the late/recovered
        -- Energy reconstruction columns on the 1min/5min tiers are added
        -- inert and are deliberately NOT written by the refresh functions
        -- until the ADR-020 consumption-engine slice (PR3) takes them over.
        -- They hold only their defaults, so an upsert that leaves them
        -- untouched cannot leave a stale value. PR3 MUST delete this
        -- exclusion so the completeness guard covers them again; until
        -- then the inverse is asserted below (the refresh must not
        -- reference them yet).
        FOR v_col IN
            SELECT column_name FROM information_schema.columns
            WHERE table_schema='analytics' AND table_name=v_tbl
              AND column_name NOT IN ('device_id','bucket_start','calculated_at')
              AND NOT (
                  v_tier IN ('1min','5min')
                  AND column_name IN (
                      'is_reconstructed',
                      'import_reconstruction_role','import_reconstruction_method',
                      'import_gap_start','import_gap_end','import_gap_delta_wh',
                      'export_reconstruction_role','export_reconstruction_method',
                      'export_gap_start','export_gap_end','export_gap_delta_wh'
                  )
              )
        LOOP
            IF position(v_tbl||'.'||v_col IN v_def) = 0 THEN
                v_fail := v_fail || (v_tbl||': CASE omits stored column '||v_col);
            END IF;
            IF position('EXCLUDED.'||v_col IN v_def) = 0 THEN
                v_fail := v_fail || (v_tbl||': CASE / SET omits EXCLUDED.'||v_col);
            END IF;
            -- the DO UPDATE SET must still assign this column from EXCLUDED
            IF v_def !~ ('\m'||v_col||'\s*=\s*EXCLUDED\.'||v_col||'\M') THEN
                v_fail := v_fail || (v_tbl||': DO UPDATE SET no longer writes '||v_col||' (ROW_COUNT contract at risk)');
            END IF;
        END LOOP;

        -- Migration 268 staged exception, inverse side: until ADR-020 PR3,
        -- no 1min/5min refresh function may read or write a reconstruction
        -- column.
        IF v_tier IN ('1min','5min')
           AND v_def ~* '(is_reconstructed|_reconstruction_role|_reconstruction_method|_gap_start|_gap_end|_gap_delta_wh)' THEN
            v_fail := v_fail || (v_tbl||': references an ADR-020 reconstruction column before PR3 -- remove the migration-268 exclusion above');
        END IF;

        -- return contract: still GET DIAGNOSTICS ... = ROW_COUNT and RETURN it
        IF v_def !~ 'GET DIAGNOSTICS\s+\S+\s*=\s*ROW_COUNT' THEN
            v_fail := v_fail || (v_tbl||': GET DIAGNOSTICS = ROW_COUNT removed');
        END IF;
        -- unchanged surface: still SECURITY DEFINER, still pinned search_path
        IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                       WHERE n.nspname='analytics' AND p.proname='refresh_'||v_tbl
                         AND p.prosecdef AND p.proconfig IS NOT NULL
                         AND pg_get_userbyid(p.proowner)='ems_admin') THEN
            v_fail := v_fail || (v_tbl||': not DEFINER/pinned/ems_admin any more');
        END IF;
    END LOOP;

    IF array_length(v_fail,1) > 0 THEN
        RAISE EXCEPTION '1 FAILED: %', array_to_string(v_fail, ' | ');
    END IF;
END;
$t$;
\echo 'PASS: 1  all 5 refresh_* -- value-aware calculated_at CASE present, column-complete on both sides, every value column still written from EXCLUDED, ROW_COUNT/DEFINER/search_path intact, old unconditional bump gone'

-- ======================================================================
-- fixtures for the behavioural parts (mirrors assert_analytical_reconciliation)
-- ======================================================================
CREATE TEMP TABLE r216 (k text PRIMARY KEY, u uuid) ON COMMIT DROP;
DO $t$
DECLARE v_org uuid := gen_random_uuid(); v_site uuid := gen_random_uuid();
BEGIN
    INSERT INTO metadata.organizations (id, name, code, description, is_active)
    VALUES (v_org, 'M216 tenant', 'M216_TENANT', 'disposable', TRUE);
    INSERT INTO metadata.sites (id, organization_id, name, code, timezone, address, is_active)
    VALUES (v_site, v_org, 'M216 site', 'M216_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE);
    INSERT INTO r216(k,u) VALUES
      ('org',v_org),('site',v_site),
      ('d15',gen_random_uuid()),('dh',gen_random_uuid()),('dd',gen_random_uuid()),('dc',gen_random_uuid());
END;
$t$;

-- seed one analytics.energy_consumption_1min row (native tier, seeded directly --
-- the CAgg cannot be refreshed in a txn; identical approach to the repo's
-- semantic-contract test).
CREATE FUNCTION pg_temp.seed1m(p_dev uuid, p_bucket timestamptz, p_samples bigint, p_kwh numeric)
RETURNS void LANGUAGE sql AS $f$
    INSERT INTO analytics.energy_consumption_1min
      (bucket_start, organization_id, site_id, device_id, previous_bucket_start,
       elapsed_minutes, source_sample_count, import_register_wh, previous_import_register_wh,
       import_consumption_wh, import_consumption_kwh, import_quality_code, import_is_valid,
       import_reset_detected, import_rollover_detected, export_register_wh, previous_export_register_wh,
       export_consumption_wh, export_consumption_kwh, export_quality_code, export_is_valid,
       export_reset_detected, export_rollover_detected, gap_detected, quality_rule_id,
       gap_threshold_minutes, quality_rule_scope, quality_rule_scope_key, calculated_at)
    VALUES
      (p_bucket, (SELECT u FROM r216 WHERE k='org'), (SELECT u FROM r216 WHERE k='site'), p_dev,
       p_bucket - INTERVAL '1 minute', 1, p_samples, 1000+p_kwh*1000, 1000,
       p_kwh*1000, p_kwh, 'GOOD', TRUE, FALSE, FALSE, 0, 0, 0, 0, 'GOOD', TRUE, FALSE, FALSE,
       FALSE, NULL, 1.5, 'TEST', 'TEST', p_bucket + INTERVAL '2 min')
    ON CONFLICT (device_id,bucket_start) DO UPDATE SET
       source_sample_count = EXCLUDED.source_sample_count,
       import_consumption_kwh = EXCLUDED.import_consumption_kwh,
       import_register_wh = EXCLUDED.import_register_wh,
       calculated_at = EXCLUDED.calculated_at;
$f$;

-- seed one analytics.energy_consumption_15min row.
CREATE FUNCTION pg_temp.seed15(p_dev uuid, p_bucket timestamptz, p_sic bigint, p_kwh numeric)
RETURNS void LANGUAGE sql AS $f$
    INSERT INTO analytics.energy_consumption_15min
      (bucket_start, organization_id, site_id, device_id, source_interval_count,
       import_consumption_kwh, export_consumption_kwh, valid_import_intervals, invalid_import_intervals,
       valid_export_intervals, invalid_export_intervals, gap_interval_count, reset_interval_count,
       rollover_interval_count, invalid_interval_count, import_gap_intervals, export_gap_intervals,
       import_reset_intervals, export_reset_intervals, import_rollover_intervals, export_rollover_intervals,
       first_source_bucket, last_source_bucket, calculated_at)
    VALUES
      (p_bucket, (SELECT u FROM r216 WHERE k='org'), (SELECT u FROM r216 WHERE k='site'), p_dev,
       p_sic, p_kwh, 0, p_sic, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
       p_bucket + INTERVAL '1 min', p_bucket + INTERVAL '14 min', p_bucket + INTERVAL '20 min')
    ON CONFLICT (device_id,bucket_start) DO UPDATE SET
       source_interval_count = EXCLUDED.source_interval_count,
       import_consumption_kwh = EXCLUDED.import_consumption_kwh,
       calculated_at = EXCLUDED.calculated_at;
$f$;

-- ======================================================================
-- PART 2 -- BEHAVIOURAL A-I for 15min / hourly / daily.
-- ======================================================================

-- ---- 15min : source = analytics.energy_consumption_1min (via v_energy_semantic_rollup_15min)
DO $t$
DECLARE
    v_dev  uuid := (SELECT u FROM r216 WHERE k='d15');
    v_b15  timestamptz := date_bin('15 min', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - INTERVAL '5 days';
    v_c1 timestamptz; v_c2 timestamptz; v_c3 timestamptz;
    v_kwh1 numeric; v_kwh2 numeric;
BEGIN
    -- A. seed 3 native minutes in one 15-min bucket, then refresh 15min
    PERFORM pg_temp.seed1m(v_dev, v_b15 + INTERVAL '1 min', 1, 0.10);
    PERFORM pg_temp.seed1m(v_dev, v_b15 + INTERVAL '2 min', 1, 0.20);
    PERFORM pg_temp.seed1m(v_dev, v_b15 + INTERVAL '3 min', 1, 0.30);
    PERFORM analytics.refresh_energy_consumption_15min(v_b15, v_b15 + INTERVAL '15 min');
    SELECT calculated_at, import_consumption_kwh INTO v_c1, v_kwh1
      FROM analytics.energy_consumption_15min WHERE device_id=v_dev AND bucket_start=v_b15;
    IF v_c1 IS NULL THEN RAISE EXCEPTION '2/15min A FAILED: row not produced'; END IF;

    -- B + C + D. refresh again, source unchanged -> calculated_at NOT advanced, value identical
    PERFORM pg_sleep(0.02);
    PERFORM analytics.refresh_energy_consumption_15min(v_b15, v_b15 + INTERVAL '15 min');
    SELECT calculated_at, import_consumption_kwh INTO v_c2, v_kwh2
      FROM analytics.energy_consumption_15min WHERE device_id=v_dev AND bucket_start=v_b15;
    IF v_c2 IS DISTINCT FROM v_c1 THEN
        RAISE EXCEPTION '2/15min C FAILED: no-op refresh advanced calculated_at (% -> %)', v_c1, v_c2;
    END IF;
    IF v_kwh2 IS DISTINCT FROM v_kwh1 THEN
        RAISE EXCEPTION '2/15min D FAILED: no-op refresh changed value (% -> %)', v_kwh1, v_kwh2;
    END IF;

    -- E + F + G + H. change the authoritative source, refresh -> value changes, calculated_at advances
    PERFORM pg_temp.seed1m(v_dev, v_b15 + INTERVAL '3 min', 1, 0.99);   -- 0.30 -> 0.99
    PERFORM pg_sleep(0.02);
    PERFORM analytics.refresh_energy_consumption_15min(v_b15, v_b15 + INTERVAL '15 min');
    SELECT calculated_at, import_consumption_kwh INTO v_c3, v_kwh2
      FROM analytics.energy_consumption_15min WHERE device_id=v_dev AND bucket_start=v_b15;
    IF v_kwh2 = v_kwh1 THEN RAISE EXCEPTION '2/15min G FAILED: real source change did not change the aggregate value'; END IF;
    IF v_c3 <= v_c1 THEN RAISE EXCEPTION '2/15min H FAILED: real change did not advance calculated_at (% !> %)', v_c3, v_c1; END IF;

    -- I. the downstream (hourly) reconcile detector sees the genuine change:
    --    seed a matching hourly row that is now stale-by-recency, confirm it is flagged.
    INSERT INTO analytics.energy_consumption_hourly
      (bucket_start, organization_id, site_id, device_id, source_interval_count,
       import_consumption_kwh, export_consumption_kwh, valid_import_intervals, invalid_import_intervals,
       valid_export_intervals, invalid_export_intervals, gap_interval_count, reset_interval_count,
       rollover_interval_count, invalid_interval_count, calculated_at)
    VALUES (date_bin('1 hour', v_b15, TIMESTAMPTZ '2000-01-01 00:00:00+00'),
       (SELECT u FROM r216 WHERE k='org'), (SELECT u FROM r216 WHERE k='site'), v_dev,
       3, v_kwh1, 0, 3,0,0,0,0,0,0,0, v_c1);   -- hourly.calculated_at = the pre-change 15min stamp
    IF NOT EXISTS (
        SELECT 1 FROM analytics.reconcile_energy_deficits(
            'energy_consumption_hourly',
            date_bin('1 hour', v_b15, TIMESTAMPTZ '2000-01-01 00:00:00+00'),
            date_bin('1 hour', v_b15, TIMESTAMPTZ '2000-01-01 00:00:00+00') + INTERVAL '1 hour',
            INTERVAL '1 hour', 10)
    ) THEN
        RAISE EXCEPTION '2/15min I FAILED: downstream detector did not flag a hourly row stale vs a genuinely-recomputed 15min parent';
    END IF;
END;
$t$;
\echo 'PASS: 2/15min  A-I -- no-op refresh preserves calculated_at + value; real source change advances both; downstream detector still catches a genuine change'

-- ---- hourly : source = analytics.energy_consumption_15min
DO $t$
DECLARE
    v_dev uuid := (SELECT u FROM r216 WHERE k='dh');
    v_hr  timestamptz := date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - INTERVAL '5 days';
    v_c1 timestamptz; v_c2 timestamptz; v_c3 timestamptz; v_si bigint;
BEGIN
    PERFORM pg_temp.seed15(v_dev, v_hr,                     4, 0.4);
    PERFORM pg_temp.seed15(v_dev, v_hr + INTERVAL '15 min', 3, 0.3);
    PERFORM pg_temp.seed15(v_dev, v_hr + INTERVAL '30 min', 5, 0.5);
    PERFORM pg_temp.seed15(v_dev, v_hr + INTERVAL '45 min', 2, 0.2);
    PERFORM analytics.refresh_energy_consumption_hourly(v_hr, v_hr + INTERVAL '1 hour');
    SELECT calculated_at, source_interval_count INTO v_c1, v_si
      FROM analytics.energy_consumption_hourly WHERE device_id=v_dev AND bucket_start=v_hr;
    IF v_si <> 14 THEN RAISE EXCEPTION '2/hourly A FAILED: source_interval_count % (expected SUM=14)', v_si; END IF;

    PERFORM pg_sleep(0.02);
    PERFORM analytics.refresh_energy_consumption_hourly(v_hr, v_hr + INTERVAL '1 hour');
    SELECT calculated_at INTO v_c2 FROM analytics.energy_consumption_hourly WHERE device_id=v_dev AND bucket_start=v_hr;
    IF v_c2 IS DISTINCT FROM v_c1 THEN RAISE EXCEPTION '2/hourly C FAILED: no-op refresh advanced calculated_at (% -> %)', v_c1, v_c2; END IF;

    PERFORM pg_temp.seed15(v_dev, v_hr + INTERVAL '30 min', 9, 0.9);   -- 5/0.5 -> 9/0.9
    PERFORM pg_sleep(0.02);
    PERFORM analytics.refresh_energy_consumption_hourly(v_hr, v_hr + INTERVAL '1 hour');
    SELECT calculated_at, source_interval_count INTO v_c3, v_si
      FROM analytics.energy_consumption_hourly WHERE device_id=v_dev AND bucket_start=v_hr;
    IF v_si <> 18 THEN RAISE EXCEPTION '2/hourly G FAILED: source_interval_count % (expected new SUM=18)', v_si; END IF;
    IF v_c3 <= v_c1 THEN RAISE EXCEPTION '2/hourly H FAILED: real change did not advance calculated_at'; END IF;

    -- I. immediate reconcile after a genuine repair converges (HEALTHY / 0) --
    --    the no-op that the wrapper will perform next minute must NOT re-open work.
    UPDATE telemetry.pipeline_state SET last_received_at = v_hr + INTERVAL '2 hours', last_status='SUCCESS'
      WHERE pipeline_name='energy_consumption_hourly';
    CALL analytics.reconcile_energy_consumption_hourly(0, '{"reconcile_window":"7 days","n_max":6}'::jsonb);
    PERFORM analytics.refresh_energy_consumption_hourly(v_hr, v_hr + INTERVAL '1 hour');   -- simulate the next forward no-op
    CALL analytics.reconcile_energy_consumption_hourly(0, '{"reconcile_window":"7 days","n_max":6}'::jsonb);
    IF (SELECT outcome FROM analytics.pipeline_reconciliation_log
          WHERE tier='energy_consumption_hourly' ORDER BY ran_at DESC LIMIT 1) <> 'HEALTHY' THEN
        RAISE EXCEPTION '2/hourly I FAILED: reconcile after a no-op forward refresh is not HEALTHY (recency deficit manufactured)';
    END IF;
END;
$t$;
\echo 'PASS: 2/hourly  A-I -- no-op refresh preserves calculated_at; real change advances it; a no-op forward refresh after a repair does NOT re-open reconcile work'

-- ---- daily : source = analytics.energy_consumption_15min (site-local day)
DO $t$
DECLARE
    v_dev uuid := (SELECT u FROM r216 WHERE k='dd');
    -- a full IST local day, safely historical
    v_day_ist date := ((now() AT TIME ZONE 'Asia/Kolkata')::date - 5);
    v_ls  timestamptz := (v_day_ist::timestamp AT TIME ZONE 'Asia/Kolkata');
    v_from timestamptz := v_ls;
    v_to   timestamptz := v_ls + INTERVAL '1 day';
    v_c1 timestamptz; v_c2 timestamptz; v_c3 timestamptz; v_si bigint;
BEGIN
    PERFORM pg_temp.seed15(v_dev, v_ls,                        6, 0.6);
    PERFORM pg_temp.seed15(v_dev, v_ls + INTERVAL '6 hours',   6, 0.6);
    PERFORM pg_temp.seed15(v_dev, v_ls + INTERVAL '18 hours',  6, 0.6);
    PERFORM analytics.refresh_energy_consumption_daily(v_from, v_to);
    SELECT calculated_at, source_interval_count INTO v_c1, v_si
      FROM analytics.energy_consumption_daily WHERE device_id=v_dev AND bucket_start=v_ls;
    IF v_si <> 18 THEN RAISE EXCEPTION '2/daily A FAILED: source_interval_count % (expected SUM=18)', v_si; END IF;

    PERFORM pg_sleep(0.02);
    PERFORM analytics.refresh_energy_consumption_daily(v_from, v_to);
    SELECT calculated_at INTO v_c2 FROM analytics.energy_consumption_daily WHERE device_id=v_dev AND bucket_start=v_ls;
    IF v_c2 IS DISTINCT FROM v_c1 THEN RAISE EXCEPTION '2/daily C FAILED: no-op refresh advanced calculated_at (% -> %)', v_c1, v_c2; END IF;

    PERFORM pg_temp.seed15(v_dev, v_ls + INTERVAL '6 hours', 11, 1.1);   -- 6 -> 11
    PERFORM pg_sleep(0.02);
    PERFORM analytics.refresh_energy_consumption_daily(v_from, v_to);
    SELECT calculated_at, source_interval_count INTO v_c3, v_si
      FROM analytics.energy_consumption_daily WHERE device_id=v_dev AND bucket_start=v_ls;
    IF v_si <> 23 THEN RAISE EXCEPTION '2/daily G FAILED: source_interval_count % (expected new SUM=23)', v_si; END IF;
    IF v_c3 <= v_c1 THEN RAISE EXCEPTION '2/daily H FAILED: real change did not advance calculated_at'; END IF;

    -- I. downstream detector: an already-correct daily row that is stale-by-recency
    --    vs a genuinely-recomputed 15min parent is still flagged.
    UPDATE analytics.energy_consumption_daily SET calculated_at = v_c1
      WHERE device_id=v_dev AND bucket_start=v_ls;                       -- freeze it in the past
    UPDATE analytics.energy_consumption_daily SET source_interval_count = 23   -- value already correct
      WHERE device_id=v_dev AND bucket_start=v_ls;
    -- the daily reconcile is an inline site-local-day detector; drive it and expect it re-drives this day
    UPDATE telemetry.pipeline_state SET last_received_at = v_to + INTERVAL '2 days', last_status='SUCCESS'
      WHERE pipeline_name='energy_consumption_daily';
    CALL analytics.reconcile_energy_consumption_daily(0, '{"reconcile_window":"21 days","n_max":6}'::jsonb);
    IF (SELECT outcome FROM analytics.pipeline_reconciliation_log
          WHERE tier='energy_consumption_daily' ORDER BY ran_at DESC LIMIT 1) NOT IN ('REPAIRED','HEALTHY') THEN
        RAISE EXCEPTION '2/daily I FAILED: daily reconcile outcome unexpected';
    END IF;
END;
$t$;
\echo 'PASS: 2/daily  A-I -- no-op refresh preserves calculated_at; real change advances it; downstream reconcile behaves'

-- ======================================================================
-- PART 3 -- the 1min/5min DO-UPDATE CASE mechanism (behavioural, on a probe):
--   the exact SQL construct migration 216 applies -- NULL-safe, numeric-scale
--   safe, and a matched no-op row is STILL counted by ROW_COUNT.
-- ======================================================================
DO $t$
DECLARE
    v_dev uuid := gen_random_uuid();
    v_b   timestamptz := now();
    v_c0 timestamptz; v_c1 timestamptz; v_c2 timestamptz; v_rc bigint;
BEGIN
    CREATE TEMP TABLE t216_probe(
        device_id uuid, bucket_start timestamptz,
        vb bigint, vn numeric, vt text, vbool boolean, vts timestamptz,
        calculated_at timestamptz NOT NULL,
        PRIMARY KEY (device_id, bucket_start)
    ) ON COMMIT DROP;

    -- initial insert
    INSERT INTO t216_probe VALUES (v_dev, v_b, 10, 1.50, 'x', TRUE, NULL, v_b);
    SELECT calculated_at INTO v_c0 FROM t216_probe WHERE device_id=v_dev AND bucket_start=v_b;

    -- no-op upsert: identical values (note 1.50 vs 1.5 -> numeric scale differs but value equal;
    -- vts NULL both sides -> IS DISTINCT FROM must treat as equal)
    PERFORM pg_sleep(0.02);
    INSERT INTO t216_probe AS p VALUES (v_dev, v_b, 10, 1.5, 'x', TRUE, NULL, clock_timestamp())
    ON CONFLICT (device_id,bucket_start) DO UPDATE SET
        vb = EXCLUDED.vb, vn = EXCLUDED.vn, vt = EXCLUDED.vt, vbool = EXCLUDED.vbool, vts = EXCLUDED.vts,
        calculated_at = CASE
            WHEN ROW(p.vb, p.vn, p.vt, p.vbool, p.vts)
                 IS DISTINCT FROM ROW(EXCLUDED.vb, EXCLUDED.vn, EXCLUDED.vt, EXCLUDED.vbool, EXCLUDED.vts)
            THEN EXCLUDED.calculated_at ELSE p.calculated_at END;
    GET DIAGNOSTICS v_rc = ROW_COUNT;
    SELECT calculated_at INTO v_c1 FROM t216_probe WHERE device_id=v_dev AND bucket_start=v_b;
    IF v_rc <> 1 THEN RAISE EXCEPTION '3 FAILED: matched no-op upsert not counted by ROW_COUNT (got %) -- wrapper NO_SOURCE_DATA contract would break', v_rc; END IF;
    IF v_c1 IS DISTINCT FROM v_c0 THEN RAISE EXCEPTION '3 FAILED: no-op CASE advanced calculated_at (% -> %)', v_c0, v_c1; END IF;

    -- real change in ONE column -> calculated_at advances
    PERFORM pg_sleep(0.02);
    INSERT INTO t216_probe AS p VALUES (v_dev, v_b, 10, 1.5, 'x', FALSE, NULL, clock_timestamp())
    ON CONFLICT (device_id,bucket_start) DO UPDATE SET
        vb = EXCLUDED.vb, vn = EXCLUDED.vn, vt = EXCLUDED.vt, vbool = EXCLUDED.vbool, vts = EXCLUDED.vts,
        calculated_at = CASE
            WHEN ROW(p.vb, p.vn, p.vt, p.vbool, p.vts)
                 IS DISTINCT FROM ROW(EXCLUDED.vb, EXCLUDED.vn, EXCLUDED.vt, EXCLUDED.vbool, EXCLUDED.vts)
            THEN EXCLUDED.calculated_at ELSE p.calculated_at END;
    SELECT calculated_at INTO v_c2 FROM t216_probe WHERE device_id=v_dev AND bucket_start=v_b;
    IF v_c2 <= v_c0 THEN RAISE EXCEPTION '3 FAILED: real change (vbool TRUE->FALSE) did not advance calculated_at'; END IF;

    -- NULL transition detected: vts NULL -> a value
    PERFORM pg_sleep(0.02);
    INSERT INTO t216_probe AS p VALUES (v_dev, v_b, 10, 1.5, 'x', FALSE, v_b, clock_timestamp())
    ON CONFLICT (device_id,bucket_start) DO UPDATE SET
        vb=EXCLUDED.vb, vn=EXCLUDED.vn, vt=EXCLUDED.vt, vbool=EXCLUDED.vbool, vts=EXCLUDED.vts,
        calculated_at = CASE
            WHEN ROW(p.vb, p.vn, p.vt, p.vbool, p.vts)
                 IS DISTINCT FROM ROW(EXCLUDED.vb, EXCLUDED.vn, EXCLUDED.vt, EXCLUDED.vbool, EXCLUDED.vts)
            THEN EXCLUDED.calculated_at ELSE p.calculated_at END;
    IF (SELECT calculated_at FROM t216_probe WHERE device_id=v_dev AND bucket_start=v_b) <= v_c2 THEN
        RAISE EXCEPTION '3 FAILED: NULL -> value transition not detected by IS DISTINCT FROM';
    END IF;
END;
$t$;
\echo 'PASS: 3  1min/5min DO-UPDATE CASE construct: NULL-safe, numeric-scale-safe, no-op preserves calculated_at, real change advances it, and a matched no-op row is STILL counted by ROW_COUNT'

-- ======================================================================
-- PART 4 -- CASCADE FIXED POINT: 1min -> 15min -> hourly -> daily.
--   A no-op upstream refresh advances NOTHING downstream and creates NO
--   reconciliation work; a genuine upstream change propagates + is detected.
-- ======================================================================
DO $t$
DECLARE
    v_dev uuid := (SELECT u FROM r216 WHERE k='dc');
    v_day_ist date := ((now() AT TIME ZONE 'Asia/Kolkata')::date - 6);
    v_ls   timestamptz := (v_day_ist::timestamp AT TIME ZONE 'Asia/Kolkata');
    v_b15  timestamptz := date_bin('15 min', v_ls + INTERVAL '3 hours', TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_hr   timestamptz := date_bin('1 hour', v_b15, TIMESTAMPTZ '2000-01-01 00:00:00+00');
    c15a timestamptz; c15b timestamptz; chra timestamptz; chrb timestamptz; cdda timestamptz; cddb timestamptz;
    c15c timestamptz; chrc timestamptz;
BEGIN
    -- build the chain
    PERFORM pg_temp.seed1m(v_dev, v_b15 + INTERVAL '1 min', 1, 0.10);
    PERFORM pg_temp.seed1m(v_dev, v_b15 + INTERVAL '2 min', 1, 0.20);
    PERFORM analytics.refresh_energy_consumption_15min(v_b15, v_b15 + INTERVAL '15 min');
    PERFORM analytics.refresh_energy_consumption_hourly(v_hr, v_hr + INTERVAL '1 hour');
    PERFORM analytics.refresh_energy_consumption_daily(v_ls, v_ls + INTERVAL '1 day');
    SELECT calculated_at INTO c15a FROM analytics.energy_consumption_15min WHERE device_id=v_dev AND bucket_start=v_b15;
    SELECT calculated_at INTO chra FROM analytics.energy_consumption_hourly WHERE device_id=v_dev AND bucket_start=v_hr;
    SELECT calculated_at INTO cdda FROM analytics.energy_consumption_daily  WHERE device_id=v_dev AND bucket_start=v_ls;

    -- RUN N+1: no-op reprocess of every tier (nothing in the source changed)
    PERFORM pg_sleep(0.03);
    PERFORM analytics.refresh_energy_consumption_15min(v_b15, v_b15 + INTERVAL '15 min');
    PERFORM analytics.refresh_energy_consumption_hourly(v_hr, v_hr + INTERVAL '1 hour');
    PERFORM analytics.refresh_energy_consumption_daily(v_ls, v_ls + INTERVAL '1 day');
    SELECT calculated_at INTO c15b FROM analytics.energy_consumption_15min WHERE device_id=v_dev AND bucket_start=v_b15;
    SELECT calculated_at INTO chrb FROM analytics.energy_consumption_hourly WHERE device_id=v_dev AND bucket_start=v_hr;
    SELECT calculated_at INTO cddb FROM analytics.energy_consumption_daily  WHERE device_id=v_dev AND bucket_start=v_ls;
    IF c15b IS DISTINCT FROM c15a THEN RAISE EXCEPTION '4 FAILED: no-op 15min refresh advanced 15min.calculated_at'; END IF;
    IF chrb IS DISTINCT FROM chra THEN RAISE EXCEPTION '4 FAILED: no-op hourly refresh advanced hourly.calculated_at'; END IF;
    IF cddb IS DISTINCT FROM cdda THEN RAISE EXCEPTION '4 FAILED: no-op daily refresh advanced daily.calculated_at'; END IF;

    -- and the detectors see NO deficit for the no-op chain
    IF EXISTS (SELECT 1 FROM analytics.reconcile_energy_deficits('energy_consumption_hourly', v_hr, v_hr + INTERVAL '1 hour', INTERVAL '1 hour', 10)) THEN
        RAISE EXCEPTION '4 FAILED: hourly detector manufactured a deficit from a no-op 15min reprocess';
    END IF;

    -- RUN N+2: a GENUINE upstream change must propagate its calculated_at advance
    PERFORM pg_temp.seed1m(v_dev, v_b15 + INTERVAL '2 min', 1, 0.77);   -- 0.20 -> 0.77
    PERFORM pg_sleep(0.03);
    PERFORM analytics.refresh_energy_consumption_15min(v_b15, v_b15 + INTERVAL '15 min');
    PERFORM analytics.refresh_energy_consumption_hourly(v_hr, v_hr + INTERVAL '1 hour');
    SELECT calculated_at INTO c15c FROM analytics.energy_consumption_15min WHERE device_id=v_dev AND bucket_start=v_b15;
    SELECT calculated_at INTO chrc FROM analytics.energy_consumption_hourly WHERE device_id=v_dev AND bucket_start=v_hr;
    IF c15c <= c15a THEN RAISE EXCEPTION '4 FAILED: genuine source change did not advance 15min.calculated_at'; END IF;
    IF chrc <= chra THEN RAISE EXCEPTION '4 FAILED: genuine 15min change did not propagate to hourly.calculated_at'; END IF;
END;
$t$;
\echo 'PASS: 4  cascade fixed point -- Run N+1 (no-op) advances nothing 1min->15min->hourly->daily and creates no reconcile work; Run N+2 (genuine change) propagates the calculated_at advance and is detected'

ROLLBACK;
SQL

printf '%s\n' 'OK: migration 216 value-aware calculated_at assertions passed.'
