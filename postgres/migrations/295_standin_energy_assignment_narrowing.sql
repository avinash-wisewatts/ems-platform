-- ============================================================================
-- Migration 295
-- One-time staging narrowing of the System Energy stand-in assignments
-- (Product Owner decision pending; ADR-018 / ADR-022 rules unchanged).
--
-- Background. On staging, 108 metadata.asset_points rows -- ENERGY_IMPORT_TOTAL
-- and ENERGY_EXPORT_TOTAL for each of the 54 assets -- were written in one
-- statement at 2026-09-25 21:06:21.442284 IST with effective_from =
-- '-infinity' and no audit record (ADR-022 decision 4: staging-only
-- stand-in rows, not commissioning). Read-only evidence (2026-10-09/10, one
-- meter at a time): narrowing each row to its meter point's first GOOD
-- reading hides no System Energy 15-minute or 1-minute row on any meter; the
-- first 15-minute period straddling the first reading stays with the
-- assignment that starts inside it (the Energy read's rule).
--
-- Scope of this migration: 92 of the 108 rows. The 16 rows of the
-- Eniscope_2_Plumbing gateway are excluded by decision (the wrapper refuses
-- that gateway).
--
-- Objects (none granted; run manually by an operator as ems_admin, one
-- gateway per call, after explicit approval):
--   1. admin.standin_energy_narrow_plan(created_at, gateway_id) -- STABLE.
--   2. admin.narrow_standin_energy_assignments_core(...) -- the operation.
--   3. admin.narrow_standin_energy_assignments_20260925(actor, gateway_id,
--      dry_run, confirm_count) -- the one-time wrapper (stand-in creation
--      time, 108 expected rows, Eniscope_2_Plumbing refused).
--   4. admin.revert_standin_energy_narrowing(actor, audit_id, dry_run,
--      confirm_count) -- guarded rollback of one executed call.
--
-- Rules (per stand-in row on the requested gateway):
--   * Scope: rows created exactly at the stand-in time with logical point
--     ENERGY_IMPORT_TOTAL or ENERGY_EXPORT_TOTAL. The call refuses unless
--     exactly the expected number of such rows exists (108; none -> nothing
--     to do, every other database). Only rows still at -infinity are
--     candidates; already narrowed rows are SKIPPED_NOT_INFINITY.
--   * Proposed start = the first GOOD numeric reading of that meter point:
--     the first GOOD-only analytics.point_telemetry_15m row of the point,
--     then the first GOOD raw reading inside it (two bounded index probes).
--   * The row is NOT narrowed (NO_CHANGE_*) when:
--       - the point has no GOOD 15-minute row (NO_READING);
--       - the raw readings of that first 15-minute row are gone
--         (RAW_EXPIRED -- retention guard: never pick a later reading);
--       - any VALID System Energy row of that direction would fall wholly
--         before the new start: analytics.energy_consumption_15min
--         (bucket end <= start) or analytics.energy_consumption_1min
--         (minute end <= start) (WOULD_HIDE_ENERGY -- the evidence-based
--         invariant: narrowing must hide nothing);
--       - a closed row's end is not after the new start (AFTER_END).
--   * Never sets -infinity; only ever moves -infinity to a finite start.
--   * Dry run (default) writes nothing (read-only transaction).
--   * Execution: requires the dry run's NARROW count; locks the rows;
--     updates effective_from only, guarded by "still -infinity at the
--     stand-in time"; writes one admin.onboarding_audit record
--     (NARROW_STANDIN_ENERGY_ASSIGNMENTS) with every row's before/after.
--   * Rollback: admin.revert_standin_energy_narrowing puts '-infinity' back
--     for the rows of one executed call that still carry the recorded
--     'after' start, with its own confirmation and audit record.
--
-- Known consequence (decision required before execution): the Analytics
-- catalogue labels a binding PARITY_BRIDGE only while its start is
-- -infinity (migration 288); narrowed rows read as CONFIRMED (internal,
-- not exposed). Assignment periods in the catalogue start at the first
-- reading instead of being unbounded.
--
-- No table, index, job, policy or telemetry change. Applying this migration
-- changes no data; only an approved, explicit call does.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regclass('metadata.asset_points') IS NULL
       OR to_regclass('admin.onboarding_audit') IS NULL
       OR to_regclass('telemetry.normalized_points') IS NULL
       OR to_regclass('analytics.point_telemetry_15m') IS NULL
       OR to_regclass('analytics.energy_consumption_15min') IS NULL
       OR to_regclass('analytics.energy_consumption_1min') IS NULL THEN
        RAISE EXCEPTION 'Migration 295 precondition failed: a required table or view is missing.';
    END IF;
    IF to_regprocedure('admin.bulk_restore_first_reading(uuid, uuid, timestamptz, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 295 precondition failed: admin.bulk_restore_first_reading (migration 294) is missing.';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
               WHERE n.nspname = 'admin'
                 AND p.proname IN ('standin_energy_narrow_plan', 'narrow_standin_energy_assignments_core',
                                   'narrow_standin_energy_assignments_20260925',
                                   'revert_standin_energy_narrowing')) THEN
        RAISE EXCEPTION 'Migration 295 precondition failed: a migration 295 function already exists.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. admin.standin_energy_narrow_plan
-- ----------------------------------------------------------------------------

CREATE FUNCTION admin.standin_energy_narrow_plan
(
    p_created_at TIMESTAMPTZ,
    p_gateway_id UUID
)
RETURNS TABLE
(
    asset_point_id          UUID,
    asset_id                UUID,
    asset_name              TEXT,
    device_id               UUID,
    device_name             TEXT,
    point_name              TEXT,
    action                  TEXT,
    current_effective_from  TIMESTAMPTZ,
    effective_to            TIMESTAMPTZ,
    proposed_effective_from TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
    WITH standin AS MATERIALIZED (
        SELECT ap.id AS ap_id, ap.asset_id AS a_id, a.name AS a_name, ap.device_id AS d_id, d.name AS d_name,
               ap.logical_point_id AS lp_id, lp.name AS lp_name, ap.effective_from AS ef, ap.effective_to AS et,
               (lp.name = 'ENERGY_IMPORT_TOTAL') AS is_import
        FROM metadata.asset_points AS ap
        JOIN metadata.devices AS d ON d.id = ap.device_id
        JOIN metadata.assets AS a ON a.id = ap.asset_id
        JOIN metadata.logical_points AS lp ON lp.id = ap.logical_point_id
        WHERE ap.created_at = p_created_at
          AND lp.name IN ('ENERGY_IMPORT_TOTAL', 'ENERGY_EXPORT_TOTAL')
          AND d.gateway_id = p_gateway_id
    ),
    first_bucket AS MATERIALIZED (
        SELECT s.*,
               (SELECT q.bucket_start FROM analytics.point_telemetry_15m AS q
                WHERE s.ef = '-infinity'::timestamptz
                  AND q.device_id = s.d_id AND q.logical_point_id = s.lp_id AND q.sample_count > 0
                ORDER BY q.bucket_start LIMIT 1) AS b0
        FROM standin AS s
    ),
    first_raw AS MATERIALIZED (
        SELECT f.*,
               CASE WHEN f.b0 IS NOT NULL
                    THEN admin.bulk_restore_first_reading(f.d_id, f.lp_id, f.b0, f.b0 + INTERVAL '15 minutes')
               END AS r0
        FROM first_bucket AS f
    ),
    checked AS (
        SELECT r.*,
               CASE
                   WHEN r.ef <> '-infinity'::timestamptz THEN 'SKIPPED_NOT_INFINITY'
                   WHEN r.b0 IS NULL THEN 'NO_CHANGE_NO_READING'
                   WHEN r.r0 IS NULL THEN 'NO_CHANGE_RAW_EXPIRED'
                   WHEN r.et IS NOT NULL AND r.et <= r.r0 THEN 'NO_CHANGE_AFTER_END'
                   WHEN EXISTS (SELECT 1 FROM analytics.energy_consumption_15min AS e
                                WHERE e.device_id = r.d_id
                                  AND e.bucket_start <= r.r0 - INTERVAL '15 minutes'
                                  AND CASE WHEN r.is_import THEN e.valid_import_intervals > 0
                                           ELSE e.valid_export_intervals > 0 END)
                     OR EXISTS (SELECT 1 FROM analytics.energy_consumption_1min AS e
                                WHERE e.device_id = r.d_id
                                  AND e.bucket_start <= r.r0 - INTERVAL '1 minute'
                                  AND CASE WHEN r.is_import THEN e.import_is_valid ELSE e.export_is_valid END)
                        THEN 'NO_CHANGE_WOULD_HIDE_ENERGY'
                   ELSE 'NARROW'
               END AS act
        FROM first_raw AS r
    )
    SELECT c.ap_id, c.a_id, c.a_name, c.d_id, c.d_name, c.lp_name, c.act, c.ef, c.et,
           CASE WHEN c.act = 'NARROW' THEN c.r0 END
    FROM checked AS c
    ORDER BY c.a_name, c.lp_name;
$function$;

ALTER FUNCTION admin.standin_energy_narrow_plan(TIMESTAMPTZ, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.standin_energy_narrow_plan(TIMESTAMPTZ, UUID) FROM PUBLIC;

COMMENT ON FUNCTION admin.standin_energy_narrow_plan(TIMESTAMPTZ, UUID) IS
'Migration 295: read-only plan for narrowing the System Energy stand-in assignments (ENERGY_IMPORT_TOTAL / ENERGY_EXPORT_TOTAL rows with effective_from -infinity created exactly at p_created_at) of one gateway to their meter point''s first GOOD reading; NO_CHANGE when there is no reading, its raw readings expired, the row would end before it, or any valid System Energy 15-minute / 1-minute row would fall wholly before it. Not granted.';


-- ----------------------------------------------------------------------------
-- 2. admin.narrow_standin_energy_assignments_core
-- ----------------------------------------------------------------------------

CREATE FUNCTION admin.narrow_standin_energy_assignments_core
(
    p_actor                TEXT,
    p_created_at           TIMESTAMPTZ,
    p_expected_rows        INTEGER,
    p_gateway_id           UUID,
    p_excluded_gateway_ids UUID[],
    p_dry_run              BOOLEAN,
    p_confirm_count        INTEGER
)
RETURNS TABLE
(
    asset_point_id          UUID,
    asset_name              TEXT,
    device_name             TEXT,
    point_name              TEXT,
    action                  TEXT,
    current_effective_from  TIMESTAMPTZ,
    effective_to            TIMESTAMPTZ,
    proposed_effective_from TIMESTAMPTZ,
    audit_transaction_id    UUID
)
LANGUAGE plpgsql
VOLATILE
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_rows     INTEGER;
    v_plan     JSONB;
    v_narrow   INTEGER;
    v_updated  INTEGER;
    v_audit_id UUID;
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION 'p_actor is required.' USING ERRCODE = '22023';
    END IF;
    IF p_gateway_id IS NULL OR p_created_at IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'p_gateway_id, p_created_at and p_dry_run are required.' USING ERRCODE = '22023';
    END IF;
    IF p_gateway_id = ANY (COALESCE(p_excluded_gateway_ids, '{}'::uuid[])) THEN
        RAISE EXCEPTION 'Gateway % is excluded from this operation. Nothing was changed.', p_gateway_id USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM metadata.gateways AS g WHERE g.id = p_gateway_id) THEN
        RAISE EXCEPTION 'Gateway % does not exist.', p_gateway_id USING ERRCODE = '22023';
    END IF;

    -- The stand-in set (every gateway, narrowed or not) must be exactly as
    -- reviewed: the rows created by the stand-in statement.
    SELECT count(*) INTO v_rows
    FROM metadata.asset_points AS ap
    JOIN metadata.logical_points AS lp ON lp.id = ap.logical_point_id
    WHERE ap.created_at = p_created_at
      AND lp.name IN ('ENERGY_IMPORT_TOTAL', 'ENERGY_EXPORT_TOTAL');
    IF v_rows = 0 THEN
        RAISE NOTICE 'No stand-in assignments created at % in this database: nothing to do.', p_created_at;
        RETURN;
    END IF;
    IF v_rows <> p_expected_rows THEN
        RAISE EXCEPTION 'Stand-in mismatch: found % stand-in rows, expected %. Nothing was changed.',
            v_rows, p_expected_rows USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(p)), '[]'::jsonb), count(*) FILTER (WHERE p.action = 'NARROW')
    INTO v_plan, v_narrow
    FROM admin.standin_energy_narrow_plan(p_created_at, p_gateway_id) AS p;

    IF NOT p_dry_run THEN
        IF p_confirm_count IS NULL OR p_confirm_count <> v_narrow THEN
            RAISE EXCEPTION 'Confirmation mismatch: this call would narrow % rows, p_confirm_count is %. Nothing was changed.',
                v_narrow, p_confirm_count USING ERRCODE = '22023';
        END IF;

        PERFORM 1
        FROM metadata.asset_points AS ap
        WHERE ap.id IN (SELECT x.asset_point_id
                        FROM jsonb_to_recordset(v_plan) AS x(asset_point_id UUID, action TEXT)
                        WHERE x.action = 'NARROW')
        FOR UPDATE;

        UPDATE metadata.asset_points AS ap
        SET effective_from = x.proposed_effective_from
        FROM jsonb_to_recordset(v_plan) AS x(asset_point_id UUID, action TEXT, proposed_effective_from TIMESTAMPTZ)
        WHERE x.action = 'NARROW'
          AND ap.id = x.asset_point_id
          AND ap.created_at = p_created_at
          AND ap.effective_from = '-infinity'::timestamptz
          AND x.proposed_effective_from IS NOT NULL
          AND isfinite(x.proposed_effective_from)
          AND (ap.effective_to IS NULL OR x.proposed_effective_from < ap.effective_to);
        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated <> v_narrow THEN
            RAISE EXCEPTION 'Concurrent change: % of % rows could be narrowed. Nothing was changed.',
                v_updated, v_narrow USING ERRCODE = '40001';
        END IF;

        INSERT INTO admin.onboarding_audit (requested_by, request_payload, result_payload)
        VALUES (
            p_actor,
            jsonb_build_object(
                'operation', 'NARROW_STANDIN_ENERGY_ASSIGNMENTS',
                'standin_created_at', p_created_at,
                'gateway_id', p_gateway_id,
                'excluded_gateway_ids', to_jsonb(COALESCE(p_excluded_gateway_ids, '{}'::uuid[])),
                'confirm_count', p_confirm_count),
            jsonb_build_object(
                'success', TRUE,
                'narrowed_count', v_narrow,
                'narrowed', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'asset_point_id', x->'asset_point_id',
                               'asset_id', x->'asset_id',
                               'device_id', x->'device_id',
                               'logical_point_name', x->'point_name',
                               'effective_from_before', '-infinity',
                               'effective_from_after', x->'proposed_effective_from',
                               'effective_to', x->'effective_to'))
                    FROM jsonb_array_elements(v_plan) AS x
                    WHERE x->>'action' = 'NARROW'), '[]'::jsonb),
                'not_narrowed', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'asset_point_id', x->'asset_point_id',
                               'logical_point_name', x->'point_name',
                               'action', x->'action'))
                    FROM jsonb_array_elements(v_plan) AS x
                    WHERE x->>'action' <> 'NARROW'), '[]'::jsonb)))
        RETURNING id INTO v_audit_id;
    END IF;

    RETURN QUERY
    SELECT x.asset_point_id, x.asset_name, x.device_name, x.point_name, x.action,
           x.current_effective_from, x.effective_to, x.proposed_effective_from, v_audit_id
    FROM jsonb_to_recordset(v_plan) AS x(
        asset_point_id UUID, asset_name TEXT, device_name TEXT, point_name TEXT, action TEXT,
        current_effective_from TIMESTAMPTZ, effective_to TIMESTAMPTZ, proposed_effective_from TIMESTAMPTZ)
    ORDER BY x.asset_name, x.point_name;
END;
$function$;

ALTER FUNCTION admin.narrow_standin_energy_assignments_core(TEXT, TIMESTAMPTZ, INTEGER, UUID, UUID[], BOOLEAN, INTEGER) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.narrow_standin_energy_assignments_core(TEXT, TIMESTAMPTZ, INTEGER, UUID, UUID[], BOOLEAN, INTEGER) FROM PUBLIC;

COMMENT ON FUNCTION admin.narrow_standin_energy_assignments_core(TEXT, TIMESTAMPTZ, INTEGER, UUID, UUID[], BOOLEAN, INTEGER) IS
'Migration 295: one-time narrowing of the System Energy stand-in assignments of one gateway (plan: admin.standin_energy_narrow_plan). Refuses excluded gateways and unless exactly p_expected_rows stand-in rows remain at -infinity (none created at p_created_at = nothing to do). Dry run writes nothing. Execution requires p_confirm_count = the NARROW count, changes effective_from only (-infinity to the first reading) and writes one admin.onboarding_audit record (NARROW_STANDIN_ENERGY_ASSIGNMENTS) with every row''s before/after. Not granted.';


-- ----------------------------------------------------------------------------
-- 3. admin.narrow_standin_energy_assignments_20260925 -- one-time wrapper
-- ----------------------------------------------------------------------------

CREATE FUNCTION admin.narrow_standin_energy_assignments_20260925
(
    p_actor         TEXT,
    p_gateway_id    UUID,
    p_dry_run       BOOLEAN DEFAULT TRUE,
    p_confirm_count INTEGER DEFAULT NULL
)
RETURNS TABLE
(
    asset_point_id          UUID,
    asset_name              TEXT,
    device_name             TEXT,
    point_name              TEXT,
    action                  TEXT,
    current_effective_from  TIMESTAMPTZ,
    effective_to            TIMESTAMPTZ,
    proposed_effective_from TIMESTAMPTZ,
    audit_transaction_id    UUID
)
LANGUAGE sql
VOLATILE
SET search_path TO pg_catalog, admin
AS $function$
    SELECT *
    FROM admin.narrow_standin_energy_assignments_core(
        p_actor,
        TIMESTAMPTZ '2026-09-25 21:06:21.442284+05:30',          -- the stand-in statement
        108,                                                     -- rows created by that statement
        p_gateway_id,
        ARRAY['8c7dc93b-37a0-4da9-a422-ccba063cf764']::uuid[],   -- Eniscope_2_Plumbing: excluded by decision
        p_dry_run,
        p_confirm_count);
$function$;

ALTER FUNCTION admin.narrow_standin_energy_assignments_20260925(TEXT, UUID, BOOLEAN, INTEGER) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.narrow_standin_energy_assignments_20260925(TEXT, UUID, BOOLEAN, INTEGER) FROM PUBLIC;

COMMENT ON FUNCTION admin.narrow_standin_energy_assignments_20260925(TEXT, UUID, BOOLEAN, INTEGER) IS
'Migration 295: one-time staging wrapper for admin.narrow_standin_energy_assignments_core with the 2026-09-25 21:06:21.442284 IST stand-in statement and Eniscope_2_Plumbing excluded and 108 stand-in rows expected (narrowed or not). Dry run by default. Not granted.';


-- ----------------------------------------------------------------------------
-- 4. admin.revert_standin_energy_narrowing -- guarded rollback of one call
-- ----------------------------------------------------------------------------

CREATE FUNCTION admin.revert_standin_energy_narrowing
(
    p_actor          TEXT,
    p_audit_id       UUID,
    p_dry_run        BOOLEAN DEFAULT TRUE,
    p_confirm_count  INTEGER DEFAULT NULL
)
RETURNS TABLE
(
    asset_point_id         UUID,
    logical_point_name     TEXT,
    current_effective_from TIMESTAMPTZ,
    action                 TEXT,
    audit_transaction_id   UUID
)
LANGUAGE plpgsql
VOLATILE
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_items    JSONB;
    v_revert   INTEGER;
    v_updated  INTEGER;
    v_audit_id UUID;
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' OR p_audit_id IS NULL OR p_dry_run IS NULL THEN
        RAISE EXCEPTION 'p_actor, p_audit_id and p_dry_run are required.' USING ERRCODE = '22023';
    END IF;
    SELECT oa.result_payload->'narrowed' INTO v_items
    FROM admin.onboarding_audit AS oa
    WHERE oa.id = p_audit_id
      AND oa.request_payload->>'operation' = 'NARROW_STANDIN_ENERGY_ASSIGNMENTS';
    IF v_items IS NULL THEN
        RAISE EXCEPTION 'Audit record % is not a NARROW_STANDIN_ENERGY_ASSIGNMENTS record.', p_audit_id USING ERRCODE = '22023';
    END IF;

    SELECT jsonb_agg(jsonb_build_object(
               'asset_point_id', x.asset_point_id,
               'logical_point_name', x.logical_point_name,
               'current_effective_from', ap.effective_from,
               'action', CASE WHEN ap.effective_from = x.effective_from_after THEN 'REVERT' ELSE 'SKIPPED_CHANGED' END)),
           count(*) FILTER (WHERE ap.effective_from = x.effective_from_after)
    INTO v_items, v_revert
    FROM jsonb_to_recordset(v_items) AS x(asset_point_id UUID, logical_point_name TEXT, effective_from_after TIMESTAMPTZ)
    LEFT JOIN metadata.asset_points AS ap ON ap.id = x.asset_point_id;

    IF NOT p_dry_run THEN
        IF p_confirm_count IS NULL OR p_confirm_count <> v_revert THEN
            RAISE EXCEPTION 'Confirmation mismatch: this call would revert % rows, p_confirm_count is %. Nothing was changed.',
                v_revert, p_confirm_count USING ERRCODE = '22023';
        END IF;
        UPDATE metadata.asset_points AS ap
        SET effective_from = '-infinity'::timestamptz
        FROM jsonb_to_recordset(v_items) AS x(asset_point_id UUID, action TEXT, current_effective_from TIMESTAMPTZ)
        WHERE x.action = 'REVERT'
          AND ap.id = x.asset_point_id
          AND ap.effective_from = x.current_effective_from;
        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated <> v_revert THEN
            RAISE EXCEPTION 'Concurrent change: % of % rows could be reverted. Nothing was changed.',
                v_updated, v_revert USING ERRCODE = '40001';
        END IF;
        INSERT INTO admin.onboarding_audit (requested_by, request_payload, result_payload)
        VALUES (p_actor,
                jsonb_build_object('operation', 'REVERT_STANDIN_ENERGY_NARROWING', 'reverted_audit_id', p_audit_id,
                                   'confirm_count', p_confirm_count),
                jsonb_build_object('success', TRUE, 'reverted_count', v_revert, 'rows', v_items))
        RETURNING id INTO v_audit_id;
    END IF;

    RETURN QUERY
    SELECT x.asset_point_id, x.logical_point_name, x.current_effective_from, x.action, v_audit_id
    FROM jsonb_to_recordset(v_items) AS x(asset_point_id UUID, logical_point_name TEXT,
                                          current_effective_from TIMESTAMPTZ, action TEXT)
    ORDER BY x.logical_point_name, x.asset_point_id;
END;
$function$;

ALTER FUNCTION admin.revert_standin_energy_narrowing(TEXT, UUID, BOOLEAN, INTEGER) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.revert_standin_energy_narrowing(TEXT, UUID, BOOLEAN, INTEGER) FROM PUBLIC;

COMMENT ON FUNCTION admin.revert_standin_energy_narrowing(TEXT, UUID, BOOLEAN, INTEGER) IS
'Migration 295: guarded rollback of one admin.narrow_standin_energy_assignments call: puts -infinity back on the rows listed in that NARROW_STANDIN_ENERGY_ASSIGNMENTS audit record that still carry the recorded new start. Dry run by default; execution requires the REVERT count and writes a REVERT_STANDIN_ENERGY_NARROWING audit record. Not granted.';


-- ----------------------------------------------------------------------------
-- 5. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'admin.standin_energy_narrow_plan(timestamptz, uuid)',
        'admin.narrow_standin_energy_assignments_core(text, timestamptz, integer, uuid, uuid[], boolean, integer)',
        'admin.narrow_standin_energy_assignments_20260925(text, uuid, boolean, integer)',
        'admin.revert_standin_energy_narrowing(text, uuid, boolean, integer)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND NOT p.prosecdef
              AND r.rolname = 'ems_admin'
              AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 295 postcondition failed: % is not SECURITY INVOKER / ems_admin / pinned search_path.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE')
           OR has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 295 postcondition failed: % is executable by PUBLIC or ems_app.', v_sig;
        END IF;
    END LOOP;
    RAISE NOTICE 'Migration 295: all postconditions passed (one-time stand-in Energy narrowing; not granted; no data changed).';
END;
$post$;
