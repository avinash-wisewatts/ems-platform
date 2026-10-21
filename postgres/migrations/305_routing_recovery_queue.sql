-- ============================================================================
-- Migration 305
-- Recovered raw messages reach energy / environment measurements (staging
-- optimization plan CI-1 / T1.4; design review §10.31 C).
--
-- THE DEFECT
--   Job 1077 (telemetry.recover_failed_raw_messages, migration 220 body)
--   re-inserts a quarantined message's normalized_points with
--   platform_received_at = the raw message's ORIGINAL received_at. The message
--   reaches recovery at least 20 minutes later (1068 grace), usually hours
--   (and days for DEFERRED_UNCOMMISSIONED messages replayed on commissioning).
--   Both routing loaders window on platform_received_at: forward runs read
--   (checkpoint - 1 min, window_end], the migration-303 late sweep reads
--   (sweep checkpoint - 1 min, forward checkpoint] AND event_time < floor. A
--   recovered row is below both windows, so it is never routed: the energy /
--   environment measurement rows (and every tier above them) stay missing, and
--   no reconciler sees it (they compare tiers derived from the same tables).
--
-- THE FIX
--   1. telemetry.routing_recovery_queue: the recovery insert becomes a
--      data-modifying CTE whose RETURNING (device_id, event_time) -- the rows
--      it added or superseded -- is queued in the SAME per-candidate
--      transaction (migration 203's COMMIT), so a rolled-back candidate queues
--      nothing and a committed one is never lost.
--   2. A third loader scope, ems.routing_scope = 'recovery' (transaction-local,
--      like 303's 'late_sweep'): the loader fixes a batch of pending queue ids
--      (oldest first, at most 10,000) under its advisory lock, reads those
--      (device_id, event_time) pairs instead of the receipt window (no receipt
--      or event_time bound: any chunk, compressed or not), runs the unchanged
--      bucket / rank / upsert code, and stamps energy_routed_at /
--      environment_routed_at in the same transaction. Its status row is
--      <pipeline>_recovery; no checkpoint is involved.
--   3. telemetry.run_routing_late_sweep_job (hourly hh:31:30, unchanged
--      schedule / config / max_runtime / retries) runs the recovery scope for
--      both loaders after the two sweeps, one transaction each, then deletes
--      entries both loaders routed more than 7 days ago.
--   4. Demand reconciler (analytics.reconcile_demand_intervals, job 1121):
--      reconcile_window 6 h -> 48 h (raw retention), so demand intervals whose
--      energy a recovery re-supplies are re-finalized (non-VALID only; VALID
--      rows stay immutable). User decision 2026-10-19.
--
-- WHY IT IS SAFE
--   - Forward and sweep scopes: the window read gains "AND v_scope <>
--     'recovery'" and a UNION ALL arm guarded by "v_scope = 'recovery'"; both
--     are parameter-only quals (one-time filters), so the forward / sweep arm
--     and its startup chunk exclusion are unchanged and the recovery arm never
--     executes outside the recovery scope.
--   - Idempotent: the upserts are keyed (bucket_start, device_id); energy
--     updates only a newer sample inside the correction deadline, environment
--     inserts DO NOTHING and updates only inside the deadline. Re-routing a
--     pair, or a duplicate queue entry, cannot duplicate or regress a row.
--   - Failure / lock contention: a failed run rolls back with its stamps; a
--     SKIPPED_LOCKED run stamps nothing; entries stay pending for the next hour.
--   - Late data: a recovered sample whose bucket is past its correction
--     deadline is inserted if the bucket is missing and never overwrites an
--     existing row.
--   - Tiers: ca_energy_1min refreshes 2 days back (recoveries are <= 48 h old);
--     the 1-minute tier is repaired by reconciler 1116 (2 d window), then
--     1118 / 1119 / 1120; demand by 1121 (now 48 h).
--
-- Not changed: forward routing jobs, normalization, job 1077's schedule /
--   config, every other procedure, Grafana, data. Applying the migration
--   changes no measurement row.
--
-- Cost note: 1121 reads 8x the window per hourly run (staging 2026-10-19 last
--   run 15.7 s at 6 h); measure after deploy, and consider T1.3e (6-hourly).
--
-- Rollback (forward migration): re-issue the migration-220 recovery body, the
--   migration-303 loader and sweep-job bodies, alter_job 1121 back to
--   reconcile_window 6 hours, DELETE the two *_recovery pipeline_state rows,
--   DROP TABLE telemetry.routing_recovery_queue (route any pending entries
--   first, or they stay unrouted as before 305).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Preconditions: exact source bodies (migrations 220 / 303 = staging
--    2026-10-19), the demand reconciler's 6-hour window, no queue yet, the
--    scope setting not set at database or role level.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure)
       IS DISTINCT FROM 'ee8c1867c0426587cda0d40467be57a2' THEN
        RAISE EXCEPTION 'Migration 305 precondition failed: load_energy_measurements_incremental differs from the migration-303 body.';
    END IF;
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure)
       IS DISTINCT FROM 'be09c0efb5cc8f5f819f2bb30b8d5370' THEN
        RAISE EXCEPTION 'Migration 305 precondition failed: load_environment_measurements_incremental differs from the migration-303 body.';
    END IF;
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'telemetry.recover_failed_raw_messages(integer)'::regprocedure)
       IS DISTINCT FROM '6c64cb3299da492900bb66221704744f' THEN
        RAISE EXCEPTION 'Migration 305 precondition failed: recover_failed_raw_messages differs from the migration-220 body.';
    END IF;
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'telemetry.run_routing_late_sweep_job(integer,jsonb)'::regprocedure)
       IS DISTINCT FROM 'ee1e97ace9547cf20c3df5e02ada9cdd' THEN
        RAISE EXCEPTION 'Migration 305 precondition failed: run_routing_late_sweep_job differs from the migration-303 body.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals'
          AND config ->> 'reconcile_window' = '6 hours') <> 1 THEN
        RAISE EXCEPTION 'Migration 305 precondition failed: expected exactly one analytics.reconcile_demand_intervals job with reconcile_window 6 hours.';
    END IF;
    IF to_regclass('telemetry.routing_recovery_queue') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 305 precondition failed: telemetry.routing_recovery_queue already exists.';
    END IF;
    IF COALESCE(current_setting('ems.routing_scope', true), '') <> '' THEN
        RAISE EXCEPTION 'Migration 305 precondition failed: ems.routing_scope is set (%).', current_setting('ems.routing_scope', true);
    END IF;
END
$pre$;


-- ----------------------------------------------------------------------------
-- 2. The queue. One row per (raw message, device, event_time) the recovery
--    insert added or superseded; each loader stamps its own column. No unique
--    key on purpose: a later recovery of the same pair is a new entry, so a
--    supersession committed while a batch is being routed is routed again.
-- ----------------------------------------------------------------------------
CREATE TABLE telemetry.routing_recovery_queue
(
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raw_received_at       TIMESTAMPTZ NOT NULL,
    raw_message_id        BIGINT      NOT NULL,
    device_id             UUID        NOT NULL,
    event_time            TIMESTAMPTZ NOT NULL,
    enqueued_at           TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    energy_routed_at      TIMESTAMPTZ,
    environment_routed_at TIMESTAMPTZ
);
CREATE INDEX routing_recovery_queue_energy_pending_idx
    ON telemetry.routing_recovery_queue (id) WHERE energy_routed_at IS NULL;
CREATE INDEX routing_recovery_queue_environment_pending_idx
    ON telemetry.routing_recovery_queue (id) WHERE environment_routed_at IS NULL;
ALTER TABLE telemetry.routing_recovery_queue OWNER TO ems_admin;
REVOKE ALL ON telemetry.routing_recovery_queue FROM PUBLIC;
COMMENT ON TABLE telemetry.routing_recovery_queue IS
'Migration 305 (plan CI-1 / T1.4): (device_id, event_time) pairs re-inserted into telemetry.normalized_points by telemetry.recover_failed_raw_messages, written in the same per-candidate transaction. Recovered rows keep their original platform_received_at, below every routing receipt window; the hourly telemetry.run_routing_late_sweep_job routes the pending entries with ems.routing_scope = ''recovery'' and each loader stamps energy_routed_at / environment_routed_at in its own transaction (a failed or lock-skipped run leaves them pending). Entries both loaders routed more than 7 days ago are deleted by the same job.';


-- ----------------------------------------------------------------------------
-- 3. Recovery: the migration-220 body plus the two migration-305 fragments
--    (the normalized_points insert becomes a data-modifying CTE feeding the
--    queue). COMMENT, owner, grants, job 1077 unchanged.
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
              WHERE lower(r2.value->>'uid') IN
              (
                  SELECT lower(di2.identifier_value)
                  FROM metadata.device_identifiers di2
                  WHERE di2.identifier_type='MQTT_UID'
                    AND di2.device_id=ce.device_id
              )
                -- Migration 220: same-bucket membership is tested by interval
                -- containment against ce's OWN authoritative bucket, replacing
                -- the per-competing-element resolve_site_capture_bucket() fan-out.
                -- ce.bucket_start / ce.capture_interval_seconds still come from
                -- current_elements' single resolve_site_capture_bucket() call --
                -- that function stays the sole bucket-resolution authority and is
                -- NOT modified. Equivalent under WALL_CLOCK alignment (the only
                -- deployed alignment_mode; asserted by the regression test):
                -- resolve_site_capture_bucket(site, ts) returns the
                -- capture_interval_seconds-aligned floor of ts, so
                --   b2.bucket_start = ce.bucket_start
                -- IFF ts lies in
                --   [ce.bucket_start, ce.bucket_start + capture_interval_seconds).
                -- Verified read-only on staging: candidate 2672476 + 3 more, all
                -- 364 competing elements over bucket_start..deadline (340 in the
                -- 900 s tail), 0 disagreements with the current bucket-function.
                -- The migration-201/204 receipt-time window
                -- (r2m.received_at BETWEEN ce.bucket_start AND ce.deadline), the
                -- rtdata-is-array guard, and the device-identity IN-list test are
                -- unchanged; only the per-element bucket re-resolution is removed.
                AND COALESCE(ts2.source_timestamp,r2m.received_at) >= ce.bucket_start
                AND COALESCE(ts2.source_timestamp,r2m.received_at) <
                        ce.bucket_start + make_interval(secs => ce.capture_interval_seconds)
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
        -- Migration 305: queue every (device_id, event_time) this insert
        -- adds or supersedes for the routing recovery scope, in this
        -- candidate's transaction (its COMMIT below). The rows keep their
        -- original platform_received_at, below every routing receipt window,
        -- so without the queue they never reach energy / environment
        -- measurements (plan CI-1 / T1.4).
        WITH recovered AS
        (
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
        WHERE EXCLUDED.platform_received_at>telemetry.normalized_points.platform_received_at
        RETURNING device_id,event_time
        )
        INSERT INTO telemetry.routing_recovery_queue (raw_received_at,raw_message_id,device_id,event_time)
        SELECT DISTINCT f.raw_received_at,f.raw_message_id,r.device_id,r.event_time
        FROM recovered r;

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


-- ----------------------------------------------------------------------------
-- 4. Energy loader: the migration-303 body plus the five migration-305 fragments.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental(IN p_overlap interval DEFAULT '00:15:00'::interval, IN p_max_window interval DEFAULT NULL)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
  -- Migration 303: ems.routing_scope (transaction-local; set only by
  -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
  v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting('ems.routing_scope', true), ''), 'forward');
  -- Migration 305: ems.routing_scope = 'recovery' (set only by the late-sweep
  -- job) routes the pairs queued in telemetry.routing_recovery_queue.
  v_pipeline_name CONSTANT TEXT := CASE v_scope WHEN 'late_sweep' THEN 'energy_measurements_late_sweep' WHEN 'recovery' THEN 'energy_measurements_recovery' ELSE 'energy_measurements' END;
  v_queue_ids BIGINT[] := '{}';
  v_event_min TIMESTAMPTZ;
  v_event_max TIMESTAMPTZ;
  v_forward_checkpoint TIMESTAMPTZ;
  v_previous_checkpoint TIMESTAMPTZ;
  v_window_start TIMESTAMPTZ;
  v_window_end TIMESTAMPTZ;
  v_affected_rows BIGINT := 0;
  v_lock_acquired BOOLEAN;
  v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
    RAISE EXCEPTION 'p_overlap must be zero or a positive interval; received %', p_overlap;
  END IF;

  -- Migration 207: reject a non-positive explicit bound. NULL (the
  -- default, and what a direct/manual invocation passes) means "no
  -- bound" -- byte-for-byte the pre-207 behaviour.
  IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
    RAISE EXCEPTION 'p_max_window must be positive when supplied; received %', p_max_window;
  END IF;

  -- Migration 303: reject an unknown scope.
  IF v_scope NOT IN ('forward', 'late_sweep', 'recovery') THEN
    RAISE EXCEPTION 'ems.routing_scope must be forward, late_sweep or recovery; received %', v_scope;
  END IF;

  SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.load_energy_measurements_incremental',0))
  INTO v_lock_acquired;
  IF NOT v_lock_acquired THEN
    UPDATE telemetry.pipeline_state SET last_status='SKIPPED_LOCKED',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  SELECT last_received_at INTO v_previous_checkpoint
  FROM telemetry.pipeline_state WHERE pipeline_name=v_pipeline_name FOR UPDATE;

  UPDATE telemetry.pipeline_state
  SET last_started_at=clock_timestamp(),last_status='RUNNING',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;

  -- Migration 267: bound the window-end lookup to recent event_time so it only
  -- reads uncompressed chunks (normalized_points compress_after = 1 day). The
  -- bounded max can only be lower than the global max, which delays -- never
  -- skips -- rows; the global lookup remains the fallback when no row has a
  -- recent event_time.
  SELECT max(platform_received_at) INTO v_window_end
  FROM telemetry.normalized_points
  WHERE platform_received_at IS NOT NULL
    AND event_time >= now() - INTERVAL '1 day';
  IF v_window_end IS NULL THEN
    SELECT max(platform_received_at) INTO v_window_end
    FROM telemetry.normalized_points
    WHERE platform_received_at IS NOT NULL;
  END IF;
  IF v_window_end IS NULL THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='NO_SOURCE_DATA',last_error=NULL,updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RETURN;
  END IF;

  -- Migration 207: cap the forward processing boundary to the previous
  -- checkpoint plus p_max_window when a caller supplies one and a
  -- previous checkpoint already exists. NULL (the default) leaves
  -- v_window_end exactly as computed above -- byte-for-byte the pre-207
  -- behaviour. The scheduled wrapper telemetry.run_energy_routing_job
  -- passes a bounded value so an unattended multi-hour
  -- normalized_points backlog self-drains over successive 1-minute runs
  -- instead of being attempted as one unbounded, max_runtime-exceeding
  -- transaction -- the job-1000 stall class, fixed for normalization by
  -- migration 205 and extended here to energy/environment routing. A
  -- direct manual CALL that omits the argument (or passes NULL) still
  -- performs unrestricted catch-up. Advisory lock, checkpoint keying,
  -- overlap semantics, the routing/calculation SQL below, and the
  -- EXCEPTION-rolls-back-the-watermark contract are all unchanged.
  IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
    v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
  END IF;

  -- Migration 303: forward runs read only normalized_points chunks newer
  -- than the newest compressed chunk (event_time >= its range_end), so
  -- chunk exclusion skips every compressed chunk instead of scanning its
  -- batch metadata on every run. Rows older than that floor (late data in
  -- compressed chunks) are routed by the hourly late-data sweep, which reads
  -- only event_time < floor and never passes the forward checkpoint.
  SELECT max(c.range_end) INTO v_event_min
  FROM timescaledb_information.chunks c
  WHERE c.hypertable_schema='telemetry'
    AND c.hypertable_name='normalized_points'
    AND c.is_compressed;
  v_event_min := COALESCE(v_event_min, '-infinity'::timestamptz);
  v_event_max := 'infinity'::timestamptz;
  IF v_scope = 'late_sweep' THEN
    v_event_max := v_event_min;
    v_event_min := '-infinity'::timestamptz;
    SELECT last_received_at INTO v_forward_checkpoint
    FROM telemetry.pipeline_state WHERE pipeline_name='energy_measurements';
    v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, '-infinity'::timestamptz));
    IF v_previous_checkpoint IS NOT NULL THEN
      v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
    END IF;
  END IF;

  -- Migration 305: the recovery scope routes the (device_id, event_time)
  -- pairs telemetry.recover_failed_raw_messages queued when it re-inserted
  -- normalized_points rows under their original platform_received_at, which
  -- is below every receipt window. The batch is fixed here (one run at a
  -- time: the advisory lock above), read below instead of the receipt window
  -- and marked routed in this transaction; a failed run leaves it pending.
  IF v_scope = 'recovery' THEN
    v_queue_ids := ARRAY(
      SELECT q.id FROM telemetry.routing_recovery_queue q
      WHERE q.energy_routed_at IS NULL
      ORDER BY q.id
      LIMIT 10000
    );
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
  -- A one-minute replay is sufficient to protect timestamp-boundary races
  -- without rescanning the full late-arrival tolerance on every run.
  p_overlap := LEAST(p_overlap, INTERVAL '1 minute');

  v_window_start := CASE WHEN v_previous_checkpoint IS NULL THEN '-infinity'::timestamptz ELSE v_previous_checkpoint-p_overlap END;

  WITH window_events AS MATERIALIZED
  (
    SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
    FROM telemetry.normalized_points np
    WHERE np.platform_received_at > v_window_start
      AND np.platform_received_at <= v_window_end
      AND np.event_time >= v_event_min
      AND np.event_time < v_event_max
      AND v_scope <> 'recovery'
    GROUP BY np.device_id,np.event_time
    UNION ALL
    -- Migration 305: recovery scope -- the queued pairs, whatever their
    -- receipt time or chunk.
    SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
    FROM telemetry.routing_recovery_queue q
    JOIN telemetry.normalized_points np ON np.device_id=q.device_id AND np.event_time=q.event_time
    WHERE v_scope = 'recovery'
      AND q.id = ANY(v_queue_ids)
    GROUP BY np.device_id,np.event_time
  ),
  full_resolution AS MATERIALIZED
  (
WITH profile_context AS
(
  SELECT
    np.event_time,
    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id,
    np.logical_point_id,
    np.device_uid,
    np.logical_point,
    np.raw_field_name,
    np.raw_value,
    np.numeric_value,
    np.quality_code,
    np.mapping_source,
    np.created_at,
    np.platform_received_at,
    np.raw_message_id,
    d.profile_id,
    dp.profile_code
  FROM window_events we
  CROSS JOIN LATERAL
  (
    SELECT src_np.*
    FROM telemetry.normalized_points src_np
    WHERE src_np.device_id = we.device_id
      AND src_np.event_time = we.event_time
    OFFSET 0
  ) np
  JOIN metadata.devices d ON d.id=np.device_id
  LEFT JOIN config.device_profiles dp ON dp.id=d.profile_id
),
register_scales AS
(
  SELECT pc.*, ers.scale_to_normalized_unit
  FROM profile_context pc
  LEFT JOIN config.energy_register_semantics ers
    ON ers.profile_id=pc.profile_id
   AND ers.logical_point_id=pc.logical_point_id
   AND ers.is_active=TRUE
),
pivoted AS
(
  SELECT
        rs.event_time AS received_at,
        rs.event_time AS source_timestamp,
        rs.organization_id,
        rs.site_id,
        rs.gateway_id,
        rs.device_id,
        NULL::UUID AS asset_id,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_total_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l1_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l2_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_IMPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_l3_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_total_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l1_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l2_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_EXPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_l3_wh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_TOTAL', 'ENERGY_REACTIVE_ENERGY_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L1', 'ENERGY_REACTIVE_ENERGY_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L2', 'ENERGY_REACTIVE_ENERGY_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_ENERGY_L3', 'ENERGY_REACTIVE_ENERGY_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_l3_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_total_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l1_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l2_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_l3_varh,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_TOTAL', 'ENERGY_APPARENT_ENERGY_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_total_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L1', 'ENERGY_APPARENT_ENERGY_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l1_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L2', 'ENERGY_APPARENT_ENERGY_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l2_vah,

        MAX(rs.numeric_value * rs.scale_to_normalized_unit) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_ENERGY_L3', 'ENERGY_APPARENT_ENERGY_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_l3_vah,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_TOTAL', 'ENERGY_ACTIVE_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_total_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L1', 'ENERGY_ACTIVE_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l1_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L2', 'ENERGY_ACTIVE_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l2_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['ACTIVE_POWER_L3', 'ENERGY_ACTIVE_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS active_power_l3_w,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_TOTAL', 'ENERGY_REACTIVE_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_total_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L1', 'ENERGY_REACTIVE_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l1_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L2', 'ENERGY_REACTIVE_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l2_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['REACTIVE_POWER_L3', 'ENERGY_REACTIVE_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS reactive_power_l3_var,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_TOTAL', 'ENERGY_APPARENT_POWER_TOTAL'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_total_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L1', 'ENERGY_APPARENT_POWER_L1'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l1_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L2', 'ENERGY_APPARENT_POWER_L2'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l2_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = ANY (ARRAY['APPARENT_POWER_L3', 'ENERGY_APPARENT_POWER_L3'])
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS apparent_power_l3_va,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_LN_AVG'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_ln_avg_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l1_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l2_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l3_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_LL_AVG'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_ll_avg_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L12'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l12_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L23'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l23_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'VOLTAGE_L31'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS voltage_l31_v,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_total_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l1_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l2_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_l3_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_NEUTRAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS neutral_current_a,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_total,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l1,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l2,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'POWER_FACTOR_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS power_factor_l3,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'FREQUENCY'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS frequency_hz,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l1_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l2_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PHASE_ANGLE_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS phase_angle_l3_deg,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_total_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l1_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l2_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'CURRENT_THD_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::DOUBLE PRECISION AS current_thd_l3_percent,

        MAX(rs.numeric_value) FILTER (
            WHERE rs.logical_point = 'PULSE_COUNT'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        )::BIGINT AS pulse_count,

        COUNT(*) FILTER (WHERE rs.quality_code='GOOD' AND rs.numeric_value IS NOT NULL) AS populated_point_count,
        COUNT(*) FILTER (WHERE rs.quality_code='INVALID_NUMERIC') AS invalid_point_count
  FROM register_scales rs
  GROUP BY rs.event_time, rs.organization_id, rs.site_id, rs.gateway_id, rs.device_id
)
SELECT *
FROM pivoted
WHERE num_nonnulls
(
    import_energy_total_wh,
    import_energy_l1_wh,
    import_energy_l2_wh,
    import_energy_l3_wh,
    export_energy_total_wh,
    export_energy_l1_wh,
    export_energy_l2_wh,
    export_energy_l3_wh,
    reactive_energy_total_varh,
    reactive_energy_l1_varh,
    reactive_energy_l2_varh,
    reactive_energy_l3_varh,
    reactive_export_energy_total_varh,
    reactive_export_energy_l1_varh,
    reactive_export_energy_l2_varh,
    reactive_export_energy_l3_varh,
    apparent_energy_total_vah,
    apparent_energy_l1_vah,
    apparent_energy_l2_vah,
    apparent_energy_l3_vah,
    active_power_total_w,
    active_power_l1_w,
    active_power_l2_w,
    active_power_l3_w,
    reactive_power_total_var,
    reactive_power_l1_var,
    reactive_power_l2_var,
    reactive_power_l3_var,
    apparent_power_total_va,
    apparent_power_l1_va,
    apparent_power_l2_va,
    apparent_power_l3_va,
    voltage_ln_avg_v,
    voltage_l1_v,
    voltage_l2_v,
    voltage_l3_v,
    voltage_ll_avg_v,
    voltage_l12_v,
    voltage_l23_v,
    voltage_l31_v,
    current_total_a,
    current_l1_a,
    current_l2_a,
    current_l3_a,
    neutral_current_a,
    power_factor_total,
    power_factor_l1,
    power_factor_l2,
    power_factor_l3,
    frequency_hz,
    phase_angle_l1_deg,
    phase_angle_l2_deg,
    phase_angle_l3_deg,
    current_thd_total_percent,
    current_thd_l1_percent,
    current_thd_l2_percent,
    current_thd_l3_percent,
    pulse_count
) > 0
  ),
  resolved AS
  (
    SELECT fr.*,bucket.policy_id,bucket.capture_interval_seconds,
           bucket.late_arrival_tolerance_seconds,bucket.bucket_start
    FROM full_resolution fr
    CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
      (fr.site_id,COALESCE(fr.source_timestamp,fr.received_at)) AS bucket
  ),
  ranked AS
  (
    SELECT resolved.*,
           row_number() OVER
           (
             PARTITION BY resolved.device_id,resolved.policy_id,resolved.bucket_start
             ORDER BY COALESCE(resolved.source_timestamp,resolved.received_at) DESC,
                      resolved.received_at DESC
           ) AS sample_rank
    FROM resolved
  )
  INSERT INTO telemetry.energy_measurements
  (
        bucket_start, received_at, source_timestamp, organization_id, site_id, gateway_id, device_id, asset_id,
        import_energy_total_wh,
        import_energy_l1_wh,
        import_energy_l2_wh,
        import_energy_l3_wh,
        export_energy_total_wh,
        export_energy_l1_wh,
        export_energy_l2_wh,
        export_energy_l3_wh,
        reactive_energy_total_varh,
        reactive_energy_l1_varh,
        reactive_energy_l2_varh,
        reactive_energy_l3_varh,
        reactive_export_energy_total_varh,
        reactive_export_energy_l1_varh,
        reactive_export_energy_l2_varh,
        reactive_export_energy_l3_varh,
        apparent_energy_total_vah,
        apparent_energy_l1_vah,
        apparent_energy_l2_vah,
        apparent_energy_l3_vah,
        active_power_total_w,
        active_power_l1_w,
        active_power_l2_w,
        active_power_l3_w,
        reactive_power_total_var,
        reactive_power_l1_var,
        reactive_power_l2_var,
        reactive_power_l3_var,
        apparent_power_total_va,
        apparent_power_l1_va,
        apparent_power_l2_va,
        apparent_power_l3_va,
        voltage_ln_avg_v,
        voltage_l1_v,
        voltage_l2_v,
        voltage_l3_v,
        voltage_ll_avg_v,
        voltage_l12_v,
        voltage_l23_v,
        voltage_l31_v,
        current_total_a,
        current_l1_a,
        current_l2_a,
        current_l3_a,
        neutral_current_a,
        power_factor_total,
        power_factor_l1,
        power_factor_l2,
        power_factor_l3,
        frequency_hz,
        phase_angle_l1_deg,
        phase_angle_l2_deg,
        phase_angle_l3_deg,
        current_thd_total_percent,
        current_thd_l1_percent,
        current_thd_l2_percent,
        current_thd_l3_percent,
        pulse_count,
        is_estimated
  )
  SELECT
        r.bucket_start, we.platform_received_at, r.source_timestamp, r.organization_id, r.site_id, r.gateway_id, r.device_id, r.asset_id,
        r.import_energy_total_wh,
        r.import_energy_l1_wh,
        r.import_energy_l2_wh,
        r.import_energy_l3_wh,
        r.export_energy_total_wh,
        r.export_energy_l1_wh,
        r.export_energy_l2_wh,
        r.export_energy_l3_wh,
        r.reactive_energy_total_varh,
        r.reactive_energy_l1_varh,
        r.reactive_energy_l2_varh,
        r.reactive_energy_l3_varh,
        r.reactive_export_energy_total_varh,
        r.reactive_export_energy_l1_varh,
        r.reactive_export_energy_l2_varh,
        r.reactive_export_energy_l3_varh,
        r.apparent_energy_total_vah,
        r.apparent_energy_l1_vah,
        r.apparent_energy_l2_vah,
        r.apparent_energy_l3_vah,
        r.active_power_total_w,
        r.active_power_l1_w,
        r.active_power_l2_w,
        r.active_power_l3_w,
        r.reactive_power_total_var,
        r.reactive_power_l1_var,
        r.reactive_power_l2_var,
        r.reactive_power_l3_var,
        r.apparent_power_total_va,
        r.apparent_power_l1_va,
        r.apparent_power_l2_va,
        r.apparent_power_l3_va,
        r.voltage_ln_avg_v,
        r.voltage_l1_v,
        r.voltage_l2_v,
        r.voltage_l3_v,
        r.voltage_ll_avg_v,
        r.voltage_l12_v,
        r.voltage_l23_v,
        r.voltage_l31_v,
        r.current_total_a,
        r.current_l1_a,
        r.current_l2_a,
        r.current_l3_a,
        r.neutral_current_a,
        r.power_factor_total,
        r.power_factor_l1,
        r.power_factor_l2,
        r.power_factor_l3,
        r.frequency_hz,
        r.phase_angle_l1_deg,
        r.phase_angle_l2_deg,
        r.phase_angle_l3_deg,
        r.current_thd_total_percent,
        r.current_thd_l1_percent,
        r.current_thd_l2_percent,
        r.current_thd_l3_percent,
        r.pulse_count,
        FALSE
  FROM ranked r
  JOIN window_events we
    ON we.device_id=r.device_id AND we.event_time=r.source_timestamp
  WHERE r.sample_rank=1
    AND r.bucket_start + make_interval(secs => COALESCE(r.capture_interval_seconds,1)) <= v_now
  ON CONFLICT (bucket_start,device_id) DO UPDATE
  SET
        received_at=EXCLUDED.received_at,
        source_timestamp=EXCLUDED.source_timestamp,
        organization_id=EXCLUDED.organization_id,
        site_id=EXCLUDED.site_id,
        gateway_id=EXCLUDED.gateway_id,
        asset_id=COALESCE(EXCLUDED.asset_id,telemetry.energy_measurements.asset_id),
        import_energy_total_wh = COALESCE(EXCLUDED.import_energy_total_wh, telemetry.energy_measurements.import_energy_total_wh),

        import_energy_l1_wh = COALESCE(EXCLUDED.import_energy_l1_wh, telemetry.energy_measurements.import_energy_l1_wh),

        import_energy_l2_wh = COALESCE(EXCLUDED.import_energy_l2_wh, telemetry.energy_measurements.import_energy_l2_wh),

        import_energy_l3_wh = COALESCE(EXCLUDED.import_energy_l3_wh, telemetry.energy_measurements.import_energy_l3_wh),

        export_energy_total_wh = COALESCE(EXCLUDED.export_energy_total_wh, telemetry.energy_measurements.export_energy_total_wh),

        export_energy_l1_wh = COALESCE(EXCLUDED.export_energy_l1_wh, telemetry.energy_measurements.export_energy_l1_wh),

        export_energy_l2_wh = COALESCE(EXCLUDED.export_energy_l2_wh, telemetry.energy_measurements.export_energy_l2_wh),

        export_energy_l3_wh = COALESCE(EXCLUDED.export_energy_l3_wh, telemetry.energy_measurements.export_energy_l3_wh),

        reactive_energy_total_varh = COALESCE(EXCLUDED.reactive_energy_total_varh, telemetry.energy_measurements.reactive_energy_total_varh),

        reactive_energy_l1_varh = COALESCE(EXCLUDED.reactive_energy_l1_varh, telemetry.energy_measurements.reactive_energy_l1_varh),

        reactive_energy_l2_varh = COALESCE(EXCLUDED.reactive_energy_l2_varh, telemetry.energy_measurements.reactive_energy_l2_varh),

        reactive_energy_l3_varh = COALESCE(EXCLUDED.reactive_energy_l3_varh, telemetry.energy_measurements.reactive_energy_l3_varh),

        reactive_export_energy_total_varh = COALESCE(EXCLUDED.reactive_export_energy_total_varh, telemetry.energy_measurements.reactive_export_energy_total_varh),

        reactive_export_energy_l1_varh = COALESCE(EXCLUDED.reactive_export_energy_l1_varh, telemetry.energy_measurements.reactive_export_energy_l1_varh),

        reactive_export_energy_l2_varh = COALESCE(EXCLUDED.reactive_export_energy_l2_varh, telemetry.energy_measurements.reactive_export_energy_l2_varh),

        reactive_export_energy_l3_varh = COALESCE(EXCLUDED.reactive_export_energy_l3_varh, telemetry.energy_measurements.reactive_export_energy_l3_varh),

        apparent_energy_total_vah = COALESCE(EXCLUDED.apparent_energy_total_vah, telemetry.energy_measurements.apparent_energy_total_vah),

        apparent_energy_l1_vah = COALESCE(EXCLUDED.apparent_energy_l1_vah, telemetry.energy_measurements.apparent_energy_l1_vah),

        apparent_energy_l2_vah = COALESCE(EXCLUDED.apparent_energy_l2_vah, telemetry.energy_measurements.apparent_energy_l2_vah),

        apparent_energy_l3_vah = COALESCE(EXCLUDED.apparent_energy_l3_vah, telemetry.energy_measurements.apparent_energy_l3_vah),

        active_power_total_w = COALESCE(EXCLUDED.active_power_total_w, telemetry.energy_measurements.active_power_total_w),

        active_power_l1_w = COALESCE(EXCLUDED.active_power_l1_w, telemetry.energy_measurements.active_power_l1_w),

        active_power_l2_w = COALESCE(EXCLUDED.active_power_l2_w, telemetry.energy_measurements.active_power_l2_w),

        active_power_l3_w = COALESCE(EXCLUDED.active_power_l3_w, telemetry.energy_measurements.active_power_l3_w),

        reactive_power_total_var = COALESCE(EXCLUDED.reactive_power_total_var, telemetry.energy_measurements.reactive_power_total_var),

        reactive_power_l1_var = COALESCE(EXCLUDED.reactive_power_l1_var, telemetry.energy_measurements.reactive_power_l1_var),

        reactive_power_l2_var = COALESCE(EXCLUDED.reactive_power_l2_var, telemetry.energy_measurements.reactive_power_l2_var),

        reactive_power_l3_var = COALESCE(EXCLUDED.reactive_power_l3_var, telemetry.energy_measurements.reactive_power_l3_var),

        apparent_power_total_va = COALESCE(EXCLUDED.apparent_power_total_va, telemetry.energy_measurements.apparent_power_total_va),

        apparent_power_l1_va = COALESCE(EXCLUDED.apparent_power_l1_va, telemetry.energy_measurements.apparent_power_l1_va),

        apparent_power_l2_va = COALESCE(EXCLUDED.apparent_power_l2_va, telemetry.energy_measurements.apparent_power_l2_va),

        apparent_power_l3_va = COALESCE(EXCLUDED.apparent_power_l3_va, telemetry.energy_measurements.apparent_power_l3_va),

        voltage_ln_avg_v = COALESCE(EXCLUDED.voltage_ln_avg_v, telemetry.energy_measurements.voltage_ln_avg_v),

        voltage_l1_v = COALESCE(EXCLUDED.voltage_l1_v, telemetry.energy_measurements.voltage_l1_v),

        voltage_l2_v = COALESCE(EXCLUDED.voltage_l2_v, telemetry.energy_measurements.voltage_l2_v),

        voltage_l3_v = COALESCE(EXCLUDED.voltage_l3_v, telemetry.energy_measurements.voltage_l3_v),

        voltage_ll_avg_v = COALESCE(EXCLUDED.voltage_ll_avg_v, telemetry.energy_measurements.voltage_ll_avg_v),

        voltage_l12_v = COALESCE(EXCLUDED.voltage_l12_v, telemetry.energy_measurements.voltage_l12_v),

        voltage_l23_v = COALESCE(EXCLUDED.voltage_l23_v, telemetry.energy_measurements.voltage_l23_v),

        voltage_l31_v = COALESCE(EXCLUDED.voltage_l31_v, telemetry.energy_measurements.voltage_l31_v),

        current_total_a = COALESCE(EXCLUDED.current_total_a, telemetry.energy_measurements.current_total_a),

        current_l1_a = COALESCE(EXCLUDED.current_l1_a, telemetry.energy_measurements.current_l1_a),

        current_l2_a = COALESCE(EXCLUDED.current_l2_a, telemetry.energy_measurements.current_l2_a),

        current_l3_a = COALESCE(EXCLUDED.current_l3_a, telemetry.energy_measurements.current_l3_a),

        neutral_current_a = COALESCE(EXCLUDED.neutral_current_a, telemetry.energy_measurements.neutral_current_a),

        power_factor_total = COALESCE(EXCLUDED.power_factor_total, telemetry.energy_measurements.power_factor_total),

        power_factor_l1 = COALESCE(EXCLUDED.power_factor_l1, telemetry.energy_measurements.power_factor_l1),

        power_factor_l2 = COALESCE(EXCLUDED.power_factor_l2, telemetry.energy_measurements.power_factor_l2),

        power_factor_l3 = COALESCE(EXCLUDED.power_factor_l3, telemetry.energy_measurements.power_factor_l3),

        frequency_hz = COALESCE(EXCLUDED.frequency_hz, telemetry.energy_measurements.frequency_hz),

        phase_angle_l1_deg = COALESCE(EXCLUDED.phase_angle_l1_deg, telemetry.energy_measurements.phase_angle_l1_deg),

        phase_angle_l2_deg = COALESCE(EXCLUDED.phase_angle_l2_deg, telemetry.energy_measurements.phase_angle_l2_deg),

        phase_angle_l3_deg = COALESCE(EXCLUDED.phase_angle_l3_deg, telemetry.energy_measurements.phase_angle_l3_deg),

        current_thd_total_percent = COALESCE(EXCLUDED.current_thd_total_percent, telemetry.energy_measurements.current_thd_total_percent),

        current_thd_l1_percent = COALESCE(EXCLUDED.current_thd_l1_percent, telemetry.energy_measurements.current_thd_l1_percent),

        current_thd_l2_percent = COALESCE(EXCLUDED.current_thd_l2_percent, telemetry.energy_measurements.current_thd_l2_percent),

        current_thd_l3_percent = COALESCE(EXCLUDED.current_thd_l3_percent, telemetry.energy_measurements.current_thd_l3_percent),

        pulse_count = COALESCE(EXCLUDED.pulse_count, telemetry.energy_measurements.pulse_count),
        is_estimated=FALSE
  WHERE
        COALESCE(EXCLUDED.source_timestamp, EXCLUDED.received_at)
            > COALESCE(
                telemetry.energy_measurements.source_timestamp,
                telemetry.energy_measurements.received_at,
                '-infinity'::timestamptz
              )
    AND v_now <= telemetry.capture_bucket_correction_deadline
    (
        EXCLUDED.site_id,
        EXCLUDED.bucket_start
    );

  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
  -- Migration 305: the fixed queue batch is routed by this transaction.
  IF v_scope = 'recovery' THEN
    UPDATE telemetry.routing_recovery_queue SET energy_routed_at=clock_timestamp()
    WHERE id = ANY(v_queue_ids);
  END IF;
  UPDATE telemetry.pipeline_state
  SET last_received_at=v_window_end,last_completed_at=clock_timestamp(),last_inserted_rows=v_affected_rows,
      last_status='SUCCESS',last_error=NULL,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE NOTICE 'Closed-bucket energy routing succeeded: window=(%, %], affected_rows=%',v_window_start,v_window_end,v_affected_rows;
EXCEPTION WHEN OTHERS THEN
  UPDATE telemetry.pipeline_state
  SET last_completed_at=clock_timestamp(),last_inserted_rows=0,last_status='FAILED',
      last_error=SQLSTATE||': '||SQLERRM,updated_at=now()
  WHERE pipeline_name=v_pipeline_name;
  RAISE;
END;
$procedure$;


-- ----------------------------------------------------------------------------
-- 5. Environment loader: the regenerated offline-generator artifact, verbatim.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental(IN p_overlap interval DEFAULT '00:15:00'::interval, IN p_max_window interval DEFAULT NULL)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    -- Migration 303: ems.routing_scope (transaction-local; set only by
    -- telemetry.run_routing_late_sweep_job) selects the late-data sweep.
    v_scope CONSTANT TEXT := COALESCE(NULLIF(current_setting('ems.routing_scope', true), ''), 'forward');
    -- Migration 305: ems.routing_scope = 'recovery' (set only by the late-sweep
    -- job) routes the pairs queued in telemetry.routing_recovery_queue.
    v_pipeline_name CONSTANT TEXT := CASE v_scope WHEN 'late_sweep' THEN 'environment_measurements_late_sweep' WHEN 'recovery' THEN 'environment_measurements_recovery' ELSE 'environment_measurements' END;
    v_queue_ids BIGINT[] := '{}';
    v_event_min TIMESTAMPTZ;
    v_event_max TIMESTAMPTZ;
    v_forward_checkpoint TIMESTAMPTZ;
    v_previous_checkpoint TIMESTAMPTZ;
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
    v_updated BIGINT := 0;
    v_inserted BIGINT := 0;
    v_lock_acquired BOOLEAN;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_update_floor TIMESTAMPTZ;
BEGIN
    IF p_overlap IS NULL OR p_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_overlap must be zero or positive';
    END IF;

    -- Migration 207: reject a non-positive explicit bound. NULL (the
    -- default, and what a direct/manual invocation passes) means "no
    -- bound" -- byte-for-byte the pre-207 behaviour.
    IF p_max_window IS NOT NULL AND p_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_max_window must be positive when supplied; received %', p_max_window;
    END IF;

    -- Migration 303: reject an unknown scope.
    IF v_scope NOT IN ('forward', 'late_sweep', 'recovery') THEN
        RAISE EXCEPTION 'ems.routing_scope must be forward, late_sweep or recovery; received %', v_scope;
    END IF;

    SELECT pg_try_advisory_xact_lock(hashtextextended('telemetry.load_environment_measurements_incremental',0))
    INTO v_lock_acquired;
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status='SKIPPED_LOCKED', last_error=NULL, updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_previous_checkpoint
    FROM telemetry.pipeline_state
    WHERE pipeline_name=v_pipeline_name
    FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at=clock_timestamp(), last_status='RUNNING', last_error=NULL, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    -- Migration 267: bound the window-end lookup to recent event_time so it only
    -- reads uncompressed chunks (normalized_points compress_after = 1 day). The
    -- bounded max can only be lower than the global max, which delays -- never
    -- skips -- rows; the global lookup remains the fallback when no row has a
    -- recent event_time.
    SELECT max(platform_received_at) INTO v_window_end
    FROM telemetry.normalized_points
    WHERE platform_received_at IS NOT NULL
      AND event_time >= now() - INTERVAL '1 day';
    IF v_window_end IS NULL THEN
      SELECT max(platform_received_at) INTO v_window_end
      FROM telemetry.normalized_points
      WHERE platform_received_at IS NOT NULL;
    END IF;
    IF v_window_end IS NULL THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
            last_status='NO_SOURCE_DATA', updated_at=now()
        WHERE pipeline_name=v_pipeline_name;
        RETURN;
    END IF;

    -- Migration 207: cap the forward processing boundary to the previous
    -- checkpoint plus p_max_window when a caller supplies one and a
    -- previous checkpoint already exists. NULL (the default) leaves
    -- v_window_end exactly as computed above -- byte-for-byte the
    -- pre-207 behaviour. See telemetry.load_energy_measurements_incremental
    -- for the full rationale; this is the identical bound applied to the
    -- environment routing loader. Advisory lock, checkpoint keying,
    -- overlap semantics, the routing/calculation SQL below, and the
    -- EXCEPTION-rolls-back-the-watermark contract are all unchanged.
    IF p_max_window IS NOT NULL AND v_previous_checkpoint IS NOT NULL THEN
        v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
    END IF;

    -- Migration 303: forward runs read only normalized_points chunks newer
    -- than the newest compressed chunk (event_time >= its range_end), so
    -- chunk exclusion skips every compressed chunk instead of scanning its
    -- batch metadata on every run. Rows older than that floor (late data in
    -- compressed chunks) are routed by the hourly late-data sweep, which reads
    -- only event_time < floor and never passes the forward checkpoint.
    SELECT max(c.range_end) INTO v_event_min
    FROM timescaledb_information.chunks c
    WHERE c.hypertable_schema='telemetry'
      AND c.hypertable_name='normalized_points'
      AND c.is_compressed;
    v_event_min := COALESCE(v_event_min, '-infinity'::timestamptz);
    v_event_max := 'infinity'::timestamptz;
    IF v_scope = 'late_sweep' THEN
        v_event_max := v_event_min;
        v_event_min := '-infinity'::timestamptz;
        SELECT last_received_at INTO v_forward_checkpoint
        FROM telemetry.pipeline_state WHERE pipeline_name='environment_measurements';
        v_window_end := LEAST(v_window_end, COALESCE(v_forward_checkpoint, '-infinity'::timestamptz));
        IF v_previous_checkpoint IS NOT NULL THEN
            v_window_end := GREATEST(v_window_end, v_previous_checkpoint);
        END IF;
    END IF;

    -- Migration 305: the recovery scope routes the (device_id, event_time)
    -- pairs telemetry.recover_failed_raw_messages queued when it re-inserted
    -- normalized_points rows under their original platform_received_at, which
    -- is below every receipt window. The batch is fixed here (one run at a
    -- time: the advisory lock above), read below instead of the receipt window
    -- and marked routed in this transaction; a failed run leaves it pending.
    IF v_scope = 'recovery' THEN
        v_queue_ids := ARRAY(
            SELECT q.id FROM telemetry.routing_recovery_queue q
            WHERE q.environment_routed_at IS NULL
            ORDER BY q.id
            LIMIT 10000
        );
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
    -- discovered by their new platform receipt timestamp, so the historical
    -- correction tolerance does not need to be rescanned every minute.
    p_overlap := LEAST(p_overlap, INTERVAL '1 minute');

    v_window_start := CASE WHEN v_previous_checkpoint IS NULL
                           THEN '-infinity'::TIMESTAMPTZ
                           ELSE v_previous_checkpoint - p_overlap END;

    CREATE TEMP TABLE tmp_environment_candidates ON COMMIT DROP AS
    WITH window_events AS MATERIALIZED
    (
      SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
      FROM telemetry.normalized_points np
      JOIN metadata.devices d ON d.id=np.device_id
      JOIN config.device_profiles dp ON dp.id=d.profile_id
      WHERE np.platform_received_at > v_window_start
        AND np.platform_received_at <= v_window_end
        AND np.event_time >= v_event_min
        AND np.event_time < v_event_max
        AND v_scope <> 'recovery'
        AND dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND np.logical_point IN
        (
            'ENV_TEMPERATURE',
            'ENV_RELATIVE_HUMIDITY',
            'ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY',
            'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW',
            'EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE',
            'BATTERY_VOLTAGE',
            'DEVICE_STATUS_CODE'
        )
      GROUP BY np.device_id,np.event_time
      UNION ALL
      -- Migration 305: recovery scope -- the queued pairs, whatever their
      -- receipt time or chunk.
      SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
      FROM telemetry.routing_recovery_queue q
      JOIN telemetry.normalized_points np ON np.device_id=q.device_id AND np.event_time=q.event_time
      JOIN metadata.devices d ON d.id=np.device_id
      JOIN config.device_profiles dp ON dp.id=d.profile_id
      WHERE v_scope = 'recovery'
        AND q.id = ANY(v_queue_ids)
        AND dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND np.logical_point IN
        (
            'ENV_TEMPERATURE',
            'ENV_RELATIVE_HUMIDITY',
            'ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY',
            'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW',
            'EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE',
            'BATTERY_VOLTAGE',
            'DEVICE_STATUS_CODE'
        )
      GROUP BY np.device_id,np.event_time
    ),
    full_resolution AS MATERIALIZED
    (
SELECT
    MAX(np.platform_received_at) AS received_at,
    np.event_time AS source_timestamp,
    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id,
    NULL::UUID AS asset_id,
    NULL::SMALLINT AS measurement_interval_seconds,
    NULL::SMALLINT AS quality_code,
    FALSE AS is_estimated,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_TEMPERATURE')::DOUBLE PRECISION AS temperature_c,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_RELATIVE_HUMIDITY')::DOUBLE PRECISION AS humidity_percent,
    NULL::DOUBLE PRECISION AS pressure_hpa,
    NULL::DOUBLE PRECISION AS co2_ppm,
    NULL::DOUBLE PRECISION AS voc_ppb,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point IN ('BATTERY_VOLTAGE','DEVICE_BATTERY_VOLTAGE'))::DOUBLE PRECISION AS battery_voltage_v,
    NULL::DOUBLE PRECISION AS signal_strength_dbm,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'ENV_ILLUMINANCE_LUX')::DOUBLE PRECISION AS illuminance_lux,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'OCCUPANCY_ACTIVITY')::DOUBLE PRECISION AS occupancy_activity,
    NULL::BIGINT AS raw_archive_id,
    ROUND(MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT'))::INTEGER AS seconds_since_last_pir_event,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'PULSE_INPUT_1_RAW')::DOUBLE PRECISION AS pulse_input_1_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_1_RAW')::DOUBLE PRECISION AS external_input_1_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_2_RAW')::DOUBLE PRECISION AS external_input_2_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_3_RAW')::DOUBLE PRECISION AS external_input_3_raw,
    MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'EXTERNAL_SENSOR_INPUT_4_RAW')::DOUBLE PRECISION AS external_input_4_raw,
    ROUND(MAX(np.numeric_value) FILTER (WHERE np.logical_point = 'DEVICE_STATUS_CODE'))::INTEGER AS device_status_code
FROM window_events we
CROSS JOIN LATERAL
(
  SELECT src_np.*
  FROM telemetry.normalized_points src_np
  WHERE src_np.device_id = we.device_id
    AND src_np.event_time = we.event_time
  OFFSET 0
) np
JOIN metadata.devices d ON d.id = np.device_id
JOIN config.device_profiles dp ON dp.id = d.profile_id
WHERE dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
  AND np.logical_point IN
  (
      'ENV_TEMPERATURE',
      'ENV_RELATIVE_HUMIDITY',
      'ENV_ILLUMINANCE_LUX',
      'OCCUPANCY_ACTIVITY',
      'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
      'PULSE_INPUT_1_RAW',
      'EXTERNAL_SENSOR_INPUT_1_RAW',
      'EXTERNAL_SENSOR_INPUT_2_RAW',
      'EXTERNAL_SENSOR_INPUT_3_RAW',
      'EXTERNAL_SENSOR_INPUT_4_RAW',
      'DEVICE_BATTERY_VOLTAGE',
      'BATTERY_VOLTAGE',
      'DEVICE_STATUS_CODE'
  )
GROUP BY np.event_time, np.organization_id, np.site_id, np.gateway_id, np.device_id
    ),
    resolved AS
    (
      SELECT fr.*,b.policy_id,b.capture_interval_seconds,
             b.late_arrival_tolerance_seconds,b.bucket_start
      FROM full_resolution fr
      CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
        (fr.site_id,COALESCE(fr.source_timestamp,fr.received_at)) AS b
    ),
    ranked AS
    (
      SELECT resolved.*,
             row_number() OVER
             (
               PARTITION BY resolved.device_id,resolved.policy_id,resolved.bucket_start
               ORDER BY COALESCE(resolved.source_timestamp,resolved.received_at) DESC,
                        resolved.received_at DESC NULLS LAST
             ) AS sample_rank
      FROM resolved
    )
    SELECT ranked.bucket_start,
           COALESCE(we.platform_received_at,ranked.received_at) AS received_at,
           ranked.source_timestamp,ranked.organization_id,ranked.site_id,ranked.gateway_id,
           ranked.device_id,ranked.asset_id,
           -- Migration 226: point-in-time, tenant-guarded Space resolution.
           -- A correlated scalar sub-select over metadata.space_points for
           -- the environmental logical points, effective at this reading's
           -- event time, restricted to the same organization as the row.
           -- (array_agg(DISTINCT space_id))[1] ... HAVING count(DISTINCT ...) = 1:
           --   * exactly one applicable Space  -> that space_id
           --   * no applicable binding         -> no row -> NULL
           --   * two or more distinct Spaces   -> HAVING fails -> NULL (never guesses)
           -- (core PostgreSQL has no max()/min() aggregate for uuid, so the
           -- single value is taken from a DISTINCT array gated by the count.)
           -- Uses metadata.space_points' migration-224 effective_range
           -- (a generated [) tstzrange; effective_to IS NULL => 'infinity').
           -- No row fan-out of the outer query.
           (
               SELECT (array_agg(DISTINCT sp.space_id))[1]
               FROM metadata.space_points sp
               JOIN metadata.spaces sps ON sps.id = sp.space_id
               WHERE sp.logical_point_id IN
               (
                   SELECT lp.id
                   FROM metadata.logical_points lp
                   WHERE lp.name IN
                   (
                       'ENV_TEMPERATURE',
                       'ENV_RELATIVE_HUMIDITY',
                       'ENV_ILLUMINANCE_LUX',
                       'OCCUPANCY_ACTIVITY',
                       'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
                       'PULSE_INPUT_1_RAW',
                       'EXTERNAL_SENSOR_INPUT_1_RAW',
                       'EXTERNAL_SENSOR_INPUT_2_RAW',
                       'EXTERNAL_SENSOR_INPUT_3_RAW',
                       'EXTERNAL_SENSOR_INPUT_4_RAW',
                       'DEVICE_BATTERY_VOLTAGE',
                       'BATTERY_VOLTAGE',
                       'DEVICE_STATUS_CODE'
                   )
               )
                 AND sp.effective_range @> COALESCE(ranked.source_timestamp, ranked.received_at)
                 AND sps.organization_id = ranked.organization_id
                 -- Migration 228: scope Space resolution to the Point instance of
                 -- THIS device -- (device_id, logical_point_id) is the
                 -- config.device_point_configuration PK. metadata.logical_points
                 -- is a global vocabulary, so a fleet of identical devices shares
                 -- one logical_point_id; without this predicate every same-org
                 -- device would resolve to a single Space. asset_devices is
                 -- unrelated / unchanged.
                 AND sp.device_id = ranked.device_id
               HAVING count(DISTINCT sp.space_id) = 1
           ) AS space_id,
           COALESCE(ranked.capture_interval_seconds,ranked.measurement_interval_seconds) AS measurement_interval_seconds,
           ranked.quality_code,ranked.is_estimated,
           ranked.temperature_c,
           ranked.humidity_percent,
           ranked.pressure_hpa,
           ranked.co2_ppm,
           ranked.voc_ppb,
           ranked.battery_voltage_v,
           ranked.signal_strength_dbm,
           ranked.illuminance_lux,
           ranked.occupancy_activity,
           ranked.raw_archive_id,
           ranked.seconds_since_last_pir_event,
           ranked.pulse_input_1_raw,
           ranked.external_input_1_raw,
           ranked.external_input_2_raw,
           ranked.external_input_3_raw,
           ranked.external_input_4_raw,
           ranked.device_status_code,
           ranked.bucket_start + make_interval(secs => ranked.capture_interval_seconds)
             + make_interval(secs => ranked.late_arrival_tolerance_seconds) AS correction_deadline
    FROM ranked
    JOIN window_events we
      ON we.device_id=ranked.device_id AND we.event_time=ranked.source_timestamp
    WHERE ranked.sample_rank=1
      AND ranked.bucket_start + make_interval(secs => COALESCE(ranked.capture_interval_seconds,1)) <= v_now;

    CREATE UNIQUE INDEX ON tmp_environment_candidates(bucket_start,device_id);

    -- Migration 291: only candidates still inside their correction window
    -- (v_now <= correction_deadline) can be updated, so bound the UPDATE to
    -- the earliest such bucket_start. That keeps it out of compressed chunks,
    -- which it otherwise decompressed in full on every run.
    SELECT min(bucket_start) INTO v_update_floor
    FROM tmp_environment_candidates
    WHERE v_now <= correction_deadline;

    IF v_update_floor IS NOT NULL THEN
    UPDATE telemetry.environment_measurements t
    SET received_at=s.received_at,
        source_timestamp=s.source_timestamp,
        organization_id=s.organization_id,
        site_id=s.site_id,
        gateway_id=s.gateway_id,
        asset_id=COALESCE(s.asset_id,t.asset_id),
        space_id=COALESCE(s.space_id,t.space_id),
        measurement_interval_seconds=s.measurement_interval_seconds,
        quality_code=COALESCE(s.quality_code,t.quality_code),
        is_estimated=COALESCE(s.is_estimated,t.is_estimated),
        temperature_c=COALESCE(s.temperature_c,t.temperature_c),
        humidity_percent=COALESCE(s.humidity_percent,t.humidity_percent),
        pressure_hpa=COALESCE(s.pressure_hpa,t.pressure_hpa),
        co2_ppm=COALESCE(s.co2_ppm,t.co2_ppm),
        voc_ppb=COALESCE(s.voc_ppb,t.voc_ppb),
        battery_voltage_v=COALESCE(s.battery_voltage_v,t.battery_voltage_v),
        signal_strength_dbm=COALESCE(s.signal_strength_dbm,t.signal_strength_dbm),
        illuminance_lux=COALESCE(s.illuminance_lux,t.illuminance_lux),
        occupancy_activity=COALESCE(s.occupancy_activity,t.occupancy_activity),
        raw_archive_id=COALESCE(s.raw_archive_id,t.raw_archive_id),
        seconds_since_last_pir_event=COALESCE(s.seconds_since_last_pir_event,t.seconds_since_last_pir_event),
        pulse_input_1_raw=COALESCE(s.pulse_input_1_raw,t.pulse_input_1_raw),
        external_input_1_raw=COALESCE(s.external_input_1_raw,t.external_input_1_raw),
        external_input_2_raw=COALESCE(s.external_input_2_raw,t.external_input_2_raw),
        external_input_3_raw=COALESCE(s.external_input_3_raw,t.external_input_3_raw),
        external_input_4_raw=COALESCE(s.external_input_4_raw,t.external_input_4_raw),
        device_status_code=COALESCE(s.device_status_code,t.device_status_code)
    FROM tmp_environment_candidates s
    WHERE t.bucket_start >= v_update_floor
      AND t.bucket_start=s.bucket_start
      AND t.device_id=s.device_id
      AND COALESCE(s.source_timestamp,s.received_at) >
          COALESCE(t.source_timestamp,t.received_at,'-infinity'::TIMESTAMPTZ)
      AND v_now <= s.correction_deadline;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    END IF;

    INSERT INTO telemetry.environment_measurements
    (
      bucket_start, received_at, source_timestamp,
      organization_id, site_id, gateway_id, device_id, asset_id, space_id,
      measurement_interval_seconds, quality_code, is_estimated,
      temperature_c,
      humidity_percent,
      pressure_hpa,
      co2_ppm,
      voc_ppb,
      battery_voltage_v,
      signal_strength_dbm,
      illuminance_lux,
      occupancy_activity,
      raw_archive_id,
      seconds_since_last_pir_event,
      pulse_input_1_raw,
      external_input_1_raw,
      external_input_2_raw,
      external_input_3_raw,
      external_input_4_raw,
      device_status_code
    )
    SELECT
      s.bucket_start, s.received_at, s.source_timestamp,
      s.organization_id, s.site_id, s.gateway_id, s.device_id, s.asset_id, s.space_id,
      s.measurement_interval_seconds, s.quality_code, s.is_estimated,
      s.temperature_c,
      s.humidity_percent,
      s.pressure_hpa,
      s.co2_ppm,
      s.voc_ppb,
      s.battery_voltage_v,
      s.signal_strength_dbm,
      s.illuminance_lux,
      s.occupancy_activity,
      s.raw_archive_id,
      s.seconds_since_last_pir_event,
      s.pulse_input_1_raw,
      s.external_input_1_raw,
      s.external_input_2_raw,
      s.external_input_3_raw,
      s.external_input_4_raw,
      s.device_status_code
    FROM tmp_environment_candidates s
    ON CONFLICT (bucket_start,device_id) WHERE device_id IS NOT NULL DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    -- Migration 305: the fixed queue batch is routed by this transaction.
    IF v_scope = 'recovery' THEN
        UPDATE telemetry.routing_recovery_queue SET environment_routed_at=clock_timestamp()
        WHERE id = ANY(v_queue_ids);
    END IF;

    UPDATE telemetry.pipeline_state
    SET last_received_at=v_window_end,
        last_completed_at=clock_timestamp(),
        last_inserted_rows=v_updated+v_inserted,
        last_status='SUCCESS', last_error=NULL, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;

    RAISE NOTICE 'Environment routing succeeded: window=(%, %], updated=%, inserted=%',
      v_window_start, v_window_end, v_updated, v_inserted;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at=clock_timestamp(), last_inserted_rows=0,
        last_status='FAILED', last_error=SQLSTATE || ': ' || SQLERRM, updated_at=now()
    WHERE pipeline_name=v_pipeline_name;
    RAISE;
END;
$procedure$;

COMMENT ON PROCEDURE telemetry.load_environment_measurements_incremental(interval, interval) IS
'Incrementally routes closed-bucket normalized environment telemetry into telemetry.environment_measurements. Checkpoint is telemetry.pipeline_state(''environment_measurements'').last_received_at, keyed on telemetry.normalized_points.platform_received_at; a pg_try_advisory_xact_lock serialises concurrent runs; the single transaction''s EXCEPTION handler re-RAISEs, so a caught failure rolls back the watermark with the data. '
'Migration 207: p_max_window (default NULL) optionally caps the forward processing boundary to previous_checkpoint + p_max_window instead of always advancing to max(telemetry.normalized_points.platform_received_at). NULL preserves the exact prior behaviour. The scheduled wrapper telemetry.run_environment_routing_job passes a bounded value (default 2 hours, config.max_window-overridable) so an unattended multi-hour backlog self-drains. No intermediate COMMIT is introduced. Mirrors migration 205 / telemetry.load_energy_measurements_incremental(). '
'Migration 226: additionally resolves telemetry.environment_measurements.space_id at routing time from metadata.space_points (point-in-time via effective_range, restricted to the row''s organization), writing NULL when there is no effective binding or when applicable bindings are ambiguous. All bounded-catch-up / watermark / overlap / correction-deadline / idempotency / advisory-lock behaviour is unchanged; quality_code is still written NULL. '
'Phase 4 (migration 227): this body is emitted by the offline generator scripts/codegen/generate_routing_procedure.py from config.parameter_routing (declarative spec scripts/codegen/routing/environment_measurements.routing.json), not hand-typed. It is behaviourally identical to the migration-226 body -- the same 12 routed logical points map to the same 12 destination columns with the same casts, the same legacy BATTERY_VOLTAGE compatibility alias feeds battery_voltage_v, and Space resolution, the watermark, bounded catch-up and the EXCEPTION contract are unchanged; only list/line formatting differs. No config.parameter_routing row is read at runtime.';


-- ----------------------------------------------------------------------------
-- 6. Late-sweep job: after both sweeps, the recovery scope for both loaders,
--    then the 7-day prune. Schedule, config, max_runtime and retries unchanged.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.run_routing_late_sweep_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS
$$
DECLARE
    v_overlap    INTERVAL := INTERVAL '15 minutes';
    v_max_window INTERVAL := INTERVAL '1 day';
BEGIN
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(BTRIM(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;

    IF config IS NOT NULL
       AND config ? 'max_window'
       AND NULLIF(BTRIM(config ->> 'max_window'), '') IS NOT NULL
    THEN
        v_max_window := (config ->> 'max_window')::INTERVAL;
    END IF;

    IF v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'Routing late sweep overlap cannot be negative: %', v_overlap;
    END IF;

    IF v_max_window IS NULL OR v_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'Routing late sweep max_window must be a positive interval: %', v_max_window;
    END IF;

    -- One transaction per loader, so each holds its advisory lock only for its
    -- own sweep. The scope setting is transaction-local and ends with COMMIT.
    PERFORM set_config('ems.routing_scope', 'late_sweep', true);
    CALL telemetry.load_energy_measurements_incremental(v_overlap, v_max_window);
    COMMIT;

    PERFORM set_config('ems.routing_scope', 'late_sweep', true);
    CALL telemetry.load_environment_measurements_incremental(v_overlap, v_max_window);
    COMMIT;

    -- Migration 305: route the rows telemetry.recover_failed_raw_messages
    -- queued (same loaders, same locks, scope 'recovery'), one transaction per
    -- loader; then drop entries both loaders routed more than 7 days ago.
    PERFORM set_config('ems.routing_scope', 'recovery', true);
    CALL telemetry.load_energy_measurements_incremental(v_overlap, v_max_window);
    COMMIT;

    PERFORM set_config('ems.routing_scope', 'recovery', true);
    CALL telemetry.load_environment_measurements_incremental(v_overlap, v_max_window);
    COMMIT;

    DELETE FROM telemetry.routing_recovery_queue
    WHERE energy_routed_at < now() - INTERVAL '7 days'
      AND environment_routed_at < now() - INTERVAL '7 days';
    COMMIT;
END;
$$;

COMMENT ON PROCEDURE telemetry.run_routing_late_sweep_job(INTEGER, JSONB) IS
'Migration 303: hourly late-data sweep for both routing loaders. Sets the transaction-local ems.routing_scope = ''late_sweep'' and CALLs telemetry.load_energy_measurements_incremental and telemetry.load_environment_measurements_incremental, each in its own transaction. In that scope a loader uses checkpoint <pipeline>_late_sweep, reads only normalized_points rows with event_time below the newest compressed chunk''s range_end (rows the bounded forward runs skip), and never passes the forward checkpoint. config: overlap (default 15 minutes, replay capped at 1 minute by the loaders as for forward runs), max_window (default 1 day). Migration 305: then CALLs both loaders with ems.routing_scope = ''recovery'' (each in its own transaction), which route the pending telemetry.routing_recovery_queue entries, and deletes entries both loaders routed more than 7 days ago.';


-- ----------------------------------------------------------------------------
-- 7. Status rows for the recovery scope (status / last run only; the queue,
--    not a checkpoint, decides what is routed). Seeded like 303's sweep rows.
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name, last_received_at, last_status)
SELECT ps.pipeline_name || '_recovery', ps.last_received_at, 'SUCCESS'
FROM telemetry.pipeline_state AS ps
WHERE ps.pipeline_name IN ('energy_measurements', 'environment_measurements')
ON CONFLICT (pipeline_name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 8. Demand reconciler (job 1121 on staging): reconcile_window 6 h -> 48 h, so
--    intervals a recovery up to the 48-hour raw retention re-supplies are
--    re-finalized. Every other config key, the schedule and the procedure are
--    unchanged. Rollback: alter_job back to the NOTICEd config.
-- ----------------------------------------------------------------------------
DO $demand$
DECLARE
    v_job INTEGER;
    v_cfg JSONB;
BEGIN
    SELECT job_id, config INTO v_job, v_cfg
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals';
    PERFORM alter_job(v_job, config => v_cfg || jsonb_build_object('reconcile_window', '48 hours'));
    RAISE NOTICE 'Migration 305: job % config % -> %', v_job, v_cfg, v_cfg || jsonb_build_object('reconcile_window', '48 hours');
END
$demand$;


-- ----------------------------------------------------------------------------
-- 9. Postconditions: new bodies exact; each fragment exactly once; reverting
--    the fragments gives back the migration-220 / migration-303 bodies byte for
--    byte; queue, status rows and demand window in place.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_energy   TEXT;
    v_env      TEXT;
    v_recovery TEXT;
    v_sweep    TEXT;
BEGIN
    SELECT replace(prosrc, E'\r', '') INTO v_energy FROM pg_proc
    WHERE oid = 'telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure;
    SELECT replace(prosrc, E'\r', '') INTO v_env FROM pg_proc
    WHERE oid = 'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure;
    SELECT replace(prosrc, E'\r', '') INTO v_recovery FROM pg_proc
    WHERE oid = 'telemetry.recover_failed_raw_messages(integer)'::regprocedure;
    SELECT replace(prosrc, E'\r', '') INTO v_sweep FROM pg_proc
    WHERE oid = 'telemetry.run_routing_late_sweep_job(integer,jsonb)'::regprocedure;

    IF md5(v_energy) IS DISTINCT FROM '9b035f4a55edbf99ec2a5db4bb173d09' THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: energy loader body md5 % is not the expected migration-305 body.', md5(v_energy);
    END IF;
    IF md5(v_env) IS DISTINCT FROM 'd2d906d4da78eeba3740b2b0d082a237' THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: environment loader body md5 % is not the expected migration-305 body.', md5(v_env);
    END IF;
    IF md5(v_recovery) IS DISTINCT FROM '76e7c9e2140fe46a3012e7f654a80294' THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: recovery body md5 % is not the expected migration-305 body.', md5(v_recovery);
    END IF;
    IF md5(v_sweep) IS DISTINCT FROM 'e649c982e6bf5089a6f126dd4c330405' THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: late-sweep job body md5 % is not the expected migration-305 body.', md5(v_sweep);
    END IF;

    IF (length(v_energy) - length(replace(v_energy, $ec1$  -- Migration 305: ems.routing_scope = 'recovery' (set only by the late-sweep
  -- job) routes the pairs queued in telemetry.routing_recovery_queue.
  v_pipeline_name CONSTANT TEXT := CASE v_scope WHEN 'late_sweep' THEN 'energy_measurements_late_sweep' WHEN 'recovery' THEN 'energy_measurements_recovery' ELSE 'energy_measurements' END;
  v_queue_ids BIGINT[] := '{}';
$ec1$, ''))) / length($el1$  -- Migration 305: ems.routing_scope = 'recovery' (set only by the late-sweep
  -- job) routes the pairs queued in telemetry.routing_recovery_queue.
  v_pipeline_name CONSTANT TEXT := CASE v_scope WHEN 'late_sweep' THEN 'energy_measurements_late_sweep' WHEN 'recovery' THEN 'energy_measurements_recovery' ELSE 'energy_measurements' END;
  v_queue_ids BIGINT[] := '{}';
$el1$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: energy fragment 1 does not appear exactly once.';
    END IF;
    IF (length(v_energy) - length(replace(v_energy, $ec2$  IF v_scope NOT IN ('forward', 'late_sweep', 'recovery') THEN
    RAISE EXCEPTION 'ems.routing_scope must be forward, late_sweep or recovery; received %', v_scope;
$ec2$, ''))) / length($el2$  IF v_scope NOT IN ('forward', 'late_sweep', 'recovery') THEN
    RAISE EXCEPTION 'ems.routing_scope must be forward, late_sweep or recovery; received %', v_scope;
$el2$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: energy fragment 2 does not appear exactly once.';
    END IF;
    IF (length(v_energy) - length(replace(v_energy, $ec3$  -- Migration 305: the recovery scope routes the (device_id, event_time)
  -- pairs telemetry.recover_failed_raw_messages queued when it re-inserted
  -- normalized_points rows under their original platform_received_at, which
  -- is below every receipt window. The batch is fixed here (one run at a
  -- time: the advisory lock above), read below instead of the receipt window
  -- and marked routed in this transaction; a failed run leaves it pending.
  IF v_scope = 'recovery' THEN
    v_queue_ids := ARRAY(
      SELECT q.id FROM telemetry.routing_recovery_queue q
      WHERE q.energy_routed_at IS NULL
      ORDER BY q.id
      LIMIT 10000
    );
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
$ec3$, ''))) / length($el3$  -- Migration 305: the recovery scope routes the (device_id, event_time)
  -- pairs telemetry.recover_failed_raw_messages queued when it re-inserted
  -- normalized_points rows under their original platform_received_at, which
  -- is below every receipt window. The batch is fixed here (one run at a
  -- time: the advisory lock above), read below instead of the receipt window
  -- and marked routed in this transaction; a failed run leaves it pending.
  IF v_scope = 'recovery' THEN
    v_queue_ids := ARRAY(
      SELECT q.id FROM telemetry.routing_recovery_queue q
      WHERE q.energy_routed_at IS NULL
      ORDER BY q.id
      LIMIT 10000
    );
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
$el3$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: energy fragment 3 does not appear exactly once.';
    END IF;
    IF (length(v_energy) - length(replace(v_energy, $ec4$      AND np.event_time < v_event_max
      AND v_scope <> 'recovery'
    GROUP BY np.device_id,np.event_time
    UNION ALL
    -- Migration 305: recovery scope -- the queued pairs, whatever their
    -- receipt time or chunk.
    SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
    FROM telemetry.routing_recovery_queue q
    JOIN telemetry.normalized_points np ON np.device_id=q.device_id AND np.event_time=q.event_time
    WHERE v_scope = 'recovery'
      AND q.id = ANY(v_queue_ids)
    GROUP BY np.device_id,np.event_time
$ec4$, ''))) / length($el4$      AND np.event_time < v_event_max
      AND v_scope <> 'recovery'
    GROUP BY np.device_id,np.event_time
    UNION ALL
    -- Migration 305: recovery scope -- the queued pairs, whatever their
    -- receipt time or chunk.
    SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
    FROM telemetry.routing_recovery_queue q
    JOIN telemetry.normalized_points np ON np.device_id=q.device_id AND np.event_time=q.event_time
    WHERE v_scope = 'recovery'
      AND q.id = ANY(v_queue_ids)
    GROUP BY np.device_id,np.event_time
$el4$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: energy fragment 4 does not appear exactly once.';
    END IF;
    IF (length(v_energy) - length(replace(v_energy, $ec5$  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
  -- Migration 305: the fixed queue batch is routed by this transaction.
  IF v_scope = 'recovery' THEN
    UPDATE telemetry.routing_recovery_queue SET energy_routed_at=clock_timestamp()
    WHERE id = ANY(v_queue_ids);
  END IF;
$ec5$, ''))) / length($el5$  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
  -- Migration 305: the fixed queue batch is routed by this transaction.
  IF v_scope = 'recovery' THEN
    UPDATE telemetry.routing_recovery_queue SET energy_routed_at=clock_timestamp()
    WHERE id = ANY(v_queue_ids);
  END IF;
$el5$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: energy fragment 5 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, $vc1$    -- Migration 305: ems.routing_scope = 'recovery' (set only by the late-sweep
    -- job) routes the pairs queued in telemetry.routing_recovery_queue.
    v_pipeline_name CONSTANT TEXT := CASE v_scope WHEN 'late_sweep' THEN 'environment_measurements_late_sweep' WHEN 'recovery' THEN 'environment_measurements_recovery' ELSE 'environment_measurements' END;
    v_queue_ids BIGINT[] := '{}';
$vc1$, ''))) / length($vl1$    -- Migration 305: ems.routing_scope = 'recovery' (set only by the late-sweep
    -- job) routes the pairs queued in telemetry.routing_recovery_queue.
    v_pipeline_name CONSTANT TEXT := CASE v_scope WHEN 'late_sweep' THEN 'environment_measurements_late_sweep' WHEN 'recovery' THEN 'environment_measurements_recovery' ELSE 'environment_measurements' END;
    v_queue_ids BIGINT[] := '{}';
$vl1$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: environment fragment 1 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, $vc2$    IF v_scope NOT IN ('forward', 'late_sweep', 'recovery') THEN
        RAISE EXCEPTION 'ems.routing_scope must be forward, late_sweep or recovery; received %', v_scope;
$vc2$, ''))) / length($vl2$    IF v_scope NOT IN ('forward', 'late_sweep', 'recovery') THEN
        RAISE EXCEPTION 'ems.routing_scope must be forward, late_sweep or recovery; received %', v_scope;
$vl2$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: environment fragment 2 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, $vc3$    -- Migration 305: the recovery scope routes the (device_id, event_time)
    -- pairs telemetry.recover_failed_raw_messages queued when it re-inserted
    -- normalized_points rows under their original platform_received_at, which
    -- is below every receipt window. The batch is fixed here (one run at a
    -- time: the advisory lock above), read below instead of the receipt window
    -- and marked routed in this transaction; a failed run leaves it pending.
    IF v_scope = 'recovery' THEN
        v_queue_ids := ARRAY(
            SELECT q.id FROM telemetry.routing_recovery_queue q
            WHERE q.environment_routed_at IS NULL
            ORDER BY q.id
            LIMIT 10000
        );
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
$vc3$, ''))) / length($vl3$    -- Migration 305: the recovery scope routes the (device_id, event_time)
    -- pairs telemetry.recover_failed_raw_messages queued when it re-inserted
    -- normalized_points rows under their original platform_received_at, which
    -- is below every receipt window. The batch is fixed here (one run at a
    -- time: the advisory lock above), read below instead of the receipt window
    -- and marked routed in this transaction; a failed run leaves it pending.
    IF v_scope = 'recovery' THEN
        v_queue_ids := ARRAY(
            SELECT q.id FROM telemetry.routing_recovery_queue q
            WHERE q.environment_routed_at IS NULL
            ORDER BY q.id
            LIMIT 10000
        );
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
$vl3$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: environment fragment 3 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, $vc4$        AND np.event_time < v_event_max
        AND v_scope <> 'recovery'
$vc4$, ''))) / length($vl4$        AND np.event_time < v_event_max
        AND v_scope <> 'recovery'
$vl4$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: environment fragment 4 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, $vc5$      GROUP BY np.device_id,np.event_time
      UNION ALL
      -- Migration 305: recovery scope -- the queued pairs, whatever their
      -- receipt time or chunk.
      SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
      FROM telemetry.routing_recovery_queue q
      JOIN telemetry.normalized_points np ON np.device_id=q.device_id AND np.event_time=q.event_time
      JOIN metadata.devices d ON d.id=np.device_id
      JOIN config.device_profiles dp ON dp.id=d.profile_id
      WHERE v_scope = 'recovery'
        AND q.id = ANY(v_queue_ids)
        AND dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND np.logical_point IN
        (
            'ENV_TEMPERATURE',
            'ENV_RELATIVE_HUMIDITY',
            'ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY',
            'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW',
            'EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE',
            'BATTERY_VOLTAGE',
            'DEVICE_STATUS_CODE'
        )
      GROUP BY np.device_id,np.event_time
    ),
$vc5$, ''))) / length($vl5$      GROUP BY np.device_id,np.event_time
      UNION ALL
      -- Migration 305: recovery scope -- the queued pairs, whatever their
      -- receipt time or chunk.
      SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
      FROM telemetry.routing_recovery_queue q
      JOIN telemetry.normalized_points np ON np.device_id=q.device_id AND np.event_time=q.event_time
      JOIN metadata.devices d ON d.id=np.device_id
      JOIN config.device_profiles dp ON dp.id=d.profile_id
      WHERE v_scope = 'recovery'
        AND q.id = ANY(v_queue_ids)
        AND dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND np.logical_point IN
        (
            'ENV_TEMPERATURE',
            'ENV_RELATIVE_HUMIDITY',
            'ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY',
            'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW',
            'EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE',
            'BATTERY_VOLTAGE',
            'DEVICE_STATUS_CODE'
        )
      GROUP BY np.device_id,np.event_time
    ),
$vl5$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: environment fragment 5 does not appear exactly once.';
    END IF;
    IF (length(v_env) - length(replace(v_env, $vc6$    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    -- Migration 305: the fixed queue batch is routed by this transaction.
    IF v_scope = 'recovery' THEN
        UPDATE telemetry.routing_recovery_queue SET environment_routed_at=clock_timestamp()
        WHERE id = ANY(v_queue_ids);
    END IF;
$vc6$, ''))) / length($vl6$    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    -- Migration 305: the fixed queue batch is routed by this transaction.
    IF v_scope = 'recovery' THEN
        UPDATE telemetry.routing_recovery_queue SET environment_routed_at=clock_timestamp()
        WHERE id = ANY(v_queue_ids);
    END IF;
$vl6$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: environment fragment 6 does not appear exactly once.';
    END IF;
    IF (length(v_recovery) - length(replace(v_recovery, $rc1$        -- Migration 305: queue every (device_id, event_time) this insert
        -- adds or supersedes for the routing recovery scope, in this
        -- candidate's transaction (its COMMIT below). The rows keep their
        -- original platform_received_at, below every routing receipt window,
        -- so without the queue they never reach energy / environment
        -- measurements (plan CI-1 / T1.4).
        WITH recovered AS
        (
        INSERT INTO telemetry.normalized_points
$rc1$, ''))) / length($rl1$        -- Migration 305: queue every (device_id, event_time) this insert
        -- adds or supersedes for the routing recovery scope, in this
        -- candidate's transaction (its COMMIT below). The rows keep their
        -- original platform_received_at, below every routing receipt window,
        -- so without the queue they never reach energy / environment
        -- measurements (plan CI-1 / T1.4).
        WITH recovered AS
        (
        INSERT INTO telemetry.normalized_points
$rl1$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: recovery fragment 1 does not appear exactly once.';
    END IF;
    IF (length(v_recovery) - length(replace(v_recovery, $rc2$        WHERE EXCLUDED.platform_received_at>telemetry.normalized_points.platform_received_at
        RETURNING device_id,event_time
        )
        INSERT INTO telemetry.routing_recovery_queue (raw_received_at,raw_message_id,device_id,event_time)
        SELECT DISTINCT f.raw_received_at,f.raw_message_id,r.device_id,r.event_time
        FROM recovered r;
$rc2$, ''))) / length($rl2$        WHERE EXCLUDED.platform_received_at>telemetry.normalized_points.platform_received_at
        RETURNING device_id,event_time
        )
        INSERT INTO telemetry.routing_recovery_queue (raw_received_at,raw_message_id,device_id,event_time)
        SELECT DISTINCT f.raw_received_at,f.raw_message_id,r.device_id,r.event_time
        FROM recovered r;
$rl2$) <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: recovery fragment 2 does not appear exactly once.';
    END IF;

    IF md5(replace(replace(replace(replace(replace(v_energy, $en1$  -- Migration 305: ems.routing_scope = 'recovery' (set only by the late-sweep
  -- job) routes the pairs queued in telemetry.routing_recovery_queue.
  v_pipeline_name CONSTANT TEXT := CASE v_scope WHEN 'late_sweep' THEN 'energy_measurements_late_sweep' WHEN 'recovery' THEN 'energy_measurements_recovery' ELSE 'energy_measurements' END;
  v_queue_ids BIGINT[] := '{}';
$en1$, $eo1$  v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = 'late_sweep' THEN 'energy_measurements_late_sweep' ELSE 'energy_measurements' END;
$eo1$), $en2$  IF v_scope NOT IN ('forward', 'late_sweep', 'recovery') THEN
    RAISE EXCEPTION 'ems.routing_scope must be forward, late_sweep or recovery; received %', v_scope;
$en2$, $eo2$  IF v_scope NOT IN ('forward', 'late_sweep') THEN
    RAISE EXCEPTION 'ems.routing_scope must be forward or late_sweep; received %', v_scope;
$eo2$), $en3$  -- Migration 305: the recovery scope routes the (device_id, event_time)
  -- pairs telemetry.recover_failed_raw_messages queued when it re-inserted
  -- normalized_points rows under their original platform_received_at, which
  -- is below every receipt window. The batch is fixed here (one run at a
  -- time: the advisory lock above), read below instead of the receipt window
  -- and marked routed in this transaction; a failed run leaves it pending.
  IF v_scope = 'recovery' THEN
    v_queue_ids := ARRAY(
      SELECT q.id FROM telemetry.routing_recovery_queue q
      WHERE q.energy_routed_at IS NULL
      ORDER BY q.id
      LIMIT 10000
    );
  END IF;

  -- Late-arriving source timestamps still have a new platform receipt time.
$en3$, $eo3$  -- Late-arriving source timestamps still have a new platform receipt time.
$eo3$), $en4$      AND np.event_time < v_event_max
      AND v_scope <> 'recovery'
    GROUP BY np.device_id,np.event_time
    UNION ALL
    -- Migration 305: recovery scope -- the queued pairs, whatever their
    -- receipt time or chunk.
    SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
    FROM telemetry.routing_recovery_queue q
    JOIN telemetry.normalized_points np ON np.device_id=q.device_id AND np.event_time=q.event_time
    WHERE v_scope = 'recovery'
      AND q.id = ANY(v_queue_ids)
    GROUP BY np.device_id,np.event_time
$en4$, $eo4$      AND np.event_time < v_event_max
    GROUP BY np.device_id,np.event_time
$eo4$), $en5$  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
  -- Migration 305: the fixed queue batch is routed by this transaction.
  IF v_scope = 'recovery' THEN
    UPDATE telemetry.routing_recovery_queue SET energy_routed_at=clock_timestamp()
    WHERE id = ANY(v_queue_ids);
  END IF;
$en5$, $eo5$  GET DIAGNOSTICS v_affected_rows=ROW_COUNT;
$eo5$)) IS DISTINCT FROM 'ee8c1867c0426587cda0d40467be57a2' THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: the energy loader differs from migration 303 outside the migration-305 fragments.';
    END IF;
    IF md5(replace(replace(replace(replace(replace(replace(v_env, $vn1$    -- Migration 305: ems.routing_scope = 'recovery' (set only by the late-sweep
    -- job) routes the pairs queued in telemetry.routing_recovery_queue.
    v_pipeline_name CONSTANT TEXT := CASE v_scope WHEN 'late_sweep' THEN 'environment_measurements_late_sweep' WHEN 'recovery' THEN 'environment_measurements_recovery' ELSE 'environment_measurements' END;
    v_queue_ids BIGINT[] := '{}';
$vn1$, $vo1$    v_pipeline_name CONSTANT TEXT := CASE WHEN v_scope = 'late_sweep' THEN 'environment_measurements_late_sweep' ELSE 'environment_measurements' END;
$vo1$), $vn2$    IF v_scope NOT IN ('forward', 'late_sweep', 'recovery') THEN
        RAISE EXCEPTION 'ems.routing_scope must be forward, late_sweep or recovery; received %', v_scope;
$vn2$, $vo2$    IF v_scope NOT IN ('forward', 'late_sweep') THEN
        RAISE EXCEPTION 'ems.routing_scope must be forward or late_sweep; received %', v_scope;
$vo2$), $vn3$    -- Migration 305: the recovery scope routes the (device_id, event_time)
    -- pairs telemetry.recover_failed_raw_messages queued when it re-inserted
    -- normalized_points rows under their original platform_received_at, which
    -- is below every receipt window. The batch is fixed here (one run at a
    -- time: the advisory lock above), read below instead of the receipt window
    -- and marked routed in this transaction; a failed run leaves it pending.
    IF v_scope = 'recovery' THEN
        v_queue_ids := ARRAY(
            SELECT q.id FROM telemetry.routing_recovery_queue q
            WHERE q.environment_routed_at IS NULL
            ORDER BY q.id
            LIMIT 10000
        );
    END IF;

    -- Route from newly received normalized rows. Late source timestamps are
$vn3$, $vo3$    -- Route from newly received normalized rows. Late source timestamps are
$vo3$), $vn4$        AND np.event_time < v_event_max
        AND v_scope <> 'recovery'
$vn4$, $vo4$        AND np.event_time < v_event_max
$vo4$), $vn5$      GROUP BY np.device_id,np.event_time
      UNION ALL
      -- Migration 305: recovery scope -- the queued pairs, whatever their
      -- receipt time or chunk.
      SELECT np.device_id,np.event_time,MAX(np.platform_received_at) AS platform_received_at
      FROM telemetry.routing_recovery_queue q
      JOIN telemetry.normalized_points np ON np.device_id=q.device_id AND np.event_time=q.event_time
      JOIN metadata.devices d ON d.id=np.device_id
      JOIN config.device_profiles dp ON dp.id=d.profile_id
      WHERE v_scope = 'recovery'
        AND q.id = ANY(v_queue_ids)
        AND dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND np.logical_point IN
        (
            'ENV_TEMPERATURE',
            'ENV_RELATIVE_HUMIDITY',
            'ENV_ILLUMINANCE_LUX',
            'OCCUPANCY_ACTIVITY',
            'OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT',
            'PULSE_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_1_RAW',
            'EXTERNAL_SENSOR_INPUT_2_RAW',
            'EXTERNAL_SENSOR_INPUT_3_RAW',
            'EXTERNAL_SENSOR_INPUT_4_RAW',
            'DEVICE_BATTERY_VOLTAGE',
            'BATTERY_VOLTAGE',
            'DEVICE_STATUS_CODE'
        )
      GROUP BY np.device_id,np.event_time
    ),
$vn5$, $vo5$      GROUP BY np.device_id,np.event_time
    ),
$vo5$), $vn6$    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    -- Migration 305: the fixed queue batch is routed by this transaction.
    IF v_scope = 'recovery' THEN
        UPDATE telemetry.routing_recovery_queue SET environment_routed_at=clock_timestamp()
        WHERE id = ANY(v_queue_ids);
    END IF;
$vn6$, $vo6$    GET DIAGNOSTICS v_inserted = ROW_COUNT;
$vo6$)) IS DISTINCT FROM 'be09c0efb5cc8f5f819f2bb30b8d5370' THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: the environment loader differs from migration 303 outside the migration-305 fragments.';
    END IF;
    IF md5(replace(replace(v_recovery, $rn1$        -- Migration 305: queue every (device_id, event_time) this insert
        -- adds or supersedes for the routing recovery scope, in this
        -- candidate's transaction (its COMMIT below). The rows keep their
        -- original platform_received_at, below every routing receipt window,
        -- so without the queue they never reach energy / environment
        -- measurements (plan CI-1 / T1.4).
        WITH recovered AS
        (
        INSERT INTO telemetry.normalized_points
$rn1$, $ro1$        INSERT INTO telemetry.normalized_points
$ro1$), $rn2$        WHERE EXCLUDED.platform_received_at>telemetry.normalized_points.platform_received_at
        RETURNING device_id,event_time
        )
        INSERT INTO telemetry.routing_recovery_queue (raw_received_at,raw_message_id,device_id,event_time)
        SELECT DISTINCT f.raw_received_at,f.raw_message_id,r.device_id,r.event_time
        FROM recovered r;
$rn2$, $ro2$        WHERE EXCLUDED.platform_received_at>telemetry.normalized_points.platform_received_at;
$ro2$)) IS DISTINCT FROM '6c64cb3299da492900bb66221704744f' THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: recovery differs from migration 220 outside the migration-305 fragments.';
    END IF;
    IF md5(replace(v_sweep, $sn1$    PERFORM set_config('ems.routing_scope', 'late_sweep', true);
    CALL telemetry.load_environment_measurements_incremental(v_overlap, v_max_window);
    COMMIT;

    -- Migration 305: route the rows telemetry.recover_failed_raw_messages
    -- queued (same loaders, same locks, scope 'recovery'), one transaction per
    -- loader; then drop entries both loaders routed more than 7 days ago.
    PERFORM set_config('ems.routing_scope', 'recovery', true);
    CALL telemetry.load_energy_measurements_incremental(v_overlap, v_max_window);
    COMMIT;

    PERFORM set_config('ems.routing_scope', 'recovery', true);
    CALL telemetry.load_environment_measurements_incremental(v_overlap, v_max_window);
    COMMIT;

    DELETE FROM telemetry.routing_recovery_queue
    WHERE energy_routed_at < now() - INTERVAL '7 days'
      AND environment_routed_at < now() - INTERVAL '7 days';
    COMMIT;
$sn1$, $so1$    PERFORM set_config('ems.routing_scope', 'late_sweep', true);
    CALL telemetry.load_environment_measurements_incremental(v_overlap, v_max_window);
    COMMIT;
$so1$)) IS DISTINCT FROM 'ee1e97ace9547cf20c3df5e02ada9cdd' THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: the late-sweep job differs from migration 303 outside the migration-305 fragment.';
    END IF;

    IF (SELECT count(*) FROM telemetry.pipeline_state
        WHERE pipeline_name IN ('energy_measurements_recovery', 'environment_measurements_recovery')) <> 2 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: the recovery status rows are missing.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals'
          AND config ->> 'reconcile_window' = '48 hours' AND config ->> 'lookback' = '3 hours') <> 1 THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: the demand reconciler window is not 48 hours.';
    END IF;
    IF has_table_privilege('public', 'telemetry.routing_recovery_queue', 'SELECT') THEN
        RAISE EXCEPTION 'Migration 305 postcondition failed: PUBLIC can read telemetry.routing_recovery_queue.';
    END IF;

    RAISE NOTICE 'Migration 305: all postconditions passed.';
END
$post$;
