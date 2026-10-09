-- ============================================================================
-- Migration 294
-- One-time staging restoration of asset history for the 9 October 2026 bulk
-- assignment (Product Owner decision, 2026-10-09; one-time exception --
-- ADR-018 decisions 5/6 and Amendments 6/8 are NOT changed).
--
-- Background. On staging, 55 audited admin.save_asset_point_assignments()
-- calls at 2026-10-09 12:56:55.116554 IST (the "bulk assignment") added
-- 3,021 metadata.asset_points rows to 54 ACTIVE assets. Save always starts a
-- new assignment at now() and ACTIVE assets are never backfilled (decision
-- 6, migration 287), so every one of those points shows history only from
-- the bulk time although its meter has valid readings from late August.
--
-- The existing commissioning backfill (migrations 256-258/287) cannot do
-- this safely: it refuses ACTIVE assets, allows one record per asset, and
-- its lower bound (the latest earlier closed binding of the same meter
-- point) would FILL a deliberate assignment gap instead of preserving it
-- (Banquet 2 AHU Energy Export, closed 2026-10-05 21:04 and re-added by the
-- bulk assignment). This migration therefore adds a dedicated, narrowly
-- scoped operation.
--
-- Objects (none granted; run manually by an operator as ems_admin, one
-- gateway at a time, after explicit approval):
--   1. admin.bulk_restore_first_reading(...) -- STABLE: the first valid
--      reading of one meter point in a window.
--   2. admin.bulk_assignment_restore_plan(...) -- STABLE: every bulk row of
--      one gateway, classified, with its proposed start.
--   3. admin.restore_bulk_assignment_history_core(...) -- the operation,
--      parameterised (bulk Save time, expected audit/row counts, excluded
--      assets, as-of) so it can be tested.
--   4. admin.restore_bulk_assignment_history_20261009(actor, gateway_id,
--      dry_run, confirm_restore_count) -- the one-time wrapper with the
--      staging bulk Save time, the expected counts (55 audits, 3,021 rows),
--      the excluded asset (P1-HeatVentUnit-01, kept unchanged by decision)
--      and as-of now() fixed.
--
-- Rules (per row added by the bulk Save audits; nothing else is written):
--   * Scope: only asset_points rows listed in result_payload->'added' of the
--     SAVE_ASSET_POINT_ASSIGNMENTS audits created exactly at the bulk Save
--     time, and only for meters on the requested gateway. If no such audit
--     exists (every other database) the call returns nothing; if the audit
--     or row counts differ from the expected ones it refuses.
--   * Eligible only if the asset is not excluded and is ACTIVE, the row is
--     still open (effective_to IS NULL) and still starts at the bulk time,
--     no OTHER asset_points row exists for the same meter point (another
--     asset or an earlier, closed period -- this preserves deliberate gaps),
--     and the meter is not related to another asset (metadata.asset_devices).
--   * New start = the first valid reading (quality GOOD, numeric) of that
--     meter point in telemetry.normalized_points within
--     [lower bound, current start), where lower bound = the later of
--     as-of - 90 days (the ADR-018 Amendment 8 limit) and the latest
--     archived relationship of the meter (asset_device_relationship_history;
--     the AirSense sensor's Banquet 1 AHU period). Never -infinity; only
--     ever earlier than the current start; no reading -> no change.
--   * Lookup: the first GOOD-only analytics.point_telemetry_15m row that can
--     hold such a reading (index device_id, logical_point_id, bucket_start),
--     then the first GOOD raw reading inside that 15-minute bucket -- two
--     bounded index probes per row, never a scan (staging capacity).
--   * Dry run (default): no writes at all; runs in a read-only transaction.
--   * Execution: requires p_confirm_restore_count = the number of RESTORE
--     rows the same call computes (the reviewed dry run's count); locks the
--     rows, updates effective_from only, guarded by "still open and still at
--     the bulk time", and writes ONE admin.onboarding_audit record with every
--     restored row's before/after start and every other row's reason. Any
--     mismatch aborts the whole call; nothing is partially applied.
--   * Read-time attribution only: B3 measurements, per-phase Energy and the
--     Analytics catalogue read asset_points at query time, so restored
--     history is visible immediately. Persisted asset-level results (Demand
--     intervals, environment routing) are not recomputed.
--
-- No table, index, job, policy or telemetry change. Applying this migration
-- changes no data; only an approved, explicit call does.
-- Rollback of the migration: DROP the four functions. Rollback of an
-- executed restore: the audit record holds every row's previous start.
-- ============================================================================

DO $pre$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'admin' AND p.proname = 'save_asset_point_assignments') THEN
        RAISE EXCEPTION 'Migration 294 precondition failed: admin.save_asset_point_assignments (migration 255) is missing.';
    END IF;
    IF to_regclass('metadata.asset_points') IS NULL
       OR to_regclass('metadata.asset_devices') IS NULL
       OR to_regclass('admin.onboarding_audit') IS NULL
       OR to_regclass('metadata.asset_device_relationship_history') IS NULL
       OR to_regclass('telemetry.normalized_points') IS NULL
       OR to_regclass('analytics.point_telemetry_15m') IS NULL THEN
        RAISE EXCEPTION 'Migration 294 precondition failed: a required table or view is missing.';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
               WHERE n.nspname = 'admin'
                 AND p.proname IN ('bulk_restore_first_reading', 'bulk_assignment_restore_plan',
                                   'restore_bulk_assignment_history_core',
                                   'restore_bulk_assignment_history_20261009')) THEN
        RAISE EXCEPTION 'Migration 294 precondition failed: a migration 294 function already exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. admin.bulk_restore_first_reading -- first GOOD reading of one meter point
--    in [p_lower, p_before): the first GOOD-only 15-minute row that can hold
--    one, then the first GOOD raw reading inside it; the next bucket only
--    when that bucket's readings all precede p_lower. At most one day of
--    buckets is stepped through.
-- ----------------------------------------------------------------------------

CREATE FUNCTION admin.bulk_restore_first_reading
(
    p_device_id        UUID,
    p_logical_point_id UUID,
    p_lower            TIMESTAMPTZ,
    p_before           TIMESTAMPTZ
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
SET search_path TO pg_catalog, telemetry, analytics
AS $function$
DECLARE
    c_15m CONSTANT INTERVAL := INTERVAL '15 minutes';
    v_bucket TIMESTAMPTZ;
    v_first  TIMESTAMPTZ;
    v_steps  INTEGER := 0;
BEGIN
    IF p_lower IS NULL OR p_before IS NULL OR NOT isfinite(p_lower) OR p_lower >= p_before THEN
        RETURN NULL;
    END IF;
    v_bucket := date_bin(c_15m, p_lower, TIMESTAMPTZ '2000-01-01 00:00:00+00') - c_15m;
    LOOP
        SELECT q.bucket_start INTO v_bucket
        FROM analytics.point_telemetry_15m AS q
        WHERE q.device_id = p_device_id
          AND q.logical_point_id = p_logical_point_id
          AND q.bucket_start > v_bucket
          AND q.bucket_start + c_15m > p_lower
          AND q.bucket_start < p_before
          AND q.sample_count > 0
        ORDER BY q.bucket_start
        LIMIT 1;
        EXIT WHEN NOT FOUND;

        SELECT np.event_time INTO v_first
        FROM telemetry.normalized_points AS np
        WHERE np.device_id = p_device_id
          AND np.logical_point_id = p_logical_point_id
          AND np.event_time >= GREATEST(v_bucket, p_lower)
          AND np.event_time < LEAST(v_bucket + c_15m, p_before)
          AND np.quality_code = 'GOOD'
          AND np.numeric_value IS NOT NULL
        ORDER BY np.event_time
        LIMIT 1;
        IF v_first IS NOT NULL THEN
            RETURN v_first;
        END IF;

        v_steps := v_steps + 1;
        EXIT WHEN v_steps >= 96;
    END LOOP;
    RETURN NULL;
END;
$function$;

ALTER FUNCTION admin.bulk_restore_first_reading(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.bulk_restore_first_reading(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION admin.bulk_restore_first_reading(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) IS
'Migration 294: the first GOOD numeric telemetry.normalized_points reading of one meter point in [p_lower, p_before), located through the GOOD-only analytics.point_telemetry_15m rows with bounded index probes. NULL when none. Read-only. Not granted.';


-- ----------------------------------------------------------------------------
-- 2. admin.bulk_assignment_restore_plan -- every row the bulk audits added
--    for one gateway's meters, classified, with its proposed start.
-- ----------------------------------------------------------------------------

CREATE FUNCTION admin.bulk_assignment_restore_plan
(
    p_bulk_saved_at      TIMESTAMPTZ,
    p_gateway_id         UUID,
    p_excluded_asset_ids UUID[],
    p_as_of              TIMESTAMPTZ
)
RETURNS TABLE
(
    asset_point_id          UUID,
    asset_id                UUID,
    asset_name              TEXT,
    device_id               UUID,
    device_name             TEXT,
    logical_point_id        UUID,
    point_name              TEXT,
    action                  TEXT,
    current_effective_from  TIMESTAMPTZ,
    proposed_effective_from TIMESTAMPTZ,
    lower_bound             TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SET search_path TO pg_catalog, admin, metadata
AS $function$
    WITH bulk AS (
        SELECT DISTINCT (e->>'asset_point_id')::uuid AS ap_id
        FROM admin.onboarding_audit AS oa
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(oa.result_payload->'added', '[]'::jsonb)) AS e
        WHERE oa.created_at = p_bulk_saved_at
          AND oa.request_payload->>'operation' = 'SAVE_ASSET_POINT_ASSIGNMENTS'
    ),
    classified AS (
        SELECT ap.id AS ap_id, ap.asset_id AS a_id, a.name AS a_name, ap.device_id AS d_id, d.name AS d_name,
               ap.logical_point_id AS lp_id, lp.name AS lp_name, ap.effective_from AS ef,
               CASE
                   WHEN ap.asset_id = ANY (COALESCE(p_excluded_asset_ids, '{}'::uuid[])) THEN 'EXCLUDED_ASSET'
                   WHEN a.lifecycle_status IS DISTINCT FROM 'ACTIVE' THEN 'EXCLUDED_ASSET_NOT_ACTIVE'
                   WHEN ap.effective_to IS NOT NULL THEN 'SKIPPED_CLOSED'
                   WHEN ap.effective_from <> p_bulk_saved_at THEN 'SKIPPED_START_CHANGED'
                   WHEN EXISTS (SELECT 1 FROM metadata.asset_points AS o
                                WHERE o.device_id = ap.device_id
                                  AND o.logical_point_id = ap.logical_point_id
                                  AND o.id <> ap.id) THEN 'EXCLUDED_OTHER_BINDING'
                   WHEN EXISTS (SELECT 1 FROM metadata.asset_devices AS x
                                WHERE x.device_id = ap.device_id
                                  AND x.asset_id <> ap.asset_id) THEN 'EXCLUDED_SHARED_METER'
               END AS excl,
               GREATEST(p_as_of - INTERVAL '90 days',
                        COALESCE((SELECT max(h.archived_at) FROM metadata.asset_device_relationship_history AS h
                                  WHERE h.device_id = ap.device_id), '-infinity'::timestamptz)) AS lower_b
        FROM bulk AS b
        JOIN metadata.asset_points AS ap ON ap.id = b.ap_id
        JOIN metadata.devices AS d ON d.id = ap.device_id
        JOIN metadata.assets AS a ON a.id = ap.asset_id
        JOIN metadata.logical_points AS lp ON lp.id = ap.logical_point_id
        WHERE d.gateway_id = p_gateway_id
    )
    SELECT c.ap_id, c.a_id, c.a_name, c.d_id, c.d_name, c.lp_id, c.lp_name,
           COALESCE(c.excl, CASE WHEN f.first_reading IS NOT NULL THEN 'RESTORE' ELSE 'NO_CHANGE_NO_HISTORY' END),
           c.ef,
           CASE WHEN c.excl IS NULL THEN f.first_reading END,
           c.lower_b
    FROM classified AS c
    LEFT JOIN LATERAL (
        SELECT admin.bulk_restore_first_reading(c.d_id, c.lp_id, c.lower_b, c.ef) AS first_reading
        WHERE c.excl IS NULL
    ) AS f ON TRUE
    ORDER BY c.a_name, c.lp_name;
$function$;

ALTER FUNCTION admin.bulk_assignment_restore_plan(TIMESTAMPTZ, UUID, UUID[], TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.bulk_assignment_restore_plan(TIMESTAMPTZ, UUID, UUID[], TIMESTAMPTZ) FROM PUBLIC;

COMMENT ON FUNCTION admin.bulk_assignment_restore_plan(TIMESTAMPTZ, UUID, UUID[], TIMESTAMPTZ) IS
'Migration 294: read-only plan of the bulk-assignment history restore for one gateway: every asset_points row added by the SAVE_ASSET_POINT_ASSIGNMENTS audits created exactly at p_bulk_saved_at whose meter is on p_gateway_id, with its action (RESTORE, NO_CHANGE_NO_HISTORY, EXCLUDED_ASSET, EXCLUDED_ASSET_NOT_ACTIVE, SKIPPED_CLOSED, SKIPPED_START_CHANGED, EXCLUDED_OTHER_BINDING, EXCLUDED_SHARED_METER), current and proposed start and lower bound. Not granted.';


-- ----------------------------------------------------------------------------
-- 3. admin.restore_bulk_assignment_history_core
-- ----------------------------------------------------------------------------

CREATE FUNCTION admin.restore_bulk_assignment_history_core
(
    p_actor                 TEXT,
    p_bulk_saved_at         TIMESTAMPTZ,
    p_expected_audits       INTEGER,
    p_expected_rows         INTEGER,
    p_gateway_id            UUID,
    p_excluded_asset_ids    UUID[],
    p_as_of                 TIMESTAMPTZ,
    p_dry_run               BOOLEAN,
    p_confirm_restore_count INTEGER
)
RETURNS TABLE
(
    asset_point_id          UUID,
    asset_id                UUID,
    asset_name              TEXT,
    device_id               UUID,
    device_name             TEXT,
    logical_point_id        UUID,
    point_name              TEXT,
    action                  TEXT,
    current_effective_from  TIMESTAMPTZ,
    proposed_effective_from TIMESTAMPTZ,
    lower_bound             TIMESTAMPTZ,
    audit_transaction_id    UUID
)
LANGUAGE plpgsql
VOLATILE
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_audits   INTEGER;
    v_rows     INTEGER;
    v_plan     JSONB;
    v_restore  INTEGER;
    v_updated  INTEGER;
    v_audit_id UUID;
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION 'p_actor is required.' USING ERRCODE = '22023';
    END IF;
    IF p_gateway_id IS NULL OR p_bulk_saved_at IS NULL OR p_as_of IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'p_gateway_id, p_bulk_saved_at, p_as_of and p_dry_run are required.' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM metadata.gateways AS g WHERE g.id = p_gateway_id) THEN
        RAISE EXCEPTION 'Gateway % does not exist.', p_gateway_id USING ERRCODE = '22023';
    END IF;

    -- The bulk assignment, identified by its audit records only.
    SELECT count(*), COALESCE(sum(jsonb_array_length(COALESCE(oa.result_payload->'added', '[]'::jsonb))), 0)
    INTO v_audits, v_rows
    FROM admin.onboarding_audit AS oa
    WHERE oa.created_at = p_bulk_saved_at
      AND oa.request_payload->>'operation' = 'SAVE_ASSET_POINT_ASSIGNMENTS';
    IF v_audits = 0 THEN
        RAISE NOTICE 'No bulk assignment audit at % in this database: nothing to restore.', p_bulk_saved_at;
        RETURN;
    END IF;
    IF v_audits <> p_expected_audits OR v_rows <> p_expected_rows THEN
        RAISE EXCEPTION 'Bulk assignment audit mismatch: found % audits / % added rows, expected % / %. Nothing was changed.',
            v_audits, v_rows, p_expected_audits, p_expected_rows USING ERRCODE = '22023';
    END IF;

    -- The plan is computed once and kept in a variable (no temporary table:
    -- a dry run must run in a read-only transaction).
    SELECT COALESCE(jsonb_agg(to_jsonb(p)), '[]'::jsonb),
           count(*) FILTER (WHERE p.action = 'RESTORE')
    INTO v_plan, v_restore
    FROM admin.bulk_assignment_restore_plan(p_bulk_saved_at, p_gateway_id, p_excluded_asset_ids, p_as_of) AS p;

    IF NOT p_dry_run THEN
        IF p_confirm_restore_count IS NULL OR p_confirm_restore_count <> v_restore THEN
            RAISE EXCEPTION 'Confirmation mismatch: this call would restore % rows, p_confirm_restore_count is %. Nothing was changed.',
                v_restore, p_confirm_restore_count USING ERRCODE = '22023';
        END IF;

        PERFORM 1
        FROM metadata.asset_points AS ap
        WHERE ap.id IN (SELECT x.asset_point_id
                        FROM jsonb_to_recordset(v_plan) AS x(asset_point_id UUID, action TEXT)
                        WHERE x.action = 'RESTORE')
        FOR UPDATE;

        UPDATE metadata.asset_points AS ap
        SET effective_from = x.proposed_effective_from
        FROM jsonb_to_recordset(v_plan) AS x(asset_point_id UUID, action TEXT, proposed_effective_from TIMESTAMPTZ)
        WHERE x.action = 'RESTORE'
          AND ap.id = x.asset_point_id
          AND ap.effective_to IS NULL
          AND ap.effective_from = p_bulk_saved_at
          AND x.proposed_effective_from IS NOT NULL
          AND isfinite(x.proposed_effective_from)
          AND x.proposed_effective_from < ap.effective_from;
        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated <> v_restore THEN
            RAISE EXCEPTION 'Concurrent change: % of % rows could be restored. Nothing was changed.',
                v_updated, v_restore USING ERRCODE = '40001';
        END IF;

        INSERT INTO admin.onboarding_audit (requested_by, request_payload, result_payload)
        VALUES (
            p_actor,
            jsonb_build_object(
                'operation', 'RESTORE_BULK_ASSIGNMENT_HISTORY',
                'bulk_saved_at', p_bulk_saved_at,
                'gateway_id', p_gateway_id,
                'excluded_asset_ids', to_jsonb(COALESCE(p_excluded_asset_ids, '{}'::uuid[])),
                'as_of', p_as_of,
                'confirm_restore_count', p_confirm_restore_count),
            jsonb_build_object(
                'success', TRUE,
                'restored_count', v_restore,
                'restored', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'asset_point_id', x->'asset_point_id',
                               'asset_id', x->'asset_id',
                               'device_id', x->'device_id',
                               'logical_point_id', x->'logical_point_id',
                               'logical_point_name', x->'point_name',
                               'effective_from_before', x->'current_effective_from',
                               'effective_from_after', x->'proposed_effective_from',
                               'lower_bound', x->'lower_bound'))
                    FROM jsonb_array_elements(v_plan) AS x
                    WHERE x->>'action' = 'RESTORE'), '[]'::jsonb),
                'not_restored', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'asset_point_id', x->'asset_point_id',
                               'asset_id', x->'asset_id',
                               'logical_point_name', x->'point_name',
                               'action', x->'action',
                               'effective_from', x->'current_effective_from'))
                    FROM jsonb_array_elements(v_plan) AS x
                    WHERE x->>'action' <> 'RESTORE'), '[]'::jsonb)))
        RETURNING id INTO v_audit_id;
    END IF;

    RETURN QUERY
    SELECT x.asset_point_id, x.asset_id, x.asset_name, x.device_id, x.device_name, x.logical_point_id,
           x.point_name, x.action, x.current_effective_from, x.proposed_effective_from, x.lower_bound, v_audit_id
    FROM jsonb_to_recordset(v_plan) AS x(
        asset_point_id UUID, asset_id UUID, asset_name TEXT, device_id UUID, device_name TEXT,
        logical_point_id UUID, point_name TEXT, action TEXT, current_effective_from TIMESTAMPTZ,
        proposed_effective_from TIMESTAMPTZ, lower_bound TIMESTAMPTZ)
    ORDER BY x.asset_name, x.point_name;
END;
$function$;

ALTER FUNCTION admin.restore_bulk_assignment_history_core(TEXT, TIMESTAMPTZ, INTEGER, INTEGER, UUID, UUID[], TIMESTAMPTZ, BOOLEAN, INTEGER) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.restore_bulk_assignment_history_core(TEXT, TIMESTAMPTZ, INTEGER, INTEGER, UUID, UUID[], TIMESTAMPTZ, BOOLEAN, INTEGER) FROM PUBLIC;

COMMENT ON FUNCTION admin.restore_bulk_assignment_history_core(TEXT, TIMESTAMPTZ, INTEGER, INTEGER, UUID, UUID[], TIMESTAMPTZ, BOOLEAN, INTEGER) IS
'Migration 294: one-time restoration of asset history for an audited bulk assignment, one gateway per call. Refuses unless the SAVE_ASSET_POINT_ASSIGNMENTS audits created exactly at p_bulk_saved_at number p_expected_audits with p_expected_rows added rows (none = nothing to do). Plan: admin.bulk_assignment_restore_plan. Dry run writes nothing. Execution requires p_confirm_restore_count = the plan''s RESTORE count, changes effective_from only (earlier, never -infinity, only rows still open at the bulk time) and writes one admin.onboarding_audit record with every row''s before/after. Not granted.';


-- ----------------------------------------------------------------------------
-- 4. admin.restore_bulk_assignment_history_20261009 -- the one-time wrapper
-- ----------------------------------------------------------------------------

CREATE FUNCTION admin.restore_bulk_assignment_history_20261009
(
    p_actor                 TEXT,
    p_gateway_id            UUID,
    p_dry_run               BOOLEAN DEFAULT TRUE,
    p_confirm_restore_count INTEGER DEFAULT NULL
)
RETURNS TABLE
(
    asset_point_id          UUID,
    asset_id                UUID,
    asset_name              TEXT,
    device_id               UUID,
    device_name             TEXT,
    logical_point_id        UUID,
    point_name              TEXT,
    action                  TEXT,
    current_effective_from  TIMESTAMPTZ,
    proposed_effective_from TIMESTAMPTZ,
    lower_bound             TIMESTAMPTZ,
    audit_transaction_id    UUID
)
LANGUAGE sql
VOLATILE
SET search_path TO pg_catalog, admin
AS $function$
    SELECT *
    FROM admin.restore_bulk_assignment_history_core(
        p_actor,
        TIMESTAMPTZ '2026-10-09 12:56:55.116554+05:30',             -- the staging bulk Save
        55,                                                         -- its audit records
        3021,                                                       -- the rows they added
        p_gateway_id,
        ARRAY['2ac4031d-b2dc-4cf1-9549-2763f633092a']::uuid[],      -- P1-HeatVentUnit-01: kept unchanged (PO)
        now(),
        p_dry_run,
        p_confirm_restore_count);
$function$;

ALTER FUNCTION admin.restore_bulk_assignment_history_20261009(TEXT, UUID, BOOLEAN, INTEGER) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.restore_bulk_assignment_history_20261009(TEXT, UUID, BOOLEAN, INTEGER) FROM PUBLIC;

COMMENT ON FUNCTION admin.restore_bulk_assignment_history_20261009(TEXT, UUID, BOOLEAN, INTEGER) IS
'Migration 294: one-time staging wrapper for admin.restore_bulk_assignment_history_core with the 2026-10-09 12:56:55.116554 IST bulk Save (55 audits, 3,021 rows), P1-HeatVentUnit-01 excluded and as-of now(). Dry run by default; run per gateway, manually, after explicit approval. Not granted.';


-- ----------------------------------------------------------------------------
-- 5. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'admin.bulk_restore_first_reading(uuid, uuid, timestamptz, timestamptz)',
        'admin.bulk_assignment_restore_plan(timestamptz, uuid, uuid[], timestamptz)',
        'admin.restore_bulk_assignment_history_core(text, timestamptz, integer, integer, uuid, uuid[], timestamptz, boolean, integer)',
        'admin.restore_bulk_assignment_history_20261009(text, uuid, boolean, integer)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND NOT p.prosecdef
              AND r.rolname = 'ems_admin'
              AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 294 postcondition failed: % is not SECURITY INVOKER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE')
           OR has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 294 postcondition failed: % is executable by PUBLIC or ems_app.', v_sig;
        END IF;
    END LOOP;
    RAISE NOTICE 'Migration 294: all postconditions passed (one-time bulk assignment history restore; not granted; no data changed).';
END;
$post$;
