-- ============================================================================
-- Migration 218
-- Make telemetry.recover_failed_raw_messages() onboarding-aware: an in-retention
-- failure candidate whose source MQTT UID does not currently resolve to a
-- commissioned, telemetry-eligible device is DEFERRED cheaply -- BEFORE the
-- expensive per-candidate recovery work -- instead of paying the full cost only
-- to fail with UNRESOLVED_DEVICE_ELEMENTS again.
--
-- WHY
--   Job 1077 (telemetry.run_failed_message_recovery_job, hourly, max_runtime
--   10 min, config {limit:1000}) processes raw_message_failures oldest-first.
--   A single high-cadence publisher that is not yet onboarded (no
--   metadata.devices row, or a device still at lifecycle_status <> 'ACTIVE')
--   can fill the queue with hundreds of candidates, each of which currently
--   runs the full path -- the current_elements MATERIALIZED CTE over
--   telemetry.v_rtdata, the migration-204 supersession NOT EXISTS scan of
--   telemetry.raw_messages, telemetry.resolve_site_capture_bucket(), and
--   telemetry.normalized_points_for_recovery_candidate() -- at ~seconds to
--   minutes per candidate, only to end at RETRY_PENDING because the device's
--   elements cannot resolve. ~5 candidates per 10-minute run get processed;
--   the job times out every run; genuinely recoverable candidates from other,
--   commissioned devices are starved behind the un-onboarded ones.
--
--   "Uncommissioned is not unrecoverable." Once the device is commissioned
--   (lifecycle_status='ACTIVE'), its deferred candidates must flow back into
--   the normal recovery path automatically, with no operator step and no data
--   loss.
--
-- WHAT CHANGES
--   1. resolution_status gains one value: 'DEFERRED_UNCOMMISSIONED'
--      (raw_message_failures_resolution_status_ck extended -- the same
--      additive DROP/ADD CONSTRAINT pattern migration 008 used for
--      'LEGACY_CLOSED'). Not a new table, not an enum, not a new column.
--   2. raw_message_failures_recovery_due_idx WHERE clause extended to include
--      'DEFERRED_UNCOMMISSIONED' so the recovery loop's re-scan of deferred
--      rows stays index-backed.
--   3. telemetry.recover_failed_raw_messages(): the migration-206 body
--      VERBATIM plus
--        a. the loop SELECT now also picks up 'DEFERRED_UNCOMMISSIONED' rows
--           (so a deferred candidate is re-evaluated every run);
--        b. a new cheap branch placed IMMEDIATELY AFTER the migration-206
--           retention-cutoff branch and BEFORE the expensive current_elements
--           CTE: resolve f.source_identifier via
--           metadata.device_identifiers (identifier_type='MQTT_UID',
--           case-insensitive) -> metadata.devices; if there is no such device,
--           or its lifecycle_status <> 'ACTIVE', or its profile_id IS NULL
--           (the same telemetry-eligibility guard current_elements itself
--           applies), set resolution_status='DEFERRED_UNCOMMISSIONED', roll
--           the just-incremented replay_attempt_count back by one (a deferral
--           is not a replay attempt and must never exhaust the 5-attempt cap),
--           set next_replay_at = now() + 1 hour, record an explicit
--           DEVICE_NOT_COMMISSIONED reason in last_replay_error, COMMIT
--           (migration-203 per-candidate durability) and CONTINUE.
--
-- INVARIANTS PRESERVED (verbatim from migration 206 / 204 / 203 / 202)
--   * The migration-206 retention branch is unchanged and still runs FIRST:
--     a candidate whose raw_received_at is older than the live
--     telemetry.raw_messages retention cutoff still becomes PERMANENT_FAILURE
--     immediately, without the expensive path AND without reaching the new
--     deferral branch. A row that is DEFERRED_UNCOMMISSIONED and later ages
--     past retention becomes PERMANENT_FAILURE on the next run (retention
--     branch precedes the deferral branch). No candidate is trapped.
--   * Migration 204's supersession subquery: byte-for-byte identical.
--   * Migration 202's normalized_points_for_recovery_candidate() call:
--     identical.
--   * Migration 203's per-candidate COMMIT: the deferral branch ends with
--     COMMIT; CONTINUE; exactly like the retention branch. The procedure is
--     still a bare-top-level-CALL procedure with no per-candidate EXCEPTION
--     handling.
--   * p_limit range [1,1000], ORDER BY raw_received_at, FOR UPDATE SKIP
--     LOCKED, the unconditional initial attempt-count increment, the
--     RETRY_PENDING backoff schedule, the RECOVERED transition, and
--     telemetry.run_failed_message_recovery_job() are all unchanged.
--   * Job 1077's schedule (1 hour), max_runtime (10 min), and config
--     ({limit:1000}) are NOT touched.
--
-- RE-ELIGIBILITY AFTER COMMISSIONING (automatic, no operator step)
--   A DEFERRED_UNCOMMISSIONED row has next_replay_at = deferral_time + 1 hour
--   and replay_attempt_count unchanged. On the next job run at or after that
--   time the loop re-selects it, the new branch re-resolves its UID; if the
--   device is now lifecycle_status='ACTIVE' with a profile the branch falls
--   through and the candidate runs the full, unchanged recovery path. Worst-
--   case latency from commissioning to first real recovery attempt is
--   ~1 hour + one job cycle.
--
-- NO UID-SPECIFIC LOGIC. Eligibility is decided purely from
-- metadata.device_identifiers + metadata.devices.lifecycle_status +
-- metadata.devices.profile_id.
--
-- NOT TOUCHED: migration 217 / the hourly reconciliation work; any analytics
-- object; telemetry.run_failed_message_recovery_job; the capture / normalization
-- ingest path; telemetry.normalized_points_for_recovery_candidate;
-- telemetry.resolve_site_capture_bucket; retention / compression policies;
-- Grafana; application code.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. resolution_status gains 'DEFERRED_UNCOMMISSIONED' (additive; the
--    migration-008 pattern). All existing rows satisfy the superset
--    constraint, so the re-validation is a no-op.
-- ----------------------------------------------------------------------------
ALTER TABLE telemetry.raw_message_failures
    DROP CONSTRAINT IF EXISTS raw_message_failures_resolution_status_ck;

ALTER TABLE telemetry.raw_message_failures
    ADD CONSTRAINT raw_message_failures_resolution_status_ck
    CHECK (resolution_status IN
        ('OPEN','RETRY_PENDING','RECOVERED','PERMANENT_FAILURE','LEGACY_CLOSED',
         'DEFERRED_UNCOMMISSIONED'));

-- ----------------------------------------------------------------------------
-- 2. Keep the recovery-loop re-scan of deferred rows index-backed.
-- ----------------------------------------------------------------------------
DROP INDEX IF EXISTS telemetry.raw_message_failures_recovery_due_idx;

CREATE INDEX raw_message_failures_recovery_due_idx
    ON telemetry.raw_message_failures (next_replay_at, raw_received_at)
    WHERE resolution_status IN ('OPEN','RETRY_PENDING','DEFERRED_UNCOMMISSIONED');

-- ----------------------------------------------------------------------------
-- 3. telemetry.recover_failed_raw_messages() -- migration-206 body verbatim
--    plus the onboarding-aware cheap deferral branch.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.recover_failed_raw_messages(IN p_limit integer DEFAULT 100)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    f RECORD;
    v_has_capture BOOLEAN;
    v_has_normalized BOOLEAN;
    v_retention_interval INTERVAL;
    v_retention_cutoff TIMESTAMPTZ;
    v_device_eligible BOOLEAN;   -- migration 218
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
        WHERE resolution_status IN ('OPEN','RETRY_PENDING','DEFERRED_UNCOMMISSIONED')   -- migration 218: also re-scan deferred rows
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

        -- Migration 218: onboarding-aware cheap deferral. Runs AFTER the
        -- retention branch (so an aged-out row is still PERMANENT_FAILURE, not
        -- deferred) and BEFORE the expensive current_elements CTE /
        -- supersession NOT EXISTS / resolve_site_capture_bucket() /
        -- normalized_points_for_recovery_candidate() work. Eligibility mirrors
        -- what current_elements itself requires: the UID must resolve, via
        -- metadata.device_identifiers (MQTT_UID, case-insensitive), to a
        -- metadata.devices row that is commissioned (lifecycle_status='ACTIVE')
        -- and has a profile (profile_id IS NOT NULL). Anything else -- no
        -- device, a device still REGISTERED/INACTIVE/DECOMMISSIONED, or a
        -- profileless device, or a NULL source_identifier -- is DEFERRED, not
        -- failed: replay_attempt_count is rolled back (a deferral is not an
        -- attempt), next_replay_at is set one hour out, and the candidate is
        -- re-evaluated on the next run so it rejoins the normal recovery path
        -- automatically once the device is commissioned.
        SELECT EXISTS (
            SELECT 1
            FROM metadata.device_identifiers di
            JOIN metadata.devices d ON d.id = di.device_id
            WHERE di.identifier_type = 'MQTT_UID'
              AND lower(di.identifier_value) = lower(f.source_identifier)
              AND d.lifecycle_status = 'ACTIVE'
              AND d.profile_id IS NOT NULL
        ) INTO v_device_eligible;

        IF NOT v_device_eligible THEN
            UPDATE telemetry.raw_message_failures
            SET resolution_status='DEFERRED_UNCOMMISSIONED',
                replay_attempt_count=GREATEST(replay_attempt_count-1,0),
                next_replay_at=clock_timestamp()+INTERVAL '1 hour',
                last_replay_error='DEVICE_NOT_COMMISSIONED: source UID '
                    ||COALESCE(f.source_identifier,'<none>')
                    ||' does not currently resolve to a commissioned (lifecycle_status=ACTIVE), '
                    ||'telemetry-eligible device; deferred pending onboarding, will retry automatically.'
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
'Replays OPEN/RETRY_PENDING/DEFERRED_UNCOMMISSIONED telemetry.raw_message_failures rows, oldest raw_received_at first (ORDER BY raw_received_at, FOR UPDATE SKIP LOCKED, LIMIT p_limit, p_limit in [1,1000], default 100), through the same supersession (migration 201/204) and targeted normalized-points (migration 202) logic as the canonical pipeline. '
'Migration 203: each candidate is its own durable transaction -- this procedure COMMITs after every candidate''s complete unit of work, so a run cancelled at max_runtime keeps every candidate already resolved in it. Invoke ONLY as a bare top-level CALL. '
'Migration 206: population selection is purely age-based against the live telemetry.raw_messages retention policy (read dynamically from timescaledb_information.jobs); a candidate older than the retention cutoff is marked PERMANENT_FAILURE immediately, without the expensive path. '
'Migration 218: BEFORE the expensive current_elements CTE / supersession NOT EXISTS / resolve_site_capture_bucket() / normalized_points_for_recovery_candidate() work -- and AFTER the retention branch -- the candidate''s source MQTT UID is resolved via metadata.device_identifiers -> metadata.devices. If it does not resolve to a commissioned (lifecycle_status=''ACTIVE''), profiled device, the candidate is set to DEFERRED_UNCOMMISSIONED with its replay_attempt_count rolled back (a deferral is not a replay attempt), next_replay_at one hour out, and an explicit DEVICE_NOT_COMMISSIONED reason -- NOT PERMANENT_FAILURE. The loop re-scans DEFERRED_UNCOMMISSIONED rows every run, so a candidate rejoins the normal recovery path automatically, with no operator step and no data loss, once its device is commissioned. No UID-specific logic. Job 1077 schedule / max_runtime / config are unchanged.';

COMMIT;
