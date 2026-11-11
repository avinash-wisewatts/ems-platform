-- ============================================================================
-- GENERATED -- do not edit. Source: postgres/migrations/310_preserved_rtdata_backfill.sql
-- Generator: scripts/maintenance/generate_airsense_recovery_session.py
-- Identity test: app/tests/test_airsense_recovery_session.py
--
-- Session-only AirSense recovery: migration 310's packet table and functions as
-- pg_temp objects. Everything it creates disappears when the session ends.
-- Differences from migration 310 (and nothing else):
--   * telemetry.{preserved_rtdata_packets, preserved_rtdata_samples,
--     preserved_rtdata_points, backfill_preserved_rtdata} -> pg_temp.<same>;
--     the advisory-lock key 'telemetry.backfill_preserved_rtdata' is unchanged;
--   * CREATE TEMP TABLE for the packet table;
--   * no OWNER / REVOKE / COMMENT statements and no postcondition block.
--
-- Use (operator, ems_admin, one psql session; see
-- docs/10-operations/airsense-preserved-payload-recovery.md):
--   1. \i this file (or pipe it) inside the session;
--   2. load the preserved exports into pg_temp.preserved_rtdata_packets;
--   3. dry runs:  SELECT * FROM pg_temp.backfill_preserved_rtdata(actor, from, to, devices);
--   4. execution only with explicit approval: (..., false, <dry-run points_to_insert>).
-- ============================================================================

-- Preconditions (migration 310, verbatim).
DO $$
BEGIN
    IF to_regclass('telemetry.raw_message_failures') IS NULL
       OR to_regclass('telemetry.capture_bucket_samples') IS NULL
       OR to_regclass('telemetry.normalized_points') IS NULL
       OR to_regclass('telemetry.routing_recovery_queue') IS NULL
       OR to_regclass('telemetry.device_point_state') IS NULL
       OR to_regclass('telemetry.device_telemetry_state') IS NULL
       OR to_regclass('admin.onboarding_audit') IS NULL THEN
        RAISE EXCEPTION 'Migration 310 precondition failed: a required telemetry/admin table is missing.';
    END IF;
    IF to_regprocedure('telemetry.resolve_site_capture_bucket(uuid,timestamp with time zone)') IS NULL THEN
        RAISE EXCEPTION 'Migration 310 precondition failed: telemetry.resolve_site_capture_bucket(uuid, timestamptz) is missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'telemetry' AND tablename = 'normalized_points'
          AND indexname = 'uq_normalized_points_identity'
    ) THEN
        RAISE EXCEPTION 'Migration 310 precondition failed: uq_normalized_points_identity is missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'telemetry.capture_bucket_samples'::regclass
          AND conname = 'capture_bucket_samples_status_ck'
          AND pg_get_constraintdef(oid) LIKE '%RECOVERED%'
    ) THEN
        RAISE EXCEPTION 'Migration 310 precondition failed: capture_bucket_samples does not allow status RECOVERED.';
    END IF;
END $$;

-- The preserved packets (session-only).
CREATE TEMP TABLE pg_temp.preserved_rtdata_packets
(
    raw_received_at   TIMESTAMPTZ NOT NULL,
    raw_message_id    BIGINT      NOT NULL,
    source_identifier TEXT,
    payload           JSONB       NOT NULL,
    source_file       TEXT        NOT NULL,
    loaded_at         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT preserved_rtdata_packets_pkey PRIMARY KEY (raw_received_at, raw_message_id),
    CONSTRAINT preserved_rtdata_packets_rtdata_ck CHECK (jsonb_typeof(payload -> 'rtdata') = 'array'),
    CONSTRAINT preserved_rtdata_packets_source_file_ck CHECK (btrim(source_file) <> '')
);

-- pg_temp.preserved_rtdata_samples (migration 310 body, names as above).
CREATE FUNCTION pg_temp.preserved_rtdata_samples
(
    p_from       TIMESTAMPTZ,
    p_to         TIMESTAMPTZ,
    p_device_ids UUID[]
)
RETURNS TABLE
(
    device_id                      UUID,
    organization_id                UUID,
    site_id                        UUID,
    gateway_id                     UUID,
    profile_id                     UUID,
    device_uid                     TEXT,
    raw_received_at                TIMESTAMPTZ,
    raw_message_id                 BIGINT,
    event_time                     TIMESTAMPTZ,
    source_timestamp               TIMESTAMPTZ,
    policy_id                      BIGINT,
    capture_interval_seconds       INTEGER,
    late_arrival_tolerance_seconds INTEGER,
    bucket_start                   TIMESTAMPTZ,
    deadline                       TIMESTAMPTZ,
    element                        JSONB,
    sample_action                  TEXT
)
LANGUAGE sql
STABLE
SET search_path TO pg_catalog, telemetry, metadata, config
AS $function$
    WITH packets AS
    (
        SELECT pk.raw_received_at, pk.raw_message_id, pk.payload
        FROM pg_temp.preserved_rtdata_packets AS pk
        WHERE pk.raw_received_at >= p_from
          AND pk.raw_received_at <  p_to
    ),
    elements AS
    (
        -- The same array expansion and ts derivation as telemetry.v_rtdata.
        SELECT DISTINCT ON (pk.raw_received_at, pk.raw_message_id, lower(e.value ->> 'uid'))
            pk.raw_received_at,
            pk.raw_message_id,
            e.value AS element,
            e.value ->> 'uid' AS device_uid,
            CASE
                WHEN e.value ->> 'ts' IS NULL THEN NULL::TIMESTAMPTZ
                WHEN pg_input_is_valid(e.value ->> 'ts', 'double precision')
                    THEN to_timestamp((e.value ->> 'ts')::DOUBLE PRECISION)
                ELSE NULL::TIMESTAMPTZ
            END AS source_timestamp
        FROM packets AS pk
        CROSS JOIN LATERAL jsonb_array_elements(pk.payload -> 'rtdata') AS e(value)
        WHERE e.value ->> 'uid' IS NOT NULL
        ORDER BY pk.raw_received_at, pk.raw_message_id, lower(e.value ->> 'uid')
    ),
    resolved AS
    (
        SELECT
            el.*,
            COALESCE(el.source_timestamp, el.raw_received_at) AS event_time,
            d.id AS device_id,
            d.organization_id,
            d.gateway_id,
            g.site_id,
            d.profile_id
        FROM elements AS el
        JOIN metadata.device_identifiers AS di
          ON di.identifier_type = 'MQTT_UID'
         AND lower(di.identifier_value) = lower(el.device_uid)
        JOIN metadata.devices AS d
          ON d.id = di.device_id
        JOIN metadata.gateways AS g
          ON g.id = d.gateway_id
        WHERE d.id = ANY (p_device_ids)
          AND d.lifecycle_status = 'ACTIVE'
          AND d.profile_id IS NOT NULL
    ),
    bucketed AS
    (
        SELECT
            r.*,
            b.policy_id,
            b.capture_interval_seconds,
            b.late_arrival_tolerance_seconds,
            b.bucket_start,
            b.bucket_start + make_interval(secs => b.capture_interval_seconds + b.late_arrival_tolerance_seconds) AS deadline
        FROM resolved AS r
        CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(r.site_id, r.event_time) AS b
    ),
    classified AS
    (
        SELECT
            bk.*,
            CASE
                WHEN bk.policy_id IS NULL THEN 'NO_POLICY'
                WHEN bk.event_time < now() - INTERVAL '89 days' THEN 'OUT_OF_RETENTION'
                WHEN bk.deadline > now() THEN 'NOT_FINAL'
                WHEN bk.raw_received_at > bk.deadline THEN 'LATE'
            END AS exclusion
        FROM bucketed AS bk
    ),
    ranked AS
    (
        SELECT
            c.*,
            CASE WHEN c.exclusion IS NULL THEN
                row_number() OVER (
                    PARTITION BY c.site_id, c.bucket_start, c.device_id, (c.exclusion IS NULL)
                    ORDER BY c.event_time DESC, c.raw_received_at DESC, c.raw_message_id DESC
                )
            END AS bucket_rank
        FROM classified AS c
    )
    SELECT
        rk.device_id, rk.organization_id, rk.site_id, rk.gateway_id, rk.profile_id, rk.device_uid,
        rk.raw_received_at, rk.raw_message_id, rk.event_time, rk.source_timestamp,
        rk.policy_id, rk.capture_interval_seconds, rk.late_arrival_tolerance_seconds,
        rk.bucket_start, rk.deadline, rk.element,
        CASE
            WHEN rk.exclusion IS NOT NULL THEN rk.exclusion
            WHEN rk.bucket_rank > 1 THEN 'SUPERSEDED'
            WHEN EXISTS (
                SELECT 1 FROM telemetry.capture_bucket_samples AS s
                WHERE s.site_id = rk.site_id AND s.bucket_start = rk.bucket_start AND s.device_id = rk.device_id
            ) THEN 'BUCKET_TAKEN'
            ELSE 'SELECTED'
        END AS sample_action
    FROM ranked AS rk;
$function$;

-- pg_temp.preserved_rtdata_points (migration 310 body, names as above).
CREATE FUNCTION pg_temp.preserved_rtdata_points
(
    p_from       TIMESTAMPTZ,
    p_to         TIMESTAMPTZ,
    p_device_ids UUID[]
)
RETURNS TABLE
(
    device_id        UUID,
    organization_id  UUID,
    site_id          UUID,
    gateway_id       UUID,
    device_uid       TEXT,
    raw_received_at  TIMESTAMPTZ,
    raw_message_id   BIGINT,
    event_time       TIMESTAMPTZ,
    bucket_start     TIMESTAMPTZ,
    logical_point_id UUID,
    logical_point    TEXT,
    raw_field_name   TEXT,
    raw_value        TEXT,
    numeric_value    NUMERIC,
    quality_code     TEXT,
    mapping_source   TEXT,
    point_action     TEXT
)
LANGUAGE sql
STABLE
SET search_path TO pg_catalog, telemetry, metadata, config
AS $function$
    WITH selected AS
    (
        SELECT s.*
        FROM pg_temp.preserved_rtdata_samples(p_from, p_to, p_device_ids) AS s
        WHERE s.sample_action = 'SELECTED'
    ),
    profile_mappings AS
    (
        SELECT
            se.*,
            pfm.logical_point_id, lp.name AS logical_point, lp.data_type,
            pfm.raw_field_name, pfm.json_path,
            1 AS mapping_priority, 'DEVICE_PROFILE'::TEXT AS mapping_source
        FROM selected AS se
        JOIN config.profile_field_mapping AS pfm
          ON pfm.profile_id = se.profile_id
        JOIN config.device_point_configuration AS dpc
          ON dpc.device_id = se.device_id
         AND dpc.logical_point_id = pfm.logical_point_id
         AND dpc.is_enabled
        JOIN metadata.logical_points AS lp
          ON lp.id = pfm.logical_point_id
    ),
    device_mappings AS
    (
        SELECT
            se.*,
            dfm.logical_point_id, lp.name AS logical_point, lp.data_type,
            dfm.raw_field_name, NULL::TEXT AS json_path,
            2 AS mapping_priority, 'DEVICE_OVERRIDE'::TEXT AS mapping_source
        FROM selected AS se
        JOIN metadata.device_field_mapping AS dfm
          ON dfm.device_id = se.device_id
        JOIN config.device_point_configuration AS dpc
          ON dpc.device_id = se.device_id
         AND dpc.logical_point_id = dfm.logical_point_id
         AND dpc.is_enabled
        JOIN metadata.logical_points AS lp
          ON lp.id = dfm.logical_point_id
    ),
    preferred AS
    (
        SELECT DISTINCT ON (m.raw_message_id, m.device_id, m.event_time, m.logical_point_id) m.*
        FROM (SELECT * FROM profile_mappings UNION ALL SELECT * FROM device_mappings) AS m
        ORDER BY m.raw_message_id, m.device_id, m.event_time, m.logical_point_id, m.mapping_priority
    ),
    extracted AS
    (
        SELECT
            p.*,
            CASE
                WHEN p.json_path IS NULL THEN p.element ->> p.raw_field_name
                ELSE jsonb_path_query_first(p.element, p.json_path::jsonpath) #>> '{}'
            END AS raw_value
        FROM preferred AS p
    )
    SELECT
        x.device_id, x.organization_id, x.site_id, x.gateway_id, x.device_uid,
        x.raw_received_at, x.raw_message_id, x.event_time, x.bucket_start,
        x.logical_point_id, x.logical_point, x.raw_field_name, x.raw_value,
        CASE
            WHEN x.raw_value IS NULL THEN NULL::NUMERIC
            WHEN x.raw_value ~ '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
                THEN btrim(x.raw_value)::NUMERIC
            ELSE NULL::NUMERIC
        END AS numeric_value,
        CASE
            WHEN x.raw_value IS NULL THEN 'MISSING'::TEXT
            WHEN x.data_type = 'numeric'
             AND x.raw_value !~ '^[[:space:]]*[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?[[:space:]]*$'
                THEN 'INVALID_NUMERIC'::TEXT
            ELSE 'GOOD'::TEXT
        END AS quality_code,
        x.mapping_source,
        CASE
            WHEN EXISTS (
                SELECT 1 FROM telemetry.normalized_points AS np
                WHERE np.event_time = x.event_time AND np.device_id = x.device_id
                  AND np.logical_point_id = x.logical_point_id
                  -- Constant window bounds so only the window's chunks are
                  -- read (a runtime-only key scans every compressed chunk).
                  AND np.event_time >= p_from - INTERVAL '2 days'
                  AND np.event_time <  p_to + INTERVAL '1 day'
            ) THEN 'PRESENT'
            ELSE 'INSERT'
        END AS point_action
    FROM extracted AS x;
$function$;

-- pg_temp.backfill_preserved_rtdata (migration 310 body, names as above).
CREATE FUNCTION pg_temp.backfill_preserved_rtdata
(
    p_actor          TEXT,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_device_ids     UUID[],
    p_dry_run        BOOLEAN DEFAULT TRUE,
    p_confirm_points INTEGER DEFAULT NULL
)
RETURNS TABLE
(
    device_id          UUID,
    device_name        TEXT,
    elements           BIGINT,
    selected           BIGINT,
    bucket_taken       BIGINT,
    superseded         BIGINT,
    late               BIGINT,
    not_final          BIGINT,
    no_policy          BIGINT,
    out_of_retention   BIGINT,
    points_to_insert   BIGINT,
    points_present     BIGINT,
    points_inserted    BIGINT,
    failures_recovered BIGINT,
    audit_id           UUID
)
LANGUAGE plpgsql
VOLATILE
SET search_path TO pg_catalog, telemetry, metadata, config, admin
AS $function$
#variable_conflict use_column
DECLARE
    v_planned   BIGINT;
    v_inserted  BIGINT := 0;
    v_recovered BIGINT := 0;
    v_audit     UUID;
BEGIN
    IF nullif(btrim(p_actor), '') IS NULL THEN
        RAISE EXCEPTION 'An actor is required.' USING ERRCODE = '22023';
    END IF;
    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from OR p_to - p_from > INTERVAL '31 days' THEN
        RAISE EXCEPTION 'The window [p_from, p_to) must be set, non-empty and at most 31 days.' USING ERRCODE = '22023';
    END IF;
    IF p_device_ids IS NULL OR cardinality(p_device_ids) = 0 OR cardinality(p_device_ids) > 10 THEN
        RAISE EXCEPTION 'p_device_ids must list 1 to 10 devices.' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_device_ids) AS x(id)
        WHERE NOT EXISTS (
            SELECT 1 FROM metadata.devices AS d
            JOIN metadata.device_identifiers AS di ON di.device_id = d.id AND di.identifier_type = 'MQTT_UID'
            WHERE d.id = x.id AND d.lifecycle_status = 'ACTIVE' AND d.profile_id IS NOT NULL
        )
    ) THEN
        RAISE EXCEPTION 'Every device must exist, be ACTIVE, have a profile and an MQTT_UID identifier.' USING ERRCODE = '22023';
    END IF;
    IF NOT p_dry_run AND p_confirm_points IS NULL THEN
        RAISE EXCEPTION 'Execution requires p_confirm_points (the dry run''s points_to_insert total).' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('telemetry.backfill_preserved_rtdata'));

    CREATE TEMP TABLE pg_temp.prb_samples ON COMMIT DROP AS
    SELECT * FROM pg_temp.preserved_rtdata_samples(p_from, p_to, p_device_ids);

    CREATE TEMP TABLE pg_temp.prb_points ON COMMIT DROP AS
    SELECT * FROM pg_temp.preserved_rtdata_points(p_from, p_to, p_device_ids);

    CREATE TEMP TABLE pg_temp.prb_inserted (device_id UUID, event_time TIMESTAMPTZ, logical_point_id UUID) ON COMMIT DROP;

    SELECT count(*) INTO v_planned FROM pg_temp.prb_points AS p WHERE p.point_action = 'INSERT';

    IF NOT p_dry_run THEN
        IF p_confirm_points <> v_planned THEN
            RAISE EXCEPTION 'Confirmation mismatch: % points to insert, % confirmed. Nothing was changed.', v_planned, p_confirm_points
                USING ERRCODE = '22023';
        END IF;

        -- Claim each selected bucket (never one that already has a sample).
        CREATE TEMP TABLE pg_temp.prb_claimed ON COMMIT DROP AS
        WITH claimed AS
        (
            INSERT INTO telemetry.capture_bucket_samples
            (
                site_id, device_id, policy_id, bucket_start, capture_interval_seconds,
                late_arrival_tolerance_seconds, source_timestamp, event_time,
                raw_received_at, raw_message_id, status, normalized_at, last_error
            )
            SELECT s.site_id, s.device_id, s.policy_id, s.bucket_start, s.capture_interval_seconds,
                   s.late_arrival_tolerance_seconds, s.source_timestamp, s.event_time,
                   s.raw_received_at, s.raw_message_id, 'RECOVERED', clock_timestamp(), NULL
            FROM pg_temp.prb_samples AS s
            WHERE s.sample_action = 'SELECTED'
            ON CONFLICT (site_id, bucket_start, device_id) DO NOTHING
            RETURNING capture_bucket_samples.site_id, capture_bucket_samples.bucket_start, capture_bucket_samples.device_id
        )
        SELECT * FROM claimed;

        WITH ins AS
        (
            INSERT INTO telemetry.normalized_points
            (
                event_time, organization_id, site_id, gateway_id, device_id,
                logical_point_id, device_uid, logical_point, raw_field_name,
                raw_value, numeric_value, quality_code, mapping_source,
                platform_received_at, raw_message_id
            )
            SELECT p.event_time, p.organization_id, p.site_id, p.gateway_id, p.device_id,
                   p.logical_point_id, p.device_uid, p.logical_point, p.raw_field_name,
                   p.raw_value, p.numeric_value, p.quality_code, p.mapping_source,
                   p.raw_received_at, p.raw_message_id
            FROM pg_temp.prb_points AS p
            JOIN pg_temp.prb_claimed AS c
              ON c.site_id = p.site_id AND c.bucket_start = p.bucket_start AND c.device_id = p.device_id
            WHERE p.point_action = 'INSERT'
            ON CONFLICT (event_time, device_id, logical_point_id) DO NOTHING
            RETURNING normalized_points.device_id, normalized_points.event_time, normalized_points.logical_point_id
        )
        INSERT INTO pg_temp.prb_inserted SELECT * FROM ins;

        SELECT count(*) INTO v_inserted FROM pg_temp.prb_inserted;
        IF v_inserted <> v_planned THEN
            RAISE EXCEPTION 'Inserted % points, expected %: concurrent change. Nothing was changed.', v_inserted, v_planned
                USING ERRCODE = '40001';
        END IF;

        -- Route the new points to the measurement tables (migration 305 queue).
        INSERT INTO telemetry.routing_recovery_queue (raw_received_at, raw_message_id, device_id, event_time)
        SELECT DISTINCT p.raw_received_at, p.raw_message_id, p.device_id, p.event_time
        FROM pg_temp.prb_points AS p
        JOIN pg_temp.prb_inserted AS i
          ON i.device_id = p.device_id AND i.event_time = p.event_time AND i.logical_point_id = p.logical_point_id;

        -- Device point / telemetry state: the live loader's upserts.
        INSERT INTO telemetry.device_point_state
        (
            device_id, logical_point_id, first_seen_at, last_seen_at, last_received_at,
            first_valid_seen_at, last_valid_seen_at, last_valid_received_at, updated_at
        )
        SELECT
            b.device_id, b.logical_point_id, min(b.event_time), max(b.event_time), max(b.raw_received_at),
            min(b.event_time) FILTER (WHERE coalesce(b.quality_code, 'GOOD') NOT IN ('INVALID', 'REJECTED', 'INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value), '') IS NOT NULL)),
            max(b.event_time) FILTER (WHERE coalesce(b.quality_code, 'GOOD') NOT IN ('INVALID', 'REJECTED', 'INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value), '') IS NOT NULL)),
            max(b.raw_received_at) FILTER (WHERE coalesce(b.quality_code, 'GOOD') NOT IN ('INVALID', 'REJECTED', 'INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value), '') IS NOT NULL)),
            now()
        FROM pg_temp.prb_points AS b
        JOIN pg_temp.prb_inserted AS i
          ON i.device_id = b.device_id AND i.event_time = b.event_time AND i.logical_point_id = b.logical_point_id
        GROUP BY b.device_id, b.logical_point_id
        ON CONFLICT (device_id, logical_point_id) DO UPDATE
        SET first_seen_at = LEAST(telemetry.device_point_state.first_seen_at, EXCLUDED.first_seen_at),
            last_seen_at = GREATEST(telemetry.device_point_state.last_seen_at, EXCLUDED.last_seen_at),
            last_received_at = GREATEST(telemetry.device_point_state.last_received_at, EXCLUDED.last_received_at),
            first_valid_seen_at = CASE
                WHEN telemetry.device_point_state.first_valid_seen_at IS NULL THEN EXCLUDED.first_valid_seen_at
                WHEN EXCLUDED.first_valid_seen_at IS NULL THEN telemetry.device_point_state.first_valid_seen_at
                ELSE LEAST(telemetry.device_point_state.first_valid_seen_at, EXCLUDED.first_valid_seen_at)
            END,
            last_valid_seen_at = GREATEST(telemetry.device_point_state.last_valid_seen_at, EXCLUDED.last_valid_seen_at),
            last_valid_received_at = GREATEST(telemetry.device_point_state.last_valid_received_at, EXCLUDED.last_valid_received_at),
            updated_at = now();

        INSERT INTO telemetry.device_telemetry_state
        (
            device_id, latest_source_timestamp, latest_received_timestamp,
            latest_valid_source_timestamp, latest_valid_received_timestamp, updated_at
        )
        SELECT
            b.device_id, max(b.event_time), max(b.raw_received_at),
            max(b.event_time) FILTER (WHERE coalesce(b.quality_code, 'GOOD') NOT IN ('INVALID', 'REJECTED', 'INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value), '') IS NOT NULL)),
            max(b.raw_received_at) FILTER (WHERE coalesce(b.quality_code, 'GOOD') NOT IN ('INVALID', 'REJECTED', 'INVALID_NUMERIC') AND (b.numeric_value IS NOT NULL OR nullif(btrim(b.raw_value), '') IS NOT NULL)),
            now()
        FROM pg_temp.prb_points AS b
        JOIN pg_temp.prb_inserted AS i
          ON i.device_id = b.device_id AND i.event_time = b.event_time AND i.logical_point_id = b.logical_point_id
        GROUP BY b.device_id
        ORDER BY b.device_id
        ON CONFLICT (device_id) DO UPDATE
        SET latest_source_timestamp = GREATEST(telemetry.device_telemetry_state.latest_source_timestamp, EXCLUDED.latest_source_timestamp),
            latest_received_timestamp = GREATEST(telemetry.device_telemetry_state.latest_received_timestamp, EXCLUDED.latest_received_timestamp),
            latest_valid_source_timestamp = GREATEST(telemetry.device_telemetry_state.latest_valid_source_timestamp, EXCLUDED.latest_valid_source_timestamp),
            latest_valid_received_timestamp = GREATEST(telemetry.device_telemetry_state.latest_valid_received_timestamp, EXCLUDED.latest_valid_received_timestamp),
            updated_at = now();

        -- A processed packet's failure row is RECOVERED only when every
        -- allow-listed element in it has a normalized sample in its bucket.
        WITH packet_state AS
        (
            SELECT
                s.raw_received_at, s.raw_message_id,
                bool_and(EXISTS (
                    SELECT 1
                    FROM telemetry.capture_bucket_samples AS cbs
                    JOIN telemetry.normalized_points AS np
                      ON np.device_id = cbs.device_id AND np.event_time = cbs.event_time
                     AND np.event_time >= p_from - INTERVAL '2 days'
                     AND np.event_time <  p_to + INTERVAL '1 day'
                    WHERE cbs.site_id = s.site_id AND cbs.bucket_start = s.bucket_start AND cbs.device_id = s.device_id
                )) AS all_represented
            FROM pg_temp.prb_samples AS s
            WHERE s.sample_action IN ('SELECTED', 'BUCKET_TAKEN', 'SUPERSEDED', 'LATE')
            GROUP BY s.raw_received_at, s.raw_message_id
        ),
        upd AS
        (
            UPDATE telemetry.raw_message_failures AS f
            SET resolution_status = 'RECOVERED',
                resolved_at = clock_timestamp(),
                resolution_method = 'PRESERVED_PAYLOAD_BACKFILL',
                next_replay_at = NULL,
                last_replay_error = NULL
            FROM packet_state AS ps
            WHERE f.raw_received_at = ps.raw_received_at
              AND f.raw_message_id = ps.raw_message_id
              AND ps.all_represented
              AND f.resolution_status <> 'RECOVERED'
            RETURNING 1
        )
        SELECT count(*) INTO v_recovered FROM upd;

        INSERT INTO admin.onboarding_audit (requested_by, request_payload, result_payload)
        VALUES
        (
            p_actor,
            jsonb_build_object('operation', 'BACKFILL_PRESERVED_RTDATA', 'from', p_from, 'to', p_to,
                               'device_ids', to_jsonb(p_device_ids), 'confirm_points', p_confirm_points),
            jsonb_build_object(
                'success', true,
                'points_inserted', v_inserted,
                'failures_recovered', v_recovered,
                'samples', (SELECT jsonb_object_agg(a.sample_action, a.n)
                            FROM (SELECT s.sample_action, count(*) AS n FROM pg_temp.prb_samples AS s GROUP BY 1) AS a),
                'points_by_device', (SELECT jsonb_object_agg(a.device_id, a.n)
                                     FROM (SELECT i.device_id, count(*) AS n FROM pg_temp.prb_inserted AS i GROUP BY 1) AS a),
                'event_time_min', (SELECT min(i.event_time) FROM pg_temp.prb_inserted AS i),
                'event_time_max', (SELECT max(i.event_time) FROM pg_temp.prb_inserted AS i))
        )
        RETURNING id INTO v_audit;
    END IF;

    RETURN QUERY
    SELECT
        d.id,
        d.name::TEXT,
        count(s.device_id),
        count(s.device_id) FILTER (WHERE s.sample_action = 'SELECTED'),
        count(s.device_id) FILTER (WHERE s.sample_action = 'BUCKET_TAKEN'),
        count(s.device_id) FILTER (WHERE s.sample_action = 'SUPERSEDED'),
        count(s.device_id) FILTER (WHERE s.sample_action = 'LATE'),
        count(s.device_id) FILTER (WHERE s.sample_action = 'NOT_FINAL'),
        count(s.device_id) FILTER (WHERE s.sample_action = 'NO_POLICY'),
        count(s.device_id) FILTER (WHERE s.sample_action = 'OUT_OF_RETENTION'),
        (SELECT count(*) FROM pg_temp.prb_points AS p WHERE p.device_id = d.id AND p.point_action = 'INSERT'),
        (SELECT count(*) FROM pg_temp.prb_points AS p WHERE p.device_id = d.id AND p.point_action = 'PRESENT'),
        (SELECT count(*) FROM pg_temp.prb_inserted AS i WHERE i.device_id = d.id),
        v_recovered,
        v_audit
    FROM metadata.devices AS d
    LEFT JOIN pg_temp.prb_samples AS s ON s.device_id = d.id
    WHERE d.id = ANY (p_device_ids)
    GROUP BY d.id, d.name
    ORDER BY d.name;

    DROP TABLE IF EXISTS pg_temp.prb_samples, pg_temp.prb_points, pg_temp.prb_inserted, pg_temp.prb_claimed;
END;
$function$;
