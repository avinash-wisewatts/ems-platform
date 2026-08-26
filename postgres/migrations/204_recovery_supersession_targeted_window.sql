-- ============================================================================
-- Migration 204
-- Replace telemetry.recover_failed_raw_messages()'s per-candidate
-- supersession NOT EXISTS query with a targeted form that avoids resolving
-- telemetry.resolve_site_capture_bucket() for every historical competing
-- raw-data element.
--
-- Root cause (2026-08-22 candidate, raw_received_at='2026-08-22
-- 17:23:46.411805+05:30', raw_message_id=1762912, investigated 2026-08-26):
-- with migrations 201-203 deployed and confirmed correct, this candidate
-- still could not be resolved -- telemetry.capture_bucket_samples and
-- telemetry.normalized_points both have zero rows for it after four replay
-- attempts, each ending in "Message is not currently eligible for a
-- finalized capture bucket." A read-only EXPLAIN against the deployed
-- supersession subquery for this exact candidate estimated ~467,405
-- telemetry.raw_messages rows, ~46.7 million JSON-expanded rtdata elements,
-- and ~701 million rows on a Hash Anti Join's build side, spilling to disk
-- (BufFileWrite) -- even though the candidate itself resolves to just 6
-- device samples at one site and migration 201's r2.received_at bound
-- (bucket_start..deadline) is already present in the query text.
--
-- Mechanism: the supersession subquery resolves each competing row's
-- device/site identity via ORDINARY (hash/merge-joinable) INNER JOINs --
-- telemetry.v_rtdata r2 JOIN metadata.device_identifiers JOIN
-- metadata.devices JOIN metadata.gateways -- before telemetry.
-- resolve_site_capture_bucket() can even be called to produce b2.bucket_start
-- for the b2.bucket_start=ce.bucket_start comparison. Because bucket_start
-- does not exist as a column until that LATERAL function has run, and the
-- identity-resolution side is built from ordinary joins the planner is free
-- to reorder and hash, PostgreSQL can choose (and, per the live EXPLAIN,
-- does choose) to materialize the identity-hash side and stream the FULL,
-- effectively unbounded v_rtdata expansion as the join's other side,
-- applying migration 201's r2.received_at bound only as a post-hash filter
-- rather than pushing it into the telemetry.raw_messages scan.
--
-- Fix: read competing rows directly from telemetry.raw_messages, applying
-- the exact same migration-201 window (r2m.received_at BETWEEN
-- ce.bucket_start AND ce.deadline) and the jsonb_typeof(...)='array' guard
-- BEFORE any JSON expansion -- a plain range/guard condition against the
-- base hypertable, not several joins removed from it. telemetry.
-- resolve_site_capture_bucket() is still called, and is still the sole
-- authority for bucket_start -- its logic is not reimplemented -- but only
-- for the now-small set of rows that already passed the device-identity and
-- time-window filters, not for every row in telemetry.raw_messages' history.
--
-- Revision (2026-08-26, same day, before this migration was ever deployed
-- or committed): an initial version of this fix compared a competing
-- element's device_uid directly to the candidate's own ce.device_uid
-- (lower(r2.value->>'uid')=lower(ce.device_uid)). A semantic-equivalence
-- audit found this NOT fully equivalent to migration 203: the schema's
-- metadata.device_identifiers table has no constraint preventing a single
-- device_id from having more than one identifier_type='MQTT_UID' row (only
-- UNIQUE(identifier_type,identifier_value) exists, preventing the same
-- string being registered twice, not multiple distinct strings per device).
-- If a device ever had two registered MQTT_UID strings, a direct
-- ce.device_uid comparison would miss a genuine competitor using the
-- device's OTHER registered UID -- a correctness regression, not merely a
-- performance one. Corrected: the device-identity test is now
-- lower(r2.value->>'uid') IN (SELECT lower(identifier_value) FROM
-- metadata.device_identifiers WHERE identifier_type='MQTT_UID' AND
-- device_id=ce.device_id) -- the direct SQL restatement of migration 203's
-- original existential condition ("does this UID resolve, via
-- device_identifiers, to ce.device_id"), correct for zero, one, or many
-- registered UIDs per device. This uses ce.device_id (already present in
-- current_elements since migration 007/201/202/203) directly, so the
-- device_uid column is no longer added to current_elements -- it was only
-- ever needed by the superseded direct-comparison approach. As with
-- device_uid before it, no join to metadata.devices or metadata.gateways is
-- needed for competing rows: a device's site is static given its identity,
-- so matching device_id already implies matching site (both g2.site_id
-- under migration 203 and ce.site_id are resolved by the same
-- devices.gateway_id -> gateways.site_id chain, both NOT-NULL-backed FKs
-- for gateways.site_id, evaluated against the identical device row).
--
-- Empirically validated (2026-08-26, read-only, against this exact
-- candidate on staging -- no writes, procedure not executed, across two
-- iterations of this fix): the targeted form, run correlated exactly as it
-- sits in current_elements (all 6 of this candidate's device-elements in
-- one statement):
--   - direct ce.device_uid comparison (superseded, semantically incomplete):
--     577.7ms, Buffers: shared hit=17415, zero disk reads.
--   - corrected device_identifiers-membership form (this migration):
--     1562.5ms, Buffers: shared hit=17392 read=1. The device-identity test
--     compiles to a Hash Semi Join whose build side is a Bitmap Heap Scan on
--     metadata.device_identifiers filtered by (identifier_type='MQTT_UID'
--     AND device_id=ce.device_id) via idx_device_identifiers_device --
--     built ONCE PER CANDIDATE (loops=6, not loops=3047), since Postgres
--     recognizes the subquery depends only on ce.device_id, constant across
--     all ~508 raw-message rows examined for one candidate. The extra ~1s
--     versus the superseded form is Hash Semi Join probe overhead per row
--     (this candidate's device is unusually chatty -- almost every message
--     in its own 16-minute window is from this same device, so the
--     membership test rarely filters anything out) -- still three-plus
--     orders of magnitude faster than migration 203's shape, no disk spill,
--     and TimescaleDB's runtime chunk exclusion still excludes 4 of 5
--     candidate chunks, scanning only the one chunk migration 201/202
--     already scanned.
--
-- Explicitly not touched by this migration: telemetry.v_rtdata,
-- telemetry.resolve_site_capture_bucket() (still the sole bucket-resolution
-- authority, still called per surviving candidate), telemetry.
-- normalized_points_for_recovery_candidate() and its call site (migration
-- 202), p_limit, ORDER BY raw_received_at, FOR UPDATE SKIP LOCKED, the
-- per-candidate COMMIT (migration 203), retry/backoff computation, the
-- ROW(...) tie-break semantics, the b2.bucket_start=ce.bucket_start
-- equality, the r2.received_at window bound, compression/retention
-- policies, the job's schedule/max_runtime, MQTT ingestion, and no
-- per-candidate EXCEPTION handling is introduced. current_elements' SELECT
-- list is unchanged from migration 203 (no device_uid column added). Every
-- change in this migration is confined to the supersession NOT EXISTS
-- subquery.
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

COMMIT;
