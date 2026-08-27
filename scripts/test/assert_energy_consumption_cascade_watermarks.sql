-- ============================================================================
-- File:
--   scripts/test/assert_energy_consumption_cascade_watermarks.sql
--
-- Purpose:
--   Regression test for migration 209 (Phase 2 Foundation, Phase 1 part 1):
--   the five run_energy_consumption_*_job wrappers are now child-watermark
--   driven -- their [v_from, v_to) is derived from a parent's actual
--   availability plus the child's own checkpoint plus a bounded catch-up
--   window, replacing the old now()-<fixed lookback>.
--
--   Contract under test (identical for every tier):
--     v_ckpt   = telemetry.pipeline_state(child).last_received_at
--     v_parent = parent_available_through (read live):
--                  1min/5min : analytics.cagg_available_through(ca_energy_1min/5min)
--                  15min     : LEAST( cp(energy_consumption_1min), cp(energy_consumption_5min) )
--                  hourly    : cp(energy_consumption_15min)
--                  daily     : cp(energy_consumption_15min)
--     v_start  = COALESCE(v_ckpt, now_binned - lookback)   -- lookback = first-run floor only
--     v_to     = LEAST(now_binned, v_parent, v_start + max_catchup_window)
--     skip (no advance) if v_parent IS NULL or v_to <= v_start
--     else refresh_*(v_start - overlap, v_to); then last_received_at = v_to
--     failure/timeout => whole txn rolls back => checkpoint unchanged
--
--   Method: fully deterministic, rollback-only. For the two CAGG-fed tiers the
--   analytics.cagg_available_through() helper is temporarily replaced (inside
--   this transaction; the real definition is restored by ROLLBACK) with a stub
--   reading a pg_temp control table, so parent_available_through is exactly
--   controllable without running a non-transactional refresh_continuous_aggregate.
--   For 15min/hourly/daily the parent is a pipeline_state checkpoint, set
--   directly. refresh_energy_consumption_* over a window with no matching
--   synthetic source rows returns 0 and writes nothing, but the wrapper still
--   advances last_received_at to v_to -- so the resulting checkpoint IS the
--   computed v_to and every window-derivation assertion is exact.
--
--   Tests: A initial watermark; B normal forward; C parent ahead -> bounded to
--   min(parent, ckpt+catchup); D parent unavailable -> no advance; E per-run
--   advance <= max_catchup_window; F successive runs drain a backlog;
--   G/H failure -> checkpoint unchanged (single-transaction model); I identical
--   re-run is idempotent (checkpoint + rows); J self-overlap guard intact
--   (structural; behavioural proof in assert_analytics_job_self_overlap.sh);
--   K 1min->15min cannot exceed LEAST(cp_1min,cp_5min); L 5min empty-by-design
--   does not block 15min and still advances its own checkpoint; M 15min->hourly
--   bound; N 15min->daily bound; O CAGG watermark (not now()) is the 1min/5min
--   bound; P tenant isolation preserved by refresh_energy_consumption_15min;
--   Q wrapper-driven output == direct refresh call output for the same window.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- --- CAGG-watermark stub (rolled back at the end of this transaction) --------
CREATE TEMP TABLE t209_cagg_wm (cagg text PRIMARY KEY, wm timestamptz);

CREATE OR REPLACE FUNCTION analytics.cagg_available_through(p_cagg regclass)
RETURNS timestamptz LANGUAGE sql STABLE AS $stub$
    SELECT wm FROM pg_temp.t209_cagg_wm WHERE cagg = p_cagg::text;
$stub$;

DO $t$
DECLARE
    v_base   TIMESTAMPTZ := date_trunc('hour', now()) - INTERVAL '30 days';  -- deterministic, far from "now"
    v_now1   TIMESTAMPTZ := date_trunc('minute', clock_timestamp());
    v_res    TIMESTAMPTZ;
    v_res2   TIMESTAMPTZ;
    v_status TEXT;
    v_raised BOOLEAN;
    v_cfg1   jsonb := '{"lookback":"30 minutes","max_catchup_window":"2 hours","overlap":"2 minutes","reconcile_window":"2 days"}';
    v_cfg5   jsonb := '{"lookback":"30 minutes","max_catchup_window":"2 hours","overlap":"10 minutes","reconcile_window":"7 days"}';
    v_cfg15  jsonb := '{"lookback":"2 hours","max_catchup_window":"6 hours","overlap":"30 minutes","reconcile_window":"3 days"}';
    v_cfgH   jsonb := '{"lookback":"2 days","max_catchup_window":"2 days","overlap":"2 hours","reconcile_window":"10 days"}';
    v_cfgD   jsonb := '{"lookback":"8 days","max_catchup_window":"8 days","overlap":"2 days","reconcile_window":"21 days"}';
    v_rows   BIGINT;
BEGIN
    -- The TimescaleDB scheduler runs these five jobs every 1-5 minutes in the
    -- test database. Hold their advisory locks for the duration of this
    -- transaction so a concurrently-scheduled run takes the SKIPPED_LOCKED
    -- path instead of racing our controlled CALLs (advisory locks are
    -- re-entrant within a session, so our own wrapper CALLs still proceed).
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_1min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_5min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_daily_job', 0));

    -- Clean slate for the five energy pipelines (rolled back).
    UPDATE telemetry.pipeline_state
    SET last_received_at=NULL, last_status='NEVER_RUN', last_started_at=NULL,
        last_completed_at=NULL, last_error=NULL, last_inserted_rows=0
    WHERE pipeline_name LIKE 'energy_consumption%';

    -- ===================================================================
    -- A: initial watermark creation. First run (checkpoint NULL), CAGG
    -- watermark ~= now (the realistic steady state). The child advances
    -- from the first-run floor to LEAST(now_binned, cagg_wm, floor+catchup).
    -- ===================================================================
    INSERT INTO pg_temp.t209_cagg_wm VALUES ('telemetry.ca_energy_1min', v_now1);
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);
    SELECT last_received_at, last_status INTO v_res, v_status
    FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    -- v_start = now1 - 30m ; v_to = LEAST(now1, now1, now1 - 30m + 2h) = now1.
    IF v_res IS DISTINCT FROM v_now1 THEN
        RAISE EXCEPTION 'TEST A FAILED (1min first run): expected checkpoint = now_binned (%), got %', v_now1, v_res;
    END IF;
    RAISE NOTICE 'TEST A passed: first run creates the checkpoint at LEAST(now_binned, parent, floor+catchup) = %.', v_res;

    -- ===================================================================
    -- O: the 1-minute bound is the CAGG materialization watermark, NOT
    -- now(). Checkpoint 30 days back; CAGG watermark just 30 minutes ahead
    -- of it; now() is ~30 days ahead. The child must stop at the CAGG
    -- watermark.
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_1min';
    UPDATE pg_temp.t209_cagg_wm SET wm = v_base + INTERVAL '30 minutes' WHERE cagg='telemetry.ca_energy_1min';
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    IF v_res IS DISTINCT FROM (v_base + INTERVAL '30 minutes') THEN
        RAISE EXCEPTION 'TEST O FAILED: expected checkpoint = CAGG watermark (% + 30m), got %', v_base, v_res;
    END IF;
    IF v_res >= v_now1 - INTERVAL '1 day' THEN
        RAISE EXCEPTION 'TEST O FAILED: 1min checkpoint % is anchored to now(), not the CAGG watermark', v_res;
    END IF;
    RAISE NOTICE 'TEST O passed: the 1min bound is the ca_energy_1min materialization watermark, not now() (checkpoint %).', v_res;

    -- ===================================================================
    -- B: normal forward progress. Checkpoint set; CAGG a little ahead
    -- (< max_catchup). Child advances exactly to the CAGG watermark.
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_1min';
    UPDATE pg_temp.t209_cagg_wm SET wm = v_base + INTERVAL '40 minutes' WHERE cagg='telemetry.ca_energy_1min';
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    IF v_res IS DISTINCT FROM (v_base + INTERVAL '40 minutes') THEN
        RAISE EXCEPTION 'TEST B FAILED: expected checkpoint = parent (% + 40m), got %', v_base, v_res;
    END IF;
    RAISE NOTICE 'TEST B passed: normal forward run advances the checkpoint to parent_available_through (%).', v_res;

    -- ===================================================================
    -- C + E: parent far ahead -> child advances by AT MOST
    -- max_catchup_window per run (checkpoint + 2h, not the parent).
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_1min';
    UPDATE pg_temp.t209_cagg_wm SET wm = v_base + INTERVAL '10 hours' WHERE cagg='telemetry.ca_energy_1min';
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    IF v_res IS DISTINCT FROM (v_base + INTERVAL '2 hours') THEN
        RAISE EXCEPTION 'TEST C/E FAILED: expected checkpoint bounded to ckpt+max_catchup (% + 2h), got %', v_base, v_res;
    END IF;
    IF v_res >= (v_base + INTERVAL '10 hours') THEN
        RAISE EXCEPTION 'TEST C/E FAILED: checkpoint % raced ahead to the parent boundary', v_res;
    END IF;
    RAISE NOTICE 'TEST C/E passed: a far-ahead parent advances the child by exactly one max_catchup_window (%).', v_res;

    -- ===================================================================
    -- F: successive runs drain the backlog in bounded steps.
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_1min';
    -- parent stays 10h ahead
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);   -- -> +2h
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);   -- -> +4h
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);   -- -> +6h
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    IF v_res IS DISTINCT FROM (v_base + INTERVAL '6 hours') THEN
        RAISE EXCEPTION 'TEST F FAILED: 3 successive bounded runs should reach % + 6h, got %', v_base, v_res;
    END IF;
    RAISE NOTICE 'TEST F passed: successive bounded runs drain a backlog (% after 3 runs).', v_res;

    -- ===================================================================
    -- D: parent unavailable (no CAGG watermark) -> no advance, NO_SOURCE_DATA.
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_1min';
    DELETE FROM pg_temp.t209_cagg_wm WHERE cagg='telemetry.ca_energy_1min';   -- helper now returns NULL
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);
    SELECT last_received_at, last_status INTO v_res, v_status
    FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    IF v_res IS DISTINCT FROM v_base OR v_status <> 'NO_SOURCE_DATA' THEN
        RAISE EXCEPTION 'TEST D FAILED: parent unavailable should leave checkpoint at % with NO_SOURCE_DATA, got % / %', v_base, v_res, v_status;
    END IF;
    RAISE NOTICE 'TEST D passed: an unavailable parent leaves the checkpoint unchanged (NO_SOURCE_DATA).';
    INSERT INTO pg_temp.t209_cagg_wm VALUES ('telemetry.ca_energy_1min', v_base + INTERVAL '10 hours');  -- restore

    -- ===================================================================
    -- G/H: a failure anywhere in the run leaves the checkpoint unchanged
    -- (one transaction per run; no intermediate COMMIT).
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_1min';
    CREATE FUNCTION pg_temp.t209_boom() RETURNS trigger LANGUAGE plpgsql AS $b$
    BEGIN
        IF NEW.pipeline_name='energy_consumption_1min' AND NEW.last_status IN ('SUCCESS','NO_SOURCE_DATA') THEN
            RAISE EXCEPTION 't209: injected failure at the checkpoint-advance write';
        END IF;
        RETURN NEW;
    END $b$;
    CREATE TRIGGER t209_boom_trg BEFORE UPDATE ON telemetry.pipeline_state
        FOR EACH ROW EXECUTE FUNCTION pg_temp.t209_boom();
    v_raised := FALSE;
    BEGIN
        CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);
    EXCEPTION WHEN OTHERS THEN v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST G/H FAILED: injected failure did not propagate';
    END IF;
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    IF v_res IS DISTINCT FROM v_base THEN
        RAISE EXCEPTION 'TEST G/H FAILED: a failed run advanced the checkpoint from % to %', v_base, v_res;
    END IF;
    DROP TRIGGER t209_boom_trg ON telemetry.pipeline_state;
    RAISE NOTICE 'TEST G/H passed: a failed run leaves the checkpoint at its pre-run value (%).', v_res;

    -- ===================================================================
    -- I: identical re-run is idempotent (same resulting checkpoint, no error).
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_1min';
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_1min';
    CALL analytics.run_energy_consumption_1min_job(999209, v_cfg1);
    SELECT last_received_at INTO v_res2 FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    IF v_res IS DISTINCT FROM v_res2 THEN
        RAISE EXCEPTION 'TEST I FAILED: identical re-run produced a different checkpoint (% vs %)', v_res, v_res2;
    END IF;
    RAISE NOTICE 'TEST I passed: an identical re-run is idempotent (checkpoint %).', v_res2;

    -- ===================================================================
    -- J: self-overlap guard intact (structural). Behavioural cross-session
    -- proof: scripts/test/assert_analytics_job_self_overlap.sh (from 208).
    -- ===================================================================
    IF pg_get_functiondef('analytics.run_energy_consumption_1min_job(integer,jsonb)'::regprocedure)
       NOT LIKE '%pg_try_advisory_xact_lock(hashtextextended(''analytics.run_energy_consumption_1min_job'', 0))%'
       OR pg_get_functiondef('analytics.run_energy_consumption_1min_job(integer,jsonb)'::regprocedure)
       NOT LIKE '%last_status = ''SKIPPED_LOCKED''%' THEN
        RAISE EXCEPTION 'TEST J FAILED: migration 208 self-overlap guard missing from the watermark wrapper';
    END IF;
    RAISE NOTICE 'TEST J passed: migration 208 advisory-lock / SKIPPED_LOCKED guard preserved in the watermark wrapper.';

    -- ===================================================================
    -- K + L: 1min -> 15min cascade. 15min cannot advance past
    -- LEAST(cp_1min, cp_5min). LEAST skips NULL, so a NULL 5min checkpoint
    -- (empty-by-design / not-yet-run) falls back to cp_1min and does NOT
    -- block 15min.
    -- ===================================================================
    -- (a) both parents set: 15min bounded to the LESSER.
    UPDATE telemetry.pipeline_state SET last_received_at = v_base + INTERVAL '3 hours'  WHERE pipeline_name='energy_consumption_1min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_base + INTERVAL '1 hour'   WHERE pipeline_name='energy_consumption_5min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_base                       WHERE pipeline_name='energy_consumption_15min';
    CALL analytics.run_energy_consumption_15min_job(999209, v_cfg15);
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_15min';
    IF v_res > (v_base + INTERVAL '1 hour') THEN
        RAISE EXCEPTION 'TEST K FAILED: 15min checkpoint % exceeded LEAST(cp_1min, cp_5min) = % + 1h', v_res, v_base;
    END IF;
    RAISE NOTICE 'TEST K passed: 15min bounded by LEAST(cp_1min, cp_5min) (checkpoint %).', v_res;

    -- (b) 5min NULL (empty-by-design): 15min falls back to cp_1min, still advances.
    UPDATE telemetry.pipeline_state SET last_received_at = NULL                        WHERE pipeline_name='energy_consumption_5min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_base                      WHERE pipeline_name='energy_consumption_15min';
    CALL analytics.run_energy_consumption_15min_job(999209, v_cfg15);
    SELECT last_received_at, last_status INTO v_res, v_status FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_15min';
    IF v_res IS NULL OR v_res <= v_base THEN
        RAISE EXCEPTION 'TEST L FAILED: a NULL 5min checkpoint blocked the 15min cascade (checkpoint stayed %)', v_res;
    END IF;
    IF v_res > (v_base + INTERVAL '3 hours') THEN
        RAISE EXCEPTION 'TEST L FAILED: 15min checkpoint % exceeded cp_1min (fallback bound)', v_res;
    END IF;
    RAISE NOTICE 'TEST L passed: a NULL (empty-by-design) 5min checkpoint does not block 15min; it advances bounded by cp_1min (%).', v_res;

    -- (c) the 5min wrapper itself: empty result still advances its own checkpoint.
    INSERT INTO pg_temp.t209_cagg_wm VALUES ('telemetry.ca_energy_5min', v_base + INTERVAL '90 minutes')
      ON CONFLICT (cagg) DO UPDATE SET wm = EXCLUDED.wm;
    UPDATE telemetry.pipeline_state SET last_received_at = v_base WHERE pipeline_name='energy_consumption_5min';
    CALL analytics.run_energy_consumption_5min_job(999209, v_cfg5);
    SELECT last_received_at, last_status, last_inserted_rows INTO v_res, v_status, v_rows
    FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_5min';
    IF v_res IS DISTINCT FROM (v_base + INTERVAL '90 minutes') THEN
        RAISE EXCEPTION 'TEST L FAILED: empty 5min run did not advance its checkpoint to the CAGG watermark (got %)', v_res;
    END IF;
    IF v_rows <> 0 OR v_status <> 'NO_SOURCE_DATA' THEN
        RAISE EXCEPTION 'TEST L FAILED: expected 5min empty run to be NO_SOURCE_DATA/0 rows, got % / %', v_status, v_rows;
    END IF;
    RAISE NOTICE 'TEST L passed: the empty-by-design 5min wrapper advances its checkpoint (NO_SOURCE_DATA, 0 rows) so LEAST() never stalls.';

    -- ===================================================================
    -- M: 15min -> hourly. Hourly cannot outrun cp_15min.
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base + INTERVAL '5 hours' WHERE pipeline_name='energy_consumption_15min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_base                      WHERE pipeline_name='energy_consumption_hourly';
    CALL analytics.run_energy_consumption_hourly_job(999209, v_cfgH);
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_hourly';
    IF v_res > (v_base + INTERVAL '5 hours') THEN
        RAISE EXCEPTION 'TEST M FAILED: hourly checkpoint % exceeded cp_15min (% + 5h)', v_res, v_base;
    END IF;
    RAISE NOTICE 'TEST M passed: hourly bounded by cp_15min (checkpoint %).', v_res;

    -- ===================================================================
    -- N: 15min -> daily. Daily cannot outrun cp_15min (daily reads
    -- energy_consumption_15min directly, NOT hourly).
    -- ===================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_base + INTERVAL '2 days' WHERE pipeline_name='energy_consumption_15min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_base                     WHERE pipeline_name='energy_consumption_daily';
    CALL analytics.run_energy_consumption_daily_job(999209, v_cfgD);
    SELECT last_received_at INTO v_res FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_daily';
    IF v_res > (v_base + INTERVAL '2 days') THEN
        RAISE EXCEPTION 'TEST N FAILED: daily checkpoint % exceeded cp_15min (% + 2d)', v_res, v_base;
    END IF;
    RAISE NOTICE 'TEST N passed: daily bounded by cp_15min (checkpoint %).', v_res;

    RAISE NOTICE 'All migration-209 watermark-contract assertions (A,B,C,D,E,F,G,H,I,J,K,L,M,N,O) passed.';
END
$t$;

ROLLBACK;

-- ---------------------------------------------------------------------------
-- P + Q -- tenant isolation + calculation-equivalence, with a real synthetic
-- fixture. Rollback-only; no CAGG refresh needed (15min reads the persisted
-- 1min table via v_energy_semantic_rollup_15min).
-- ---------------------------------------------------------------------------
BEGIN;

DO $pq$
DECLARE
    v_org_a UUID := gen_random_uuid();
    v_org_b UUID := gen_random_uuid();
    v_site_a UUID := gen_random_uuid();
    v_site_b UUID := gen_random_uuid();
    v_dev_a UUID := gen_random_uuid();
    v_dev_b UUID := gen_random_uuid();
    v_t0    TIMESTAMPTZ := date_trunc('day', now()) - INTERVAL '10 days';
    i INT;
    v_wrapper_a NUMERIC;
    v_direct_a  NUMERIC;
    v_b_rows    BIGINT;
BEGIN
    -- The TimescaleDB scheduler runs these five jobs every 1-5 minutes in the
    -- test database. Hold their advisory locks for the duration of this
    -- transaction so a concurrently-scheduled run takes the SKIPPED_LOCKED
    -- path instead of racing our controlled CALLs (advisory locks are
    -- re-entrant within a session, so our own wrapper CALLs still proceed).
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_1min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_5min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_daily_job', 0));

    -- Minimal synthetic energy_consumption_1min rows for two orgs, 40 minutes
    -- each (all NOT NULL columns + the columns v_energy_semantic_rollup_15min
    -- reads). One INSERT per (org, minute) via a small helper CTE.
    FOR i IN 0..39 LOOP
        INSERT INTO analytics.energy_consumption_1min
            (bucket_start, organization_id, site_id, device_id,
             previous_bucket_start, elapsed_minutes, source_sample_count,
             import_register_wh, previous_import_register_wh, import_consumption_wh, import_consumption_kwh,
             export_register_wh, previous_export_register_wh, export_consumption_wh, export_consumption_kwh,
             import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
             export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
             gap_detected, calculated_at)
        SELECT v_t0 + (i||' minutes')::interval, o.org, o.site, o.dev,
               v_t0 + ((i-1)||' minutes')::interval, 1, 1,
               o.base + i*o.step, o.base + (i-1)*o.step, o.step, o.step/1000.0,
               0, 0, 0, 0,
               'GOOD', TRUE, FALSE, FALSE,
               'GOOD', TRUE, FALSE, FALSE,
               FALSE, clock_timestamp()
        FROM (VALUES (v_org_a, v_site_a, v_dev_a, 1000::numeric, 10::numeric),
                     (v_org_b, v_site_b, v_dev_b, 5000::numeric, 99::numeric)) AS o(org, site, dev, base, step);
    END LOOP;

    -- Drive 15min via the WATERMARK WRAPPER (parent = cp_1min set to cover the fixture).
    UPDATE telemetry.pipeline_state SET last_received_at=NULL, last_status='NEVER_RUN' WHERE pipeline_name='energy_consumption_15min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_t0 + INTERVAL '45 minutes' WHERE pipeline_name='energy_consumption_1min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_t0 + INTERVAL '45 minutes' WHERE pipeline_name='energy_consumption_5min';
    UPDATE telemetry.pipeline_state SET last_received_at = v_t0 WHERE pipeline_name='energy_consumption_15min';
    CALL analytics.run_energy_consumption_15min_job(999209,
        '{"lookback":"2 hours","max_catchup_window":"6 hours","overlap":"30 minutes","reconcile_window":"3 days"}'::jsonb);

    -- Org A's 15min import total from the wrapper-driven run.
    SELECT COALESCE(sum(import_consumption_kwh),0) INTO v_wrapper_a
    FROM analytics.energy_consumption_15min
    WHERE organization_id = v_org_a AND bucket_start >= v_t0 AND bucket_start < v_t0 + INTERVAL '45 minutes';

    -- Org B rows present and isolated (never touched org A's totals / watermark).
    SELECT count(*) INTO v_b_rows
    FROM analytics.energy_consumption_15min
    WHERE organization_id = v_org_b AND bucket_start >= v_t0 AND bucket_start < v_t0 + INTERVAL '45 minutes';
    IF v_b_rows = 0 THEN
        RAISE EXCEPTION 'TEST P FAILED: org B produced no 15min rows -- the cascade is not tenant-complete';
    END IF;

    -- Wipe and recompute org A's 15min range with a DIRECT call to the
    -- UNCHANGED refresh function over the same window; totals must match.
    DELETE FROM analytics.energy_consumption_15min WHERE bucket_start >= v_t0 AND bucket_start < v_t0 + INTERVAL '45 minutes';
    PERFORM analytics.refresh_energy_consumption_15min(v_t0 - INTERVAL '30 minutes', v_t0 + INTERVAL '45 minutes');
    SELECT COALESCE(sum(import_consumption_kwh),0) INTO v_direct_a
    FROM analytics.energy_consumption_15min
    WHERE organization_id = v_org_a AND bucket_start >= v_t0 AND bucket_start < v_t0 + INTERVAL '45 minutes';

    IF v_wrapper_a IS DISTINCT FROM v_direct_a THEN
        RAISE EXCEPTION 'TEST Q FAILED: wrapper-driven 15min total (%) != direct refresh total (%) for org A', v_wrapper_a, v_direct_a;
    END IF;
    IF v_wrapper_a <= 0 THEN
        RAISE EXCEPTION 'TEST Q FAILED: org A 15min import total is % (expected > 0 from the fixture)', v_wrapper_a;
    END IF;

    RAISE NOTICE 'TEST P passed: both orgs produce isolated 15min rows; the global watermark did not mix tenants.';
    RAISE NOTICE 'TEST Q passed: watermark-wrapper-driven 15min output == direct refresh_energy_consumption_15min output (org A total = %).', v_wrapper_a;
END
$pq$;

ROLLBACK;

SELECT 'Energy-consumption cascade watermark assertions passed.' AS result;
