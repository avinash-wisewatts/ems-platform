-- ============================================================================
-- Migration 197
-- Phase 1E-B — historical backfill orchestration for per-flow energy
-- quality columns
--
-- Introduces exactly one new object: analytics.backfill_energy_
-- consumption_per_flow_quality(p_from, p_to, p_batch_interval). It
-- contains NO new calculation or classification logic. It only loops
-- over historical time batches and calls the three existing, unmodified
-- Phase 1E-A refresh functions (refresh_energy_consumption_15min/hourly/
-- daily) in the required dependency order (15min -> hourly -> daily) for
-- each batch, exactly as they already run in production on a schedule.
--
-- Reconstructability (see Audit/EMS Analytics Platform — Phase 1E-B
-- Implementation Plan.txt for the full analysis, corrected after review):
-- the only permanent limit is per-flow data for a bucket whose native
-- source (energy_consumption_1min/5min) has already been deleted by its
-- own retention policy at the time this procedure runs. This is NOT an
-- additional, independent limit on hourly/daily beyond 15-minute's own
-- retention -- once a 15-minute row's per-flow columns are populated
-- (by this backfill or by ongoing real-time operation), that information
-- is part of the row and hourly/daily derive from it exactly as they
-- already do for any other 15-minute data, independent of native's or
-- 15-minute's own subsequent expiration.
--
-- Because refresh_energy_consumption_15min/hourly/daily are each
-- INSERT ... SELECT ... ON CONFLICT DO UPDATE, a batch whose source
-- returns no rows (native fully expired, or -- for hourly/daily -- the
-- 15-minute tier not yet per-flow-populated for that window) is a safe
-- no-op: any existing row is left completely untouched, and its per-flow
-- columns correctly remain NULL ("cannot reconstruct"), never zeroed.
--
-- Each batch runs its three calls inside one sub-transaction (a PL/pgSQL
-- exception block, which is a savepoint): a failure part-way through a
-- batch rolls back only that batch, is logged via RAISE WARNING, and the
-- loop proceeds to the next batch. The whole operation is idempotent and
-- safely resumable by simply re-invoking it with the same (or a
-- superset) range -- already-correct rows recompute to identical values;
-- unreconstructable rows remain a no-op.
--
-- This migration does not invoke the procedure. Actually running a
-- backfill against staging or production is a separate, explicitly
-- approved operational step (see the Implementation Plan, §11), never
-- automatic as part of deployment.
-- ============================================================================


CREATE OR REPLACE FUNCTION analytics.backfill_energy_consumption_per_flow_quality(
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ,
    p_batch_interval INTERVAL DEFAULT INTERVAL '7 days'
)
RETURNS TABLE
(
    batch_start TIMESTAMPTZ,
    batch_end   TIMESTAMPTZ,
    rows_15min  BIGINT,
    rows_hourly BIGINT,
    rows_daily  BIGINT,
    batch_error TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_batch_start TIMESTAMPTZ;
    v_batch_end   TIMESTAMPTZ;
    v_rows_15min  BIGINT;
    v_rows_hourly BIGINT;
    v_rows_daily  BIGINT;
    v_error       TEXT;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'p_from and p_to are required';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION 'p_to (%) must be later than p_from (%)', p_to, p_from;
    END IF;

    IF p_batch_interval IS NULL OR p_batch_interval <= INTERVAL '0' THEN
        RAISE EXCEPTION 'p_batch_interval must be a positive interval';
    END IF;

    v_batch_start := p_from;

    WHILE v_batch_start < p_to LOOP
        v_batch_end   := LEAST(v_batch_start + p_batch_interval, p_to);
        v_rows_15min  := NULL;
        v_rows_hourly := NULL;
        v_rows_daily  := NULL;
        v_error       := NULL;

        BEGIN
            -- Strict dependency order: 15-minute must complete before
            -- hourly/daily are attempted for the same window, since both
            -- read exclusively from analytics.energy_consumption_15min.
            v_rows_15min  := analytics.refresh_energy_consumption_15min(v_batch_start, v_batch_end);
            v_rows_hourly := analytics.refresh_energy_consumption_hourly(v_batch_start, v_batch_end);
            v_rows_daily  := analytics.refresh_energy_consumption_daily(v_batch_start, v_batch_end);

            RAISE NOTICE
                'Phase 1E-B backfill batch [%, %): 15min=%, hourly=%, daily=%',
                v_batch_start, v_batch_end, v_rows_15min, v_rows_hourly, v_rows_daily;

        EXCEPTION WHEN OTHERS THEN
            v_error := SQLERRM;
            RAISE WARNING
                'Phase 1E-B backfill batch [%, %) failed and was skipped: %',
                v_batch_start, v_batch_end, v_error;
        END;

        batch_start := v_batch_start;
        batch_end   := v_batch_end;
        rows_15min  := v_rows_15min;
        rows_hourly := v_rows_hourly;
        rows_daily  := v_rows_daily;
        batch_error := v_error;
        RETURN NEXT;

        v_batch_start := v_batch_end;
    END LOOP;

    RETURN;
END;
$function$;


COMMENT ON FUNCTION analytics.backfill_energy_consumption_per_flow_quality(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL) IS
'Phase 1E-B: batched orchestration that re-invokes the existing, unmodified analytics.refresh_energy_consumption_15min/hourly/daily() over a historical range, in dependency order, to populate the per-flow quality columns Phase 1E-A added. Contains no new calculation logic. Idempotent and safely resumable by re-invocation. A batch whose source has no surviving data is a safe no-op, correctly leaving per-flow columns NULL rather than zeroed. Not invoked automatically by any migration or deployment step.';


ALTER FUNCTION analytics.backfill_energy_consumption_per_flow_quality(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.backfill_energy_consumption_per_flow_quality(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION analytics.backfill_energy_consumption_per_flow_quality(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL)
TO ems_admin;

-- Internal operational tool only, matching the grant posture of the
-- refresh functions it calls. Never exposed to grafana_reader/ems_app.
