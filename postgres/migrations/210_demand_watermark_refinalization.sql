-- ============================================================================
-- Migration 210
-- Phase 2 Foundation, Phase 1 (2/4): demand watermark + status-guarded demand
-- re-finalization.
--
-- Root cause (Migration 210 Pre-Implementation Audit): analytics.demand_intervals
-- is finalized WRITE-ONCE (INSERT ... ON CONFLICT DO NOTHING). A 15-minute
-- interval finalized NO_DATA / INCOMPLETE while upstream energy_measurements /
-- normalized_points was stalled is never reconsidered, even after real source
-- data later arrives; and analytics.run_demand_calculation_job scans a fixed
-- now()-3h window every minute (nothing older than 3h is revisited at all).
--
-- This migration:
--
--   1. analytics.refresh_demand_analytics gains two optional parameters
--        p_finalize_from timestamptz DEFAULT NULL,
--        p_finalize_to   timestamptz DEFAULT NULL
--      that bound ONLY the historical finalization loop to an explicit
--      [v_win_from, v_win_to) window. NULL/NULL (every legacy two-argument
--      caller) reproduces the pre-210 window exactly -- (p_now - p_lookback,
--      p_now]. The live analytics.demand_state block is UNCHANGED and stays
--      keyed to p_now, so a bounded historical catch-up can never turn into
--      repeated accumulation in demand_state. calculate_demand_window() and
--      resolve_demand_interval() are NOT touched -- the demand mathematics and
--      quality rules are byte-for-byte unchanged. (CREATE OR REPLACE does not
--      replace a procedure of a different arity, so the two-argument signature
--      is DROPped first -- migration-205 pattern.)
--
--   2. The finalization write changes from a single INSERT ... ON CONFLICT DO
--      NOTHING to a scope-branched status-guarded upsert -- because
--      demand_intervals carries TWO partial unique indexes
--      (uq_demand_intervals_site_scope WHERE scope_type='SITE';
--       uq_demand_intervals_asset_scope WHERE scope_type='ASSET'), an
--      unqualified ON CONFLICT cannot pick the arbiter. Per scope:
--        INSERT ... ON CONFLICT (<site_id|asset_id>, interval_start,
--                                demand_policy_id) WHERE scope_type = '<SCOPE>'
--        DO UPDATE SET <all computed columns>, finalized_at = clock_timestamp()
--        WHERE analytics.demand_intervals.quality_status <> 'VALID'
--          AND ( quality_status | demand_kw | demand_kva | coverage_percent |
--                observed_observations  IS DISTINCT FROM the persisted value )
--      => a finalized VALID interval is FROZEN (never downgraded / rewritten);
--         a NO_DATA / INCOMPLETE / INVALID_SOURCE / INSUFFICIENT_SOURCE_RESOLUTION
--         row is replaced when calculate_demand_window now yields a materially
--         different result (NO_DATA -> INCOMPLETE / VALID, INCOMPLETE -> VALID,
--         strictly per the existing coverage-vs-minimum_coverage_percent rule);
--         an unchanged result writes nothing, so finalized_at does not churn.
--
--   3. analytics.run_demand_calculation_job becomes watermark-driven, using the
--      exact bounded-catch-up pattern established by migration 209 and the
--      audited demand parent-availability semantics:
--        v_ckpt   := pipeline_state('demand_intervals').last_received_at   (FOR UPDATE)
--        v_grace  := max(config.site_demand_policies.late_arrival_tolerance_seconds
--                        WHERE is_enabled) + 300s          (<= 3900s by the CHECK)
--        v_parent := LEAST( max(telemetry.energy_measurements.bucket_start),
--                           max(telemetry.normalized_points.event_time) )
--                    -- the actual closed-bucket source frontier; NOT a routing
--                    -- pipeline_state watermark (that is ingest time).
--        v_start  := COALESCE(v_ckpt, clock_timestamp() - v_lookback)   -- lookback = FIRST-RUN FLOOR only
--        v_to     := date_bin('15 minutes',
--                      LEAST(clock_timestamp() - v_grace, v_parent, v_start + v_max_catchup_window),
--                      '2000-01-01 00:00:00+00')
--        IF v_parent IS NULL OR v_to <= v_start: NO_SOURCE_DATA, DO NOT advance, RETURN.
--        v_from   := v_start - v_overlap
--        CALL analytics.refresh_demand_analytics(clock_timestamp(), v_lookback, v_from, v_to);
--        -- on success, LAST write of the single transaction:
--        pipeline_state('demand_intervals').last_received_at := v_to
--        -- EXCEPTION WHEN OTHERS -> FAILED -> RAISE  => the TimescaleDB job
--        --   runner aborts the whole job transaction (the advance, every
--        --   demand_intervals write, RUNNING and FAILED all roll back), so a
--        --   failed / cancelled / timed-out run leaves last_received_at exactly
--        --   at its pre-run value. Retry reprocesses the identical window.
--      The v_grace clamp prevents the checkpoint from leaping over the finalize
--      loop's own grace-skipped region (which would leave a permanent hole
--      below the watermark). Buckets in (v_to, now) are finalized on a later
--      run once they age past the grace. parent_available_through is an INPUT
--      only -- it is never written into the child checkpoint.
--
--   4. Job config gains "max_catchup_window" (6 hours), "overlap" (30 minutes),
--      and "reconcile_window" (6 hours). reconcile_window is stored now and
--      consumed by migration 212 only (this migration adds NO reconciliation
--      framework, no pipeline_reconciliation_log, no v_pipeline_health).
--      "lookback" (3 hours, now the first-run floor), schedule_interval (1m),
--      max_runtime (10m), max_retries (3), retry_period (5m), and the
--      migration-208 check_config validator are UNCHANGED. The
--      migration-208 advisory-lock / SKIPPED_LOCKED / RUNNING / FAILED
--      scaffolding on the wrapper is preserved verbatim, as are SECURITY
--      INVOKER / search_path / owner ems_admin.
--
-- NOT touched: analytics.calculate_demand_window, analytics.resolve_demand_interval,
-- analytics.resolve_demand_capability, the live demand_state block and its two
-- DELETE statements, the demand_state / demand_intervals schemas, demand quality
-- rules, tenant isolation, demand interval grain, any CAGG / retention /
-- compression / Grafana object / job schedule / cadence.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1 + 2. refresh_demand_analytics: parameterised finalization window +
--        scope-branched status-guarded upsert. (Body generated by transforming
--        the deployed definition with the six audited mechanical edits
--        [audit M1 (i)-(vi)]: (i) v_win_from/v_win_to derivation; (ii) v_max_n
--        from the window; (iii) loop step anchor v_win_to; (iv) EXIT bound
--        v_win_from; (v) defensive CONTINUE WHEN interval_start IS NULL;
--        (vi) the IF SITE / ELSE ASSET status-guarded upsert. Everything else
--        is reproduced verbatim from the deployed definition. Line-level delta
--        vs. the deployed body: +88 / -10 lines.)
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.refresh_demand_analytics(timestamptz, interval);

CREATE OR REPLACE PROCEDURE analytics.refresh_demand_analytics(IN p_now timestamp with time zone DEFAULT clock_timestamp(), IN p_lookback interval DEFAULT '03:00:00'::interval, IN p_finalize_from timestamp with time zone DEFAULT NULL, IN p_finalize_to timestamp with time zone DEFAULT NULL)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'analytics', 'config', 'metadata'
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
    v_win_from TIMESTAMPTZ;
    v_win_to TIMESTAMPTZ;
BEGIN
    IF p_lookback IS NULL OR p_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_lookback must be positive.';
    END IF;

    -- Migration 210: the historical finalization loop below operates over
    -- an explicit [v_win_from, v_win_to) window. p_finalize_from /
    -- p_finalize_to = NULL (every legacy two-argument caller) reproduce
    -- the pre-210 window exactly: (p_now - p_lookback, p_now]. The live
    -- analytics.demand_state block below is UNCHANGED and always keyed to
    -- p_now, so a bounded historical catch-up can never push a historical
    -- interval into demand_state.
    v_win_from := COALESCE(p_finalize_from, p_now - p_lookback);
    v_win_to   := COALESCE(p_finalize_to,   p_now);

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
                extract(epoch FROM (v_win_to - v_win_from)) / v_policy.demand_interval_seconds
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

            -- Finalized historical intervals. Five-minute processing grace remains
            -- separate from the policy late-arrival allowance.
            FOR v_n IN 1..v_max_n LOOP
                SELECT * INTO v_interval
                FROM analytics.resolve_demand_interval(
                    v_site.site_id,
                    v_policy.demand_interval_seconds,
                    v_win_to - make_interval(secs => v_n*v_policy.demand_interval_seconds)
                );

                CONTINUE WHEN v_interval.interval_start IS NULL;
                EXIT WHEN v_interval.interval_end <= v_win_from;

                IF v_interval.interval_start < v_policy.effective_from THEN
                    CONTINUE;
                END IF;
                IF v_policy.effective_to IS NOT NULL
                   AND v_interval.interval_end > v_policy.effective_to THEN
                    CONTINUE;
                END IF;
                IF v_interval.interval_end
                   + make_interval(secs => COALESCE(v_policy.late_arrival_tolerance_seconds,0))
                   + INTERVAL '5 minutes' > p_now THEN
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

                -- Migration 210: status-guarded re-finalization. demand_intervals
                -- has two PARTIAL unique indexes (SITE / ASSET), so the upsert
                -- names the matching arbiter per scope. A finalized VALID row is
                -- NEVER rewritten; a NO_DATA / INCOMPLETE / other non-VALID row
                -- is replaced only when calculate_demand_window (rules UNCHANGED)
                -- now yields a materially different result -- so a later-arriving
                -- valid source promotes NO_DATA/INCOMPLETE -> VALID (or improves
                -- an INCOMPLETE strictly per the existing coverage rule) without
                -- churning finalized_at on stable rows.
                IF v_scope.scope_type = 'SITE' THEN
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
                    ON CONFLICT (site_id,interval_start,demand_policy_id) WHERE scope_type = 'SITE'
                    DO UPDATE SET
                        organization_id=EXCLUDED.organization_id,
                        source_device_id=EXCLUDED.source_device_id,
                        demand_kw=EXCLUDED.demand_kw,
                        demand_kva=EXCLUDED.demand_kva,
                        peak_power_kw=EXCLUDED.peak_power_kw,
                        energy_kwh=EXCLUDED.energy_kwh,
                        source_method=EXCLUDED.source_method,
                        expected_observations=EXCLUDED.expected_observations,
                        observed_observations=EXCLUDED.observed_observations,
                        coverage_percent=EXCLUDED.coverage_percent,
                        quality_status=EXCLUDED.quality_status,
                        finalized_at=clock_timestamp()
                    WHERE analytics.demand_intervals.quality_status <> 'VALID'
                      AND (   EXCLUDED.quality_status        IS DISTINCT FROM analytics.demand_intervals.quality_status
                           OR EXCLUDED.demand_kw             IS DISTINCT FROM analytics.demand_intervals.demand_kw
                           OR EXCLUDED.demand_kva            IS DISTINCT FROM analytics.demand_intervals.demand_kva
                           OR EXCLUDED.coverage_percent      IS DISTINCT FROM analytics.demand_intervals.coverage_percent
                           OR EXCLUDED.observed_observations IS DISTINCT FROM analytics.demand_intervals.observed_observations );
                ELSE
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
                    ON CONFLICT (asset_id,interval_start,demand_policy_id) WHERE scope_type = 'ASSET'
                    DO UPDATE SET
                        organization_id=EXCLUDED.organization_id,
                        source_device_id=EXCLUDED.source_device_id,
                        demand_kw=EXCLUDED.demand_kw,
                        demand_kva=EXCLUDED.demand_kva,
                        peak_power_kw=EXCLUDED.peak_power_kw,
                        energy_kwh=EXCLUDED.energy_kwh,
                        source_method=EXCLUDED.source_method,
                        expected_observations=EXCLUDED.expected_observations,
                        observed_observations=EXCLUDED.observed_observations,
                        coverage_percent=EXCLUDED.coverage_percent,
                        quality_status=EXCLUDED.quality_status,
                        finalized_at=clock_timestamp()
                    WHERE analytics.demand_intervals.quality_status <> 'VALID'
                      AND (   EXCLUDED.quality_status        IS DISTINCT FROM analytics.demand_intervals.quality_status
                           OR EXCLUDED.demand_kw             IS DISTINCT FROM analytics.demand_intervals.demand_kw
                           OR EXCLUDED.demand_kva            IS DISTINCT FROM analytics.demand_intervals.demand_kva
                           OR EXCLUDED.coverage_percent      IS DISTINCT FROM analytics.demand_intervals.coverage_percent
                           OR EXCLUDED.observed_observations IS DISTINCT FROM analytics.demand_intervals.observed_observations );
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$procedure$;

ALTER PROCEDURE analytics.refresh_demand_analytics(timestamptz, interval, timestamptz, timestamptz) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.refresh_demand_analytics(timestamptz, interval, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE analytics.refresh_demand_analytics(timestamptz, interval, timestamptz, timestamptz) TO ems_admin;

COMMENT ON PROCEDURE analytics.refresh_demand_analytics(timestamptz, interval, timestamptz, timestamptz) IS
'Refreshes provisional current demand state (analytics.demand_state, keyed to p_now -- UNCHANGED) and finalizes closed demand intervals (analytics.demand_intervals). '
'Migration 210: the finalization loop operates over an explicit [COALESCE(p_finalize_from, p_now - p_lookback), COALESCE(p_finalize_to, p_now)) window -- NULL/NULL preserves the exact pre-210 behaviour for every two-argument caller. The finalization write is now a scope-branched status-guarded upsert: ON CONFLICT (<site_id|asset_id>, interval_start, demand_policy_id) WHERE scope_type=''SITE''|''ASSET'' DO UPDATE ... WHERE demand_intervals.quality_status <> ''VALID'' AND (materially-changed) -- a finalized VALID interval is immutable; a non-VALID interval is re-finalized when calculate_demand_window (rules unchanged) now yields a different result. calculate_demand_window() and resolve_demand_interval() are unchanged; the live demand_state block and its two DELETEs are unchanged. Intended to be driven by analytics.run_demand_calculation_job''s bounded child watermark; also safely re-invocable by a later bounded trailing reconciliation over a historical [from, to) window WITHOUT moving that watermark.';

-- ----------------------------------------------------------------------------
-- 3. run_demand_calculation_job: bounded watermark-driven wrapper (migration-209
--    pattern). Migration-208 advisory-lock / status scaffolding preserved.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.run_demand_calculation_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'demand_intervals';
    v_lookback      INTERVAL := INTERVAL '3 hours';       -- FIRST-RUN FLOOR only
    v_max_catchup   INTERVAL := INTERVAL '6 hours';
    v_overlap       INTERVAL := INTERVAL '30 minutes';
    v_grace         INTERVAL;
    v_ckpt          TIMESTAMPTZ;
    v_parent        TIMESTAMPTZ;
    v_start         TIMESTAMPTZ;
    v_to            TIMESTAMPTZ;
    v_from          TIMESTAMPTZ;
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'demand config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)',
            v_lookback, v_max_catchup, v_overlap;
    END IF;

    -- Migration 208 self-overlap guard (verbatim).
    v_lock_acquired := pg_try_advisory_xact_lock(hashtextextended('analytics.run_demand_calculation_job', 0));
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Migration 210: bounded, watermark-driven historical finalization window.
    -- v_grace >= the finalize loop's own (late_arrival_tolerance + 5 minutes)
    -- grace, so no interval inside [v_from, v_to) is grace-skipped while the
    -- checkpoint advances past it (which would leave a permanent hole below the
    -- watermark). Bounded by the config.site_demand_policies CHECK (<= 3600s) + 300s.
    v_grace := make_interval(secs => COALESCE(
        (SELECT max(late_arrival_tolerance_seconds)
         FROM config.site_demand_policies WHERE is_enabled), 0) + 300);

    -- Parent availability = the actual closed-bucket source-data frontier
    -- (audited). NOT a routing pipeline_state watermark (that is ingest time).
    v_parent := LEAST(
        (SELECT max(bucket_start) FROM telemetry.energy_measurements),
        (SELECT max(event_time)   FROM telemetry.normalized_points)
    );

    v_start := COALESCE(v_ckpt, clock_timestamp() - v_lookback);
    v_to    := date_bin(INTERVAL '15 minutes',
                 LEAST(clock_timestamp() - v_grace, v_parent, v_start + v_max_catchup),
                 TIMESTAMPTZ '2000-01-01 00:00:00+00');

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := v_start - v_overlap;

    -- p_now = clock_timestamp() keeps the LIVE demand_state block current
    -- (never historical); p_finalize_from / p_finalize_to bound ONLY the
    -- historical demand_intervals finalization loop.
    CALL analytics.refresh_demand_analytics(clock_timestamp(), v_lookback, v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = 0,
        last_status        = 'SUCCESS',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

ALTER PROCEDURE analytics.run_demand_calculation_job(integer, jsonb) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.run_demand_calculation_job(integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE analytics.run_demand_calculation_job(integer, jsonb) TO ems_admin;

COMMENT ON PROCEDURE analytics.run_demand_calculation_job(integer, jsonb) IS
'TimescaleDB background action for demand. Migration 210: watermark-driven. Reads pipeline_state(''demand_intervals'').last_received_at (FOR UPDATE), derives parent_available_through = LEAST(max(energy_measurements.bucket_start), max(normalized_points.event_time)), and CALLs analytics.refresh_demand_analytics(clock_timestamp(), lookback, v_from, v_to) with v_to = date_bin(''15 minutes'', LEAST(now - grace, parent_available_through, checkpoint + max_catchup_window)) and v_from = checkpoint - overlap. Advances last_received_at = v_to ONLY as the last write of the successful single transaction; any failure / cancel / timeout rolls the whole run back and leaves the checkpoint unchanged. lookback is the first-run floor only. The migration-208 advisory lock (-> SKIPPED_LOCKED) is preserved. The live demand_state path (inside refresh_demand_analytics, keyed to clock_timestamp()) is unaffected.';

-- ----------------------------------------------------------------------------
-- 4. pipeline_state row (already created by migration 208; idempotent).
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name)
VALUES ('demand_intervals')
ON CONFLICT (pipeline_name) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 5. Job config: add the Phase-1 keys. lookback / schedule / runtime / retries
--    / check_config UNCHANGED. reconcile_window is consumed by migration 212.
-- ----------------------------------------------------------------------------
DO $cfg$
DECLARE
    v_job_id INTEGER;
BEGIN
    FOR v_job_id IN
        SELECT job_id FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'run_demand_calculation_job'
    LOOP
        PERFORM alter_job(
            v_job_id,
            config => (
                SELECT COALESCE(config, '{}'::jsonb)
                       || jsonb_build_object(
                            'max_catchup_window', '6 hours',
                            'overlap',            '30 minutes',
                            'reconcile_window',   '6 hours')
                FROM timescaledb_information.jobs WHERE job_id = v_job_id
            )
        );
        RAISE NOTICE 'Migration 210: job % (analytics.run_demand_calculation_job) config += max_catchup_window=6 hours, overlap=30 minutes, reconcile_window=6 hours',
            v_job_id;
    END LOOP;
END
$cfg$;

COMMIT;
