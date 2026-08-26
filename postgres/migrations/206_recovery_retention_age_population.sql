-- ============================================================================
-- Migration 206
-- Simplify telemetry.recover_failed_raw_messages()'s recoverability
-- classification: population selection now uses the telemetry.raw_messages
-- retention policy's own configured age directly, instead of probing
-- whether the raw row physically still exists.
--
-- Decision (2026-08-26): once telemetry.raw_message_failures.raw_received_at
-- is older than telemetry.raw_messages' own configured retention window, the
-- candidate is unrecoverable by definition. The retention-drop job
-- (policy_retention) runs on its own schedule (currently once/day) and can
-- lag behind the moment a given row's age actually crosses the retention
-- threshold. The previously deployed v_exists probe (migration 201/203/204's
-- "NOT EXISTS (SELECT 1 FROM telemetry.raw_messages ...)" check) let
-- candidates that are already provably beyond the retention window keep
-- re-entering job 1077's expensive per-candidate supersession/normalization
-- logic -- sometimes for days, across up to 5 replay attempts each -- for as
-- long as the daily retention sweep happened not to have reached them yet.
-- On staging this inflated the recoverable population from ~904 genuinely
-- recoverable candidates to ~1,964, the extra ~1,060 already provably
-- unrecoverable but still physically present (see the one-time
-- raw_message_failures cleanup performed the same day, and migration 205's
-- header for the stalled-normalization-watermark backlog that produced most
-- of it).
--
-- Fix: derive the retention cutoff dynamically from the deployed
-- policy_retention job for telemetry.raw_messages (never hard-coded), and
-- classify purely by age: raw_received_at < cutoff => PERMANENT_FAILURE
-- immediately, without running the supersession/normalization logic at all.
-- Candidates at or inside the cutoff are completely unaffected -- they still
-- flow through migration 204's supersession search, migration 202's targeted
-- normalized-points lookup, and migration 203's per-candidate COMMIT exactly
-- as deployed today.
--
--   SELECT (config->>'drop_after')::interval
--   FROM timescaledb_information.jobs
--   WHERE proc_schema='_timescaledb_functions'
--     AND proc_name='policy_retention'
--     AND hypertable_schema='telemetry'
--     AND hypertable_name='raw_messages';
--
-- proc_schema/proc_name are TimescaleDB's own stable identifiers for a
-- retention-drop job, unlike the human-editable application_name, so this
-- remains correct even if the policy is later dropped and re-added with a
-- different interval. If no such job exists, the procedure raises rather
-- than silently guessing a value.
--
-- This is a deliberate policy simplification, not a correctness fix: a
-- candidate whose raw row happens to still be physically present past its
-- own retention cutoff is not special-cased -- it is treated identically to
-- one already dropped. Age alone defines the recovery population.
--
-- Explicitly not touched: migration 204's supersession subquery (byte-for-
-- byte identical), migration 202's normalized_points_for_recovery_candidate()
-- call, migration 203's per-candidate COMMIT, p_limit, ORDER BY
-- raw_received_at, FOR UPDATE SKIP LOCKED, the initial attempt-count
-- increment, the RETRY_PENDING retry/backoff computation below the
-- supersession block, job 1077's schedule/config, and telemetry.
-- run_failed_message_recovery_job(). The only removed logic is the v_exists
-- probe itself, replaced one-for-one by the age comparison; no new branch is
-- added and no existing branch is removed beyond that substitution.
-- ============================================================================

BEGIN;

CREATE OR REPLACE PROCEDURE telemetry.recover_failed_raw_messages(IN p_limit integer DEFAULT 100)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    f RECORD;
    v_has_capture BOOLEAN;
    v_has_normalized BOOLEAN;
    v_retention_interval INTERVAL;
    v_retention_cutoff TIMESTAMPTZ;
BEGIN
    IF p_limit IS NULL OR p_limit<1 OR p_limit>1000 THEN
        RAISE EXCEPTION 'p_limit must be between 1 and 1000';
    END IF;

    -- Migration 206: read the actually-deployed retention policy dynamically
    -- rather than hard-coding its interval. proc_schema/proc_name are
    -- TimescaleDB's own stable identifiers for a retention-drop job, unlike
    -- the human-editable application_name, so this remains correct even if
    -- the policy is later dropped and re-added with a different interval.
    SELECT (config->>'drop_after')::interval
      INTO v_retention_interval
    FROM timescaledb_information.jobs
    WHERE proc_schema='_timescaledb_functions'
      AND proc_name='policy_retention'
      AND hypertable_schema='telemetry'
      AND hypertable_name='raw_messages';

    IF v_retention_interval IS NULL THEN
        RAISE EXCEPTION 'Could not determine telemetry.raw_messages retention policy: no policy_retention job found for telemetry.raw_messages';
    END IF;

    v_retention_cutoff:=clock_timestamp()-v_retention_interval;

    FOR f IN
        SELECT *
        FROM telemetry.raw_message_failures
        WHERE resolution_status IN ('OPEN','RETRY_PENDING')
          AND coalesce(next_replay_at,'-infinity'::timestamptz)<=clock_timestamp()
          AND replay_attempt_count<5
        ORDER BY raw_received_at
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    LOOP
        UPDATE telemetry.raw_message_failures
        SET replay_attempt_count=replay_attempt_count+1,last_replay_at=clock_timestamp(),
            resolution_status='RETRY_PENDING',last_replay_error=NULL
        WHERE raw_received_at=f.raw_received_at AND raw_message_id=f.raw_message_id;

        -- Migration 206: population selection is now purely age-based --
        -- retention age alone defines recoverability, deliberately without a
        -- raw_messages existence check (a row that happens to still be
        -- physically present past its own retention cutoff is not
        -- special-cased; it is treated identically to one already dropped).
        IF f.raw_received_at<v_retention_cutoff THEN
            UPDATE telemetry.raw_message_failures
            SET resolution_status='PERMANENT_FAILURE',
                next_replay_at=NULL,
                last_replay_error='raw_received_at ('||f.raw_received_at||') is older than the current telemetry.raw_messages retention window ('||v_retention_interval||'); payload is no longer recoverable.'
            WHERE raw_received_at=f.raw_received_at AND raw_message_id=f.raw_message_id;
            COMMIT;
            CONTINUE;
        END IF;

        -- Re-evaluate the exact raw packet. If its device sample is now already
        -- represented by a finalized capture bucket, recovery is complete by
        -- canonical supersession. Otherwise insert a selected capture row only
        -- when this packet is the latest eligible sample in its bucket.
        WITH current_elements AS MATERIALIZED
        (
            SELECT
                r.received_at,r.raw_message_id,COALESCE(r.source_timestamp,r.received_at) AS event_time,
                r.source_timestamp,d.id AS device_id,g.site_id,
                b.policy_id,b.capture_interval_seconds,b.late_arrival_tolerance_seconds,b.bucket_start,
                b.bucket_start+make_interval(secs=>b.capture_interval_seconds+b.late_arrival_tolerance_seconds) AS deadline
            FROM telemetry.v_rtdata r
            JOIN metadata.device_identifiers di
              ON di.identifier_type='MQTT_UID' AND lower(di.identifier_value)=lower(r.device_uid)
            JOIN metadata.devices d ON d.id=di.device_id
            JOIN metadata.gateways g ON g.id=d.gateway_id
            CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(g.site_id,COALESCE(r.source_timestamp,r.received_at)) b
            WHERE r.received_at=f.raw_received_at AND r.raw_message_id=f.raw_message_id
              AND d.profile_id IS NOT NULL AND b.policy_id IS NOT NULL
        )
        INSERT INTO telemetry.capture_bucket_samples
        (
            site_id,device_id,policy_id,bucket_start,capture_interval_seconds,
            late_arrival_tolerance_seconds,source_timestamp,event_time,
            raw_received_at,raw_message_id,status,last_error
        )
        SELECT ce.site_id,ce.device_id,ce.policy_id,ce.bucket_start,ce.capture_interval_seconds,
               ce.late_arrival_tolerance_seconds,ce.source_timestamp,ce.event_time,
               ce.received_at,ce.raw_message_id,'SELECTED',NULL
        FROM current_elements ce
        WHERE ce.deadline<=clock_timestamp()
          AND ce.received_at<=ce.deadline
          AND NOT EXISTS
          (
              -- Migration 204: targeted supersession search. Reads competing
              -- rows directly from telemetry.raw_messages, applying migration
              -- 201's receipt-time window (bucket_start..deadline) and the
              -- rtdata-is-array guard BEFORE any JSON expansion, instead of
              -- going through telemetry.v_rtdata (whose unfiltered
              -- expansion, joined against metadata.device_identifiers /
              -- metadata.devices / metadata.gateways via ordinary,
              -- hash-joinable INNER JOINs, is what let the planner build an
              -- effectively unbounded Hash Anti Join over history). Device
              -- identity is tested via lower(r2.value->>'uid') IN (SELECT
              -- lower(identifier_value) FROM metadata.device_identifiers
              -- WHERE identifier_type='MQTT_UID' AND device_id=ce.device_id)
              -- -- the direct SQL restatement of migration 203's original
              -- existential condition ("this UID resolves, via
              -- device_identifiers, to ce.device_id"), correct for a device
              -- with any number of registered MQTT_UID identifiers, unlike a
              -- single-string comparison against one already-resolved UID.
              -- No join to metadata.devices / metadata.gateways is needed
              -- for competing rows: a device's site is static given its
              -- identity, so matching device_id already implies matching
              -- site. telemetry.resolve_site_capture_bucket() remains the
              -- sole bucket-resolution authority and is still called per
              -- surviving row -- only the identity/window filtering ahead of
              -- it changed. See migration 204's header for the full
              -- root-cause and semantic-equivalence argument.
              SELECT 1
              FROM
              (
                  SELECT r2m.received_at,r2m.id AS raw_message_id,r2m.payload
                  FROM telemetry.raw_messages r2m
                  WHERE r2m.received_at>=ce.bucket_start
                    AND r2m.received_at<=ce.deadline
                    AND jsonb_typeof(r2m.payload->'rtdata')='array'
              ) r2m
              CROSS JOIN LATERAL jsonb_array_elements(r2m.payload->'rtdata') r2(value)
              CROSS JOIN LATERAL
              (
                  SELECT
                      CASE
                          WHEN (r2.value->>'ts') IS NULL THEN NULL::timestamptz
                          WHEN pg_input_is_valid(r2.value->>'ts','double precision')
                              THEN to_timestamp((r2.value->>'ts')::double precision)
                          ELSE NULL::timestamptz
                      END AS source_timestamp
              ) ts2
              CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
              (
                  ce.site_id,COALESCE(ts2.source_timestamp,r2m.received_at)
              ) b2
              WHERE lower(r2.value->>'uid') IN
              (
                  SELECT lower(di2.identifier_value)
                  FROM metadata.device_identifiers di2
                  WHERE di2.identifier_type='MQTT_UID'
                    AND di2.device_id=ce.device_id
              )
                AND b2.bucket_start=ce.bucket_start
                AND ROW
                    (COALESCE(ts2.source_timestamp,r2m.received_at),r2m.received_at,r2m.raw_message_id)
                    > ROW(ce.event_time,ce.received_at,ce.raw_message_id)
          )
        ON CONFLICT (site_id,bucket_start,device_id) DO NOTHING;

        -- Materialize any replay-selected samples from this raw packet.
        -- Migration 202: telemetry.normalized_points_for_recovery_candidate()
        -- replaces telemetry.v_normalized_points here -- see that function's
        -- COMMENT and migration 202's header for the full rationale and
        -- semantic-equivalence argument. Every other consumer of
        -- telemetry.v_normalized_points is unaffected.
        INSERT INTO telemetry.normalized_points
        (
            event_time,organization_id,site_id,gateway_id,device_id,
            logical_point_id,device_uid,logical_point,raw_field_name,
            raw_value,numeric_value,quality_code,mapping_source,
            platform_received_at,raw_message_id
        )
        SELECT np.event_time,np.organization_id,np.site_id,np.gateway_id,np.device_id,
               np.logical_point_id,np.device_uid,np.logical_point,np.raw_field_name,
               np.raw_value,np.numeric_value,np.quality_code,np.mapping_source,
               np.received_at,np.raw_message_id
        FROM telemetry.capture_bucket_samples s
        CROSS JOIN LATERAL
        (
            SELECT source_np.*
            FROM telemetry.normalized_points_for_recovery_candidate
            (
                s.raw_received_at,s.raw_message_id,s.device_id,s.event_time
            ) source_np
            OFFSET 0
        ) np
        WHERE s.raw_received_at=f.raw_received_at
          AND s.raw_message_id=f.raw_message_id
          AND s.status IN ('SELECTED','FAILED')
        ON CONFLICT (event_time,device_id,logical_point_id) DO UPDATE
        SET platform_received_at=EXCLUDED.platform_received_at,raw_message_id=EXCLUDED.raw_message_id
        WHERE EXCLUDED.platform_received_at>telemetry.normalized_points.platform_received_at;

        UPDATE telemetry.capture_bucket_samples s
        SET status='RECOVERED',normalized_at=coalesce(s.normalized_at,clock_timestamp()),last_error=NULL
        WHERE s.raw_received_at=f.raw_received_at AND s.raw_message_id=f.raw_message_id
          AND EXISTS
          (
              SELECT 1 FROM telemetry.normalized_points np
              WHERE np.device_id=s.device_id AND np.event_time=s.event_time
          );

        SELECT EXISTS
        (
            SELECT 1 FROM telemetry.capture_bucket_samples s
            WHERE s.raw_received_at=f.raw_received_at AND s.raw_message_id=f.raw_message_id
        ) INTO v_has_capture;

        SELECT EXISTS
        (
            SELECT 1
            FROM telemetry.v_rtdata fr
            JOIN metadata.device_identifiers fdi
              ON fdi.identifier_type='MQTT_UID'
             AND lower(fdi.identifier_value)=lower(fr.device_uid)
            JOIN metadata.devices fd ON fd.id=fdi.device_id
            JOIN metadata.gateways fg ON fg.id=fd.gateway_id
            CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
            (
                fg.site_id,COALESCE(fr.source_timestamp,fr.received_at)
            ) fb
            JOIN telemetry.capture_bucket_samples s
              ON s.site_id=fg.site_id
             AND s.device_id=fd.id
             AND s.bucket_start=fb.bucket_start
            JOIN telemetry.normalized_points np
              ON np.device_id=s.device_id AND np.event_time=s.event_time
            WHERE fr.received_at=f.raw_received_at
              AND fr.raw_message_id=f.raw_message_id
        ) INTO v_has_normalized;

        IF v_has_normalized THEN
            UPDATE telemetry.raw_message_failures
            SET resolution_status='RECOVERED',resolved_at=clock_timestamp(),
                resolution_method='AUTO_REPLAY_OR_CANONICAL_SUPERSESSION',next_replay_at=NULL,last_replay_error=NULL
            WHERE raw_received_at=f.raw_received_at AND raw_message_id=f.raw_message_id;
        ELSE
            UPDATE telemetry.raw_message_failures
            SET resolution_status=CASE WHEN replay_attempt_count>=5 THEN 'PERMANENT_FAILURE' ELSE 'RETRY_PENDING' END,
                next_replay_at=clock_timestamp()+CASE
                    WHEN replay_attempt_count<=1 THEN INTERVAL '1 hour'
                    WHEN replay_attempt_count=2 THEN INTERVAL '2 hours'
                    WHEN replay_attempt_count=3 THEN INTERVAL '6 hours'
                    ELSE INTERVAL '12 hours' END,
                last_replay_error=CASE WHEN v_has_capture
                    THEN 'Capture sample remains incomplete after replay.'
                    ELSE 'Message is not currently eligible for a finalized capture bucket.' END
            WHERE raw_received_at=f.raw_received_at AND raw_message_id=f.raw_message_id;
        END IF;

        -- Migration 203: commit this candidate's complete, already-atomic
        -- unit of work (attempt-count increment, supersession decision,
        -- normalization, final resolution-status transition) durably before
        -- moving on, so a later candidate that is slow enough to exhaust the
        -- job's max_runtime only loses its own in-flight, uncommitted work --
        -- every candidate resolved so far in this run stays resolved. See
        -- this migration's header for the empirical validation of this
        -- pattern against the real job-scheduler invocation shape.
        COMMIT;
    END LOOP;
END;
$procedure$;

COMMENT ON PROCEDURE telemetry.recover_failed_raw_messages(integer) IS
'Replays OPEN/RETRY_PENDING telemetry.raw_message_failures rows, oldest raw_received_at first (ORDER BY raw_received_at, FOR UPDATE SKIP LOCKED, LIMIT p_limit, p_limit in [1,1000], default 100), through the same supersession (migration 201) and targeted normalized-points (migration 202, telemetry.normalized_points_for_recovery_candidate) logic as the canonical pipeline. '
'Migration 203: each candidate is its own durable transaction -- this procedure COMMITs after every candidate''s complete recovery unit of work (attempt-count increment, retention-cutoff/quarantine branch, supersession decision, normalization, final RECOVERED/RETRY_PENDING/PERMANENT_FAILURE transition), instead of committing once after the whole LIMIT p_limit batch. '
'Consequence: if the calling job is cancelled (e.g. the TimescaleDB job scheduler''s max_runtime) while this procedure is running, every candidate already resolved in that run stays durably committed; only the one candidate being processed at the moment of cancellation rolls back; candidates after it are simply left unprocessed for the next run. A run that hits max_runtime is therefore still reported as a failed job run, but is no longer a run with zero backlog progress. '
'Operational constraint: because of the above, this procedure MUST be invoked as a bare top-level CALL (exactly as the TimescaleDB job scheduler invokes telemetry.run_failed_message_recovery_job, which nested-CALLs this procedure). Do NOT wrap a manual invocation in an explicit BEGIN; ... COMMIT; block, call it from a DO block or SQL function that is itself not a bare top-level statement, or call it from any other context that already owns an open transaction -- doing so fails immediately with "invalid transaction termination" (confirmed empirically; the failure is immediate and rolls back cleanly, it does not corrupt state, but it will not run at all). '
'This migration intentionally does NOT add per-candidate EXCEPTION handling: a per-candidate BEGIN...EXCEPTION WHEN OTHERS...END block combined with this procedure''s per-candidate COMMIT was confirmed empirically to fail ("invalid transaction termination") as soon as the handler actually catches a real error, because PostgreSQL does not permit a transaction-control statement once an exception has been caught in the same call frame. Per-candidate commit and per-candidate error isolation are mutually incompatible in this procedure shape; only the former is implemented here. A genuinely failing (not merely slow) candidate can still abort the current run at that point -- exactly as before this migration -- rolling back only its own uncommitted work; every previously committed candidate in that run remains resolved. '
'Migration 206: population selection is now purely age-based against the live telemetry.raw_messages retention policy, read dynamically from timescaledb_information.jobs (proc_schema=_timescaledb_functions, proc_name=policy_retention) and never hard-coded, instead of a raw_messages existence probe. A candidate whose raw_received_at is older than the current retention cutoff is immediately marked PERMANENT_FAILURE without running the supersession/normalization logic; a raw row that happens to still be physically present past its own cutoff is deliberately not special-cased. Migration 204''s targeted, bounded supersession search is unchanged for every candidate still inside the retention window.';

COMMIT;
