-- ============================================================================
-- Migration 203
-- Give telemetry.recover_failed_raw_messages() a per-candidate transaction
-- boundary, so that a run killed by the job's 10-minute max_runtime leaves
-- durable partial progress instead of rolling back the entire batch.
--
-- Root cause (2026-08-26, live staging investigation, continued from
-- migrations 201 and 202): even after 201 bounded the supersession search
-- and 202 replaced the normalized-points lookup with a targeted function,
-- job 1077 (telemetry.run_failed_message_recovery_job) still ran the whole
-- up-to-100-candidate batch as ONE transaction. The exceptional historical
-- backlog (devices onboarded/configured later than the raw messages that
-- predate their commissioning) contains a long tail of candidates against
-- old, compressed chunks whose per-candidate cost varies widely. Whenever a
-- run's cumulative cost across its candidates exceeded max_runtime, the
-- scheduler's cancellation rolled back every candidate processed in that
-- run -- zero durable backlog movement, no matter how many candidates had
-- already been successfully resolved before the slow one.
--
-- This migration does not change why any individual candidate is slow (that
-- was 201/202's job, and their fixes are unchanged and still in effect
-- here). It changes what survives when a run runs out of time.
--
-- Fix: commit after each candidate's existing recovery unit of work
-- completes, instead of after the whole LIMIT p_limit batch. The existing
-- FOR f IN SELECT ... ORDER BY raw_received_at LIMIT p_limit FOR UPDATE
-- SKIP LOCKED LOOP is unchanged; a single COMMIT is added as the last
-- statement of the loop body, after the existing RECOVERED / RETRY_PENDING /
-- PERMANENT_FAILURE resolution-status transition. Everything inside one
-- iteration -- the replay_attempt_count increment, the not-exists/quarantine
-- branch, the Track B (migration 201) supersession decision, the PR #11
-- (migration 202) targeted normalized-points materialization, and the final
-- resolution-status update -- remains exactly one atomic, all-or-nothing
-- unit of work; only the point at which that unit becomes durable moves
-- earlier, from "after the whole batch" to "after this one candidate".
--
-- Explicitly not touched by this migration: p_limit (still 1-1000, default
-- 100), ORDER BY raw_received_at (oldest-first is unchanged and, if
-- anything, strengthened -- see below), FOR UPDATE SKIP LOCKED concurrency
-- safety, retry/backoff computation, the RECOVERED / RETRY_PENDING /
-- PERMANENT_FAILURE state machine, migration 201's bounded supersession
-- predicate, migration 202's normalized_points_for_recovery_candidate()
-- function and its call site, compression/retention policies, the job's
-- schedule_interval, max_runtime, or retry policy (all set in
-- postgres/ddl/126_site_frequency_normalization_recovery.sql and untouched
-- here), and MQTT ingestion. No per-candidate EXCEPTION handling is
-- introduced -- see the empirical finding below for why.
--
-- Empirical validation (2026-08-26, against the exact TimescaleDB image
-- staging/production run, in a disposable throwaway container -- not
-- staging, not production):
--   - The real invocation shape -- TimescaleDB job scheduler's top-level
--     CALL telemetry.run_failed_message_recovery_job(job_id, config), which
--     nested-CALLs telemetry.recover_failed_raw_messages(p_limit) -- was
--     reproduced exactly. A FOR ... FOR UPDATE SKIP LOCKED LOOP with an
--     intra-loop COMMIT inside the nested procedure ran cleanly: no error,
--     each row committed independently.
--   - Cancelling the backend mid-candidate (simulating the scheduler's
--     max_runtime kill) left already-committed candidates durably resolved
--     and rolled back only the in-flight candidate's uncommitted work --
--     "canceling statement due to user request", no partial/corrupt row
--     state.
--   - FOR UPDATE SKIP LOCKED continues to behave correctly across the added
--     COMMIT: PL/pgSQL's implicit cursor for a FOR-over-query loop with
--     transaction control fetches and locks rows lazily as each iteration
--     advances (not all upfront), so each subsequent candidate's lock is
--     acquired fresh, under a new snapshot, after the prior candidate's
--     commit -- concurrent invocations (e.g. an operator's manual forced
--     CALL overlapping the scheduled run) remain safe and non-duplicating,
--     and in fact hold each row's lock for a shorter duration than before.
--   - Wrapping the CALL in an explicit BEGIN; ... COMMIT; fails immediately
--     with "invalid transaction termination" and rolls back cleanly (no
--     corruption) -- manual/ad hoc invocation of this procedure must be a
--     bare top-level CALL. This is documented on the procedure itself
--     below.
--   - A per-candidate BEGIN ... EXCEPTION WHEN OTHERS ... END block combined
--     with the per-candidate COMMIT is NOT supported: once the exception
--     handler actually catches a real error, the next COMMIT fails with the
--     same "invalid transaction termination". Per-candidate commit and
--     per-candidate error isolation are mutually incompatible in this
--     procedure shape. This migration intentionally adds only the commit,
--     not exception handling: a genuinely failing (not merely slow)
--     candidate can still abort the current run at that point, exactly as
--     before, rolling back only its own uncommitted work -- every
--     previously committed candidate in that run stays durably resolved.
-- ============================================================================

BEGIN;

CREATE OR REPLACE PROCEDURE telemetry.recover_failed_raw_messages(IN p_limit integer DEFAULT 100)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    f RECORD;
    v_exists BOOLEAN;
    v_has_capture BOOLEAN;
    v_has_normalized BOOLEAN;
BEGIN
    IF p_limit IS NULL OR p_limit<1 OR p_limit>1000 THEN
        RAISE EXCEPTION 'p_limit must be between 1 and 1000';
    END IF;

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

        SELECT EXISTS
        (
            SELECT 1 FROM telemetry.raw_messages r
            WHERE r.received_at=f.raw_received_at AND r.id=f.raw_message_id
        ) INTO v_exists;

        IF NOT v_exists THEN
            UPDATE telemetry.raw_message_failures
            SET resolution_status=CASE WHEN replay_attempt_count>=5 THEN 'PERMANENT_FAILURE' ELSE 'RETRY_PENDING' END,
                next_replay_at=clock_timestamp()+INTERVAL '6 hours',
                last_replay_error='Original raw row is outside the 48-hour raw retention window; payload remains quarantined for manual forensic recovery.'
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
              -- Supersession search, bounded to the candidate bucket's own
              -- late-arrival tolerance window -- see COMMENT ON COLUMN
              -- config.telemetry_capture_policies.late_arrival_tolerance_seconds
              -- (migration 201) for the full semantic definition. Both
              -- bounds are resolved per-candidate from ce (bucket_start,
              -- deadline), never from now() or the candidate's own age, so
              -- an old failed message still gets a full, correctly-scoped
              -- search here -- it is only ever disqualified from recovery
              -- above by replay_attempt_count<5, never by this predicate.
              SELECT 1
              FROM telemetry.v_rtdata r2
              JOIN metadata.device_identifiers di2
                ON di2.identifier_type='MQTT_UID'
               AND lower(di2.identifier_value)=lower(r2.device_uid)
              JOIN metadata.devices d2 ON d2.id=di2.device_id
              JOIN metadata.gateways g2 ON g2.id=d2.gateway_id
              CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
              (
                  g2.site_id,COALESCE(r2.source_timestamp,r2.received_at)
              ) b2
              WHERE d2.id=ce.device_id
                AND g2.site_id=ce.site_id
                AND b2.bucket_start=ce.bucket_start
                AND r2.received_at>=ce.bucket_start
                AND r2.received_at<=ce.deadline
                AND ROW
                    (COALESCE(r2.source_timestamp,r2.received_at),r2.received_at,r2.raw_message_id)
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
'Migration 203: each candidate is its own durable transaction -- this procedure COMMITs after every candidate''s complete recovery unit of work (attempt-count increment, not-exists/quarantine branch, supersession decision, normalization, final RECOVERED/RETRY_PENDING/PERMANENT_FAILURE transition), instead of committing once after the whole LIMIT p_limit batch. '
'Consequence: if the calling job is cancelled (e.g. the TimescaleDB job scheduler''s max_runtime) while this procedure is running, every candidate already resolved in that run stays durably committed; only the one candidate being processed at the moment of cancellation rolls back; candidates after it are simply left unprocessed for the next run. A run that hits max_runtime is therefore still reported as a failed job run, but is no longer a run with zero backlog progress. '
'Operational constraint: because of the above, this procedure MUST be invoked as a bare top-level CALL (exactly as the TimescaleDB job scheduler invokes telemetry.run_failed_message_recovery_job, which nested-CALLs this procedure). Do NOT wrap a manual invocation in an explicit BEGIN; ... COMMIT; block, call it from a DO block or SQL function that is itself not a bare top-level statement, or call it from any other context that already owns an open transaction -- doing so fails immediately with "invalid transaction termination" (confirmed empirically; the failure is immediate and rolls back cleanly, it does not corrupt state, but it will not run at all). '
'This migration intentionally does NOT add per-candidate EXCEPTION handling: a per-candidate BEGIN...EXCEPTION WHEN OTHERS...END block combined with this procedure''s per-candidate COMMIT was confirmed empirically to fail ("invalid transaction termination") as soon as the handler actually catches a real error, because PostgreSQL does not permit a transaction-control statement once an exception has been caught in the same call frame. Per-candidate commit and per-candidate error isolation are mutually incompatible in this procedure shape; only the former is implemented here. A genuinely failing (not merely slow) candidate can still abort the current run at that point -- exactly as before this migration -- rolling back only its own uncommitted work; every previously committed candidate in that run remains resolved.';

COMMIT;
