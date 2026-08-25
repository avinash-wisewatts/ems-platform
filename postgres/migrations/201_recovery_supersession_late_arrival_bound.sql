-- ============================================================================
-- Migration 201
-- Bound the failed-message recovery job's supersession search to the
-- candidate bucket's own late-arrival tolerance window.
--
-- Root cause (2026-08-25, live investigation): job 1077
-- (telemetry.run_failed_message_recovery_job -> telemetry.
-- recover_failed_raw_messages(limit=100)) has been timing out on every
-- hourly run for 25+ hours (max_runtime=10m). EXPLAIN ANALYZE against real
-- staging data showed the procedure's per-candidate "has this failed
-- message already been superseded by a later sample" NOT EXISTS subquery
-- still running after 4m33s for a single probe with LIMIT 1, while the
-- tightly-filtered exact-message lookup elsewhere in the same procedure
-- measured 72ms. The difference: that subquery's only bound on
-- telemetry.v_rtdata (and therefore on the underlying telemetry.raw_messages
-- hypertable) was `r2.received_at <= ce.deadline` -- an upper bound with no
-- lower bound at all, so every invocation scanned essentially the entire
-- historical raw_messages table (500K+ rows and growing), once per loop
-- iteration, up to 100 times per job run.
--
-- Semantic decision (approved): late_arrival_tolerance_seconds is part of
-- the canonical definition of supersession, not merely a performance
-- parameter. A later raw sample is eligible to supersede a failed message
-- belonging to capture bucket X only if its received_at falls within that
-- bucket's own configured late-arrival tolerance window -- i.e. within
-- [bucket_start, bucket_start + capture_interval_seconds +
-- late_arrival_tolerance_seconds]. A sample arriving outside that window
-- was never a candidate for finalizing bucket X in the first place (the
-- canonical batch pipeline, postgres/ddl/127_set_based_capture_selection_
-- legacy_recovery.sql, enforces the same upper edge via
-- finalization_deadline), so it cannot legitimately supersede anything
-- inside it either.
--
-- Fix: add the corresponding lower bound, `r2.received_at >=
-- ce.bucket_start`, to the existing NOT EXISTS subquery. The upper bound
-- (`r2.received_at <= ce.deadline`, where ce.deadline already encodes
-- ce.late_arrival_tolerance_seconds) is unchanged. Both endpoints are
-- values already resolved per-candidate; no new parameter, no hardcoded
-- duration, and critically no dependence on now() or the candidate's own
-- age -- an old failed message still gets a full, correctly narrow
-- (capture_interval_seconds + late_arrival_tolerance_seconds, i.e.
-- 60-900 seconds in this deployment's configured policies) supersession
-- search, it is never disqualified from recovery by its age. This also
-- restores TimescaleDB's chunk-exclusion ability on the query (a bounded
-- time range, not an open-ended one), which is what makes it fast.
--
-- Preserves unchanged: idempotency (still ON CONFLICT DO NOTHING /
-- SKIP LOCKED), the retry cap (replay_attempt_count<5), next_replay_at
-- backoff schedule, failure classification, tenant/device identity
-- resolution, normalization behavior, and the advisory-lock-free
-- FOR UPDATE SKIP LOCKED concurrency model -- none of those lines are
-- touched by this migration.
-- ============================================================================

BEGIN;

COMMENT ON COLUMN config.telemetry_capture_policies.late_arrival_tolerance_seconds IS
'Governs two related things: (1) canonical finalization lateness -- how long past a bucket''s nominal end (bucket_start + capture_interval_seconds) a raw sample may still arrive and be selected as that bucket''s canonical sample (telemetry.resolve_site_capture_bucket, the set-based batch pipeline in postgres/ddl/127_set_based_capture_selection_legacy_recovery.sql); and (2) supersession eligibility during failed-message recovery (telemetry.recover_failed_raw_messages, migration 201) -- a later sample can only supersede a failed candidate if its received_at falls within [bucket_start, bucket_start + capture_interval_seconds + late_arrival_tolerance_seconds], the same window definition used for (1).';

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
            SELECT source_np.* FROM telemetry.v_normalized_points source_np
            WHERE source_np.raw_message_id=s.raw_message_id
              AND source_np.device_id=s.device_id
              AND source_np.event_time=s.event_time
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
    END LOOP;
END;
$procedure$;

-- Ownership and grants are preserved as-is by CREATE OR REPLACE PROCEDURE --
-- not touched here.

COMMIT;
