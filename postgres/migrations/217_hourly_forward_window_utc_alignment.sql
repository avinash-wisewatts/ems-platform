-- ============================================================================
-- Migration 217 -- Hourly forward-window UTC-hour alignment.
--
-- WHAT
--   CREATE OR REPLACE analytics.run_energy_consumption_hourly_job with its
--   EXACT migration-209 body, changing ONLY the window derivation so that
--   v_parent, v_from, v_to and the stored forward checkpoint
--   (telemetry.pipeline_state('energy_consumption_hourly').last_received_at)
--   are always whole UTC-hour boundaries -- the SAME grid that
--   analytics.refresh_energy_consumption_hourly bins on:
--       date_bin('1 hour', <ts>, TIMESTAMPTZ '2000-01-01 00:00:00+00')
--   Plus a one-row, idempotent, floor-DOWN normalization of the already-
--   deployed checkpoint so the first post-217 run already has a UTC-hour-
--   aligned v_start.
--
-- WHY
--   Migration 209 set  v_now_binned := date_trunc('hour', clock_timestamp()).
--   date_trunc truncates in the bgworker session TimeZone (Asia/Kolkata on
--   staging) -> an HH:00 IST boundary, which is permanently 30 minutes out of
--   phase with the UTC hourly grid used by refresh_energy_consumption_hourly's
--   date_bin('1 hour', s.bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00')
--   (HH:00 UTC = HH:30 IST). Because v_from = v_start - overlap inherits that
--   offset, every effective run's window left-edge bisects an hourly bucket;
--   refresh_energy_consumption_hourly SUMs only the 15-minute rows inside
--   [p_from, p_to) and does ON CONFLICT DO UPDATE SET col = EXCLUDED.col
--   (replace, not accumulate), so the bisected bucket is overwritten with a
--   partial (~half) aggregate. The checkpoint only moves forward, so later
--   runs never re-cover that bucket; only the migration-213 hourly reconcile
--   repairs it, at n_max=6 coarse hours / 12 h -- below the ~24 hours/day the
--   forward job corrupts -> a permanently non-converging deficit
--   (analytics.v_pipeline_health: forward=OK, reconcile=BACKLOGGED,
--   integrity=PERSISTENT_DEFICIT).
--
-- THE FOUR EXPRESSION EDITS (every other line of the 209 body is verbatim)
--   1. v_parent     : floored to the UTC hour  -> an hour is only built once
--                     its 15-minute source tier has fully passed it.
--   2. v_now_binned : date_bin('1 hour', clock_timestamp(), <utc origin>)
--                     = start of the CURRENT UTC hour. refresh uses
--                     "s.bucket_start < p_to", so the in-progress hour is
--                     excluded and the job processes the LAST COMPLETED hour.
--   3. v_to         : floored defensively after the LEAST() so alignment does
--                     not depend on reasoning about (v_start + v_max_catchup).
--   4. v_from       : floored defensively after (v_start - v_overlap).
--   date_bin(..., TIMESTAMPTZ '2000-01-01 00:00:00+00') operates on the
--   absolute instant and is INDEPENDENT of the session TimeZone -- unlike the
--   209 date_trunc. This removes a latent session-TZ / DST-onboarding hazard.
--
-- CHECKPOINT NORMALIZATION (one row, floor DOWN only)
--   The deployed last_received_at sits on an IST-hour boundary (= :30 UTC).
--   Floor it DOWN to the UTC hour: at worst the next forward run re-processes
--   one whole hour it already covered (idempotent under the migration-216
--   value-aware calculated_at upsert); flooring UP could skip an unprocessed
--   hour. Guarded so it is a no-op wherever the checkpoint is already aligned.
--
-- WHAT IS PRESERVED (verbatim from migration 209 / 208)
--   * advisory-lock / SKIPPED_LOCKED / RUNNING / FAILED+RAISE scaffolding and
--     the shared key hashtextextended(
--       'analytics.run_energy_consumption_hourly_job', 0)
--     (so the forward job and the migration-213 reconcile never overlap);
--   * SELECT last_received_at ... FOR UPDATE checkpoint read;
--   * v_parent sourced from the energy_consumption_15min forward checkpoint,
--     the (v_parent IS NULL OR v_to IS NULL OR v_to <= v_start) guard and its
--     SUCCESS-vs-NO_SOURCE_DATA status semantics;
--   * lookback / max_catchup_window / overlap config keys (defaults
--     2 days / 2 days / 2 hours) and the positivity check;
--   * the single call analytics.refresh_energy_consumption_hourly(v_from, v_to)
--     -- that function is NOT modified; v_rows = ROW_COUNT; last_status =
--     CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS';
--   * SECURITY DEFINER, SET search_path, owner ems_admin and EXECUTE grants
--     (CREATE OR REPLACE keeps owner + ACLs), single transaction, no COMMIT.
--
-- NOT TOUCHED
--   analytics.refresh_energy_consumption_hourly (migration 216); any
--   reconcile_* object or reconcile job (213); analytics.v_pipeline_health
--   (214); the hourly job's schedule / max_runtime / max_retries / config /
--   check_config; every other run_*_job wrapper (15min / 5min / 1min / daily /
--   demand / environment_daily); analytics.energy_consumption_hourly schema /
--   hypertable / indexes / retention / compression; telemetry.pipeline_state
--   schema; any CAGG or CAGG policy; Grafana / reporting objects
--   (analytics.v_energy_reporting_hourly reads v_energy_reporting_15min, not
--   this table); application / API code; normalization; routing. NO historical
--   data repair -- the existing partial hourly rows are left as-is for a
--   separate, explicitly-authorised operator step.
-- ============================================================================

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_hourly_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name    CONSTANT TEXT := 'energy_consumption_hourly';
    v_lookback         INTERVAL := INTERVAL '2 days';
    v_max_catchup      INTERVAL := INTERVAL '2 days';
    v_overlap          INTERVAL := INTERVAL '2 hours';
    v_ckpt             TIMESTAMPTZ;
    v_parent           TIMESTAMPTZ;
    v_now_binned       TIMESTAMPTZ;
    v_start            TIMESTAMPTZ;
    v_to               TIMESTAMPTZ;
    v_from             TIMESTAMPTZ;
    v_rows             BIGINT := 0;
    v_lock_acquired    BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'hourly energy consumption config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)', v_lookback, v_max_catchup, v_overlap;
    END IF;

    v_lock_acquired := pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- ------------------------------------------------------------------------
    -- Migration 217: derive the window on the SAME UTC hourly grid the
    -- materialization (analytics.refresh_energy_consumption_hourly) bins on.
    -- date_bin(..., TIMESTAMPTZ '2000-01-01 00:00:00+00') is an absolute-
    -- instant operation, independent of the session TimeZone -- unlike the
    -- migration-209 date_trunc('hour', clock_timestamp()), which truncated in
    -- Asia/Kolkata and was 30 min out of phase with the UTC grid.
    --
    --   v_parent     : the 15-minute forward checkpoint, FLOORED to the UTC
    --                  hour -> the hourly job will not build hour [h, h+1h)
    --                  until the 15-minute tier has fully passed h+1h (no
    --                  partial-child aggregation).
    --   v_now_binned : start of the CURRENT UTC hour -> refresh's
    --                  "s.bucket_start < p_to" excludes the in-progress hour;
    --                  the job processes the LAST COMPLETED UTC hour.
    --   v_to / v_from: floored defensively so alignment holds regardless of
    --                  the (v_start + v_max_catchup) term or a legacy
    --                  off-grid v_ckpt.
    -- ------------------------------------------------------------------------
    v_parent := date_bin(
        INTERVAL '1 hour',
        (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_15min'),
        TIMESTAMPTZ '2000-01-01 00:00:00+00'
    );
    v_now_binned := date_bin(INTERVAL '1 hour', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);
    v_to         := date_bin(INTERVAL '1 hour', v_to, TIMESTAMPTZ '2000-01-01 00:00:00+00');

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := date_bin(INTERVAL '1 hour', v_start - v_overlap, TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_rows := analytics.refresh_energy_consumption_hourly(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
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

COMMENT ON PROCEDURE analytics.run_energy_consumption_hourly_job(integer, jsonb) IS
'Migration 217: derives the forward window on the UTC hourly grid date_bin(''1 hour'', <ts>, TIMESTAMPTZ ''2000-01-01 00:00:00+00'') -- the same grid analytics.refresh_energy_consumption_hourly bins on -- so v_from, v_to and telemetry.pipeline_state(''energy_consumption_hourly'').last_received_at are always whole UTC-hour boundaries and refresh is never called with a partial-hour range. Replaces the migration-209 date_trunc(''hour'', clock_timestamp()), which truncated in the session TimeZone and was 30 min out of phase with the UTC grid, causing every effective run to left-clip one hourly bucket into a ~half aggregate. Processes the last COMPLETED UTC hour; the in-progress hour is excluded. All other migration-209/208 semantics (advisory lock + shared key, checkpoint FOR UPDATE, v_parent from the 15-minute checkpoint [now floored], guard + status, single call to the unchanged analytics.refresh_energy_consumption_hourly, FAILED+RAISE) are preserved verbatim.';

-- ----------------------------------------------------------------------------
-- One-time, idempotent, floor-DOWN normalization of the already-deployed
-- checkpoint so the FIRST post-217 run already has a UTC-hour-aligned v_start.
-- Floor DOWN, never up: at worst the next forward run re-processes one whole
-- hour it already covered (idempotent under the migration-216 value-aware
-- calculated_at upsert); flooring up could skip an unprocessed hour. No-op
-- wherever last_received_at is already UTC-hour aligned or still NULL.
-- ----------------------------------------------------------------------------
UPDATE telemetry.pipeline_state
SET    last_received_at = date_bin(INTERVAL '1 hour', last_received_at, TIMESTAMPTZ '2000-01-01 00:00:00+00'),
       updated_at       = now()
WHERE  pipeline_name = 'energy_consumption_hourly'
  AND  last_received_at IS NOT NULL
  AND  last_received_at <> date_bin(INTERVAL '1 hour', last_received_at, TIMESTAMPTZ '2000-01-01 00:00:00+00');
