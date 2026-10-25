-- ============================================================================
-- Migration 311
-- Bound telemetry.recover_failed_raw_messages()'s two normalized_points
-- lookups by the candidate's own event-time span (job 1061 on production /
-- job 1077 on staging).
--
-- DEFECT (production, 2026-10-24, read-only evidence)
--   After three AirSense sensors were registered, every run of job 1061 hit its
--   10-minute max_runtime. The 14:28 run spent its whole transaction on ONE
--   candidate in IO/DataFileRead holding a lock on every normalized_points
--   chunk; EXPLAIN of the lookup
--     capture_bucket_samples s ... JOIN/EXISTS normalized_points np
--       ON np.device_id = s.device_id AND np.event_time = s.event_time
--   is a Hash Join over a sequential, decompressing scan of all ~13 weekly
--   chunks: the key is known only at run time, so no chunk is excluded. A
--   candidate therefore costs more than 10 minutes, rolls back (migration 203
--   per-candidate commit), and the backlog never moves. The job is paused on
--   production (audit d3bf7863) until this fix is in place.
--
-- FIX (the migration-305 body verbatim plus three fragments)
--   1. two variables, v_event_min / v_event_max;
--   2. per candidate, before current_elements: the min / max event time of the
--      candidate's own elements (element ts, else received_at -- the
--      telemetry.v_rtdata derivation), read by the raw_messages primary key;
--      an absent packet gives received_at for both;
--   3. both normalized_points lookups (the RECOVERED update of the capture
--      samples and the v_has_normalized check) gain
--        np.event_time >= v_event_min - 1 day AND np.event_time < v_event_max + 1 day.
--   Every row those lookups can match is a capture sample of this packet or
--   of a bucket one of its elements falls in, so its event_time lies inside
--   that window (capture intervals are far shorter than a day): the results
--   are unchanged; only the chunks read change (plpgsql passes the bounds as
--   parameters, which TimescaleDB excludes chunks on at executor startup).
--
-- NOT CHANGED: everything else in the body (migrations 203-220 / 305
-- fragments), its signature, owner, privileges and COMMENT; the job, its
-- schedule, config, max_runtime and scheduled state (production job 1061
-- stays paused -- resuming it is a separate, approved step); data.
--
-- Rollback: re-issue the migration-305 body (CREATE OR REPLACE PROCEDURE from
-- 305_routing_recovery_queue.sql section 3).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Precondition: the deployed body is exactly migration 305's.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'telemetry.recover_failed_raw_messages(integer)'::regprocedure)
       IS DISTINCT FROM '76e7c9e2140fe46a3012e7f654a80294' THEN
        RAISE EXCEPTION 'Migration 311 precondition failed: recover_failed_raw_messages differs from the migration-305 body.';
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2. The migration-305 body plus the three migration-311 fragments.
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
    v_event_min TIMESTAMPTZ;     -- migration 311
    v_event_max TIMESTAMPTZ;     -- migration 311
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
        -- Migration 311: the event-time span of this candidate's own elements
        -- (the telemetry.v_rtdata derivation: element ts, else received_at),
        -- read by the raw_messages primary key. It bounds the two
        -- normalized_points lookups below, whose keys are otherwise known only
        -- at run time -- without a bound the planner scans and decompresses
        -- every normalized_points chunk for each candidate (production job
        -- 1061, 2026-10-24: more than 10 minutes per candidate). Every row
        -- those lookups can match lies inside [span - 1 day, span + 1 day)
        -- (a capture sample of this packet, or of a bucket one of its
        -- elements falls in; buckets are shorter than a day), so the result
        -- is unchanged. A packet no longer in raw_messages gives an empty
        -- span; its lookups then find nothing, exactly as before.
        SELECT min(COALESCE(x.source_timestamp, rm.received_at)), max(COALESCE(x.source_timestamp, rm.received_at))
          INTO v_event_min, v_event_max
        FROM telemetry.raw_messages rm
        CROSS JOIN LATERAL jsonb_array_elements(rm.payload->'rtdata') e(value)
        CROSS JOIN LATERAL
        (
            SELECT CASE
                WHEN e.value->>'ts' IS NULL THEN NULL::timestamptz
                WHEN pg_input_is_valid(e.value->>'ts','double precision') THEN to_timestamp((e.value->>'ts')::double precision)
                ELSE NULL::timestamptz
            END AS source_timestamp
        ) x
        WHERE rm.received_at=f.raw_received_at AND rm.id=f.raw_message_id
          AND jsonb_typeof(rm.payload->'rtdata')='array';
        v_event_min:=COALESCE(v_event_min,f.raw_received_at);
        v_event_max:=COALESCE(v_event_max,f.raw_received_at);

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
                AND np.event_time>=v_event_min-INTERVAL '1 day' AND np.event_time<v_event_max+INTERVAL '1 day'   -- migration 311
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
             AND np.event_time>=v_event_min-INTERVAL '1 day' AND np.event_time<v_event_max+INTERVAL '1 day'   -- migration 311
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
-- 3. Postcondition: the new body is exact and holds each fragment once.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_body TEXT;
BEGIN
    SELECT replace(prosrc, E'\r', '') INTO v_body FROM pg_proc
    WHERE oid = 'telemetry.recover_failed_raw_messages(integer)'::regprocedure;
    IF md5(v_body) IS DISTINCT FROM '31f4db2fbe27b6b072c0aa17bf5660d9' THEN
        RAISE EXCEPTION 'Migration 311 postcondition failed: body md5 % is not the expected migration-311 body.', md5(v_body);
    END IF;
    IF (length(v_body) - length(replace(v_body, '-- migration 311', ''))) / length('-- migration 311') <> 4 THEN
        RAISE EXCEPTION 'Migration 311 postcondition failed: expected the four migration-311 markers exactly once each.';
    END IF;
END $$;
