-- ============================================================================
-- ROLLBACK for migration 297 (plan T1.1). NOT a forward migration.
-- Re-creates the exact migration-213 bodies of the three reconcile procedures.
-- Apply only with explicit approval, through the normal release path (a revert
-- PR adding a new forward migration with this content), never ad hoc on staging.
-- No data is touched. Rows rewritten by reconciliation meanwhile are
-- value-identical recalculations produced by the production refresh functions.
-- ============================================================================

DO $pre$
DECLARE
    v_md5 text;
BEGIN
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
      FROM pg_proc p WHERE p.oid = 'analytics.reconcile_energy_consumption_15min(integer,jsonb)'::regprocedure;
    IF v_md5 IS DISTINCT FROM 'c0426e6b647e4ebb3b711c171270fe65' THEN
        RAISE EXCEPTION 'Migration 297 rollback precondition failed: analytics.reconcile_energy_consumption_15min body md5 % (expected c0426e6b647e4ebb3b711c171270fe65)', v_md5;
    END IF;
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
      FROM pg_proc p WHERE p.oid = 'analytics.reconcile_energy_consumption_daily(integer,jsonb)'::regprocedure;
    IF v_md5 IS DISTINCT FROM '8789f6eae5b4d92c0a3374629141ae29' THEN
        RAISE EXCEPTION 'Migration 297 rollback precondition failed: analytics.reconcile_energy_consumption_daily body md5 % (expected 8789f6eae5b4d92c0a3374629141ae29)', v_md5;
    END IF;
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
      FROM pg_proc p WHERE p.oid = 'telemetry.reconcile_environment_daily(integer,jsonb)'::regprocedure;
    IF v_md5 IS DISTINCT FROM 'e71b2511ee69b1a7f273249c31979dbe' THEN
        RAISE EXCEPTION 'Migration 297 rollback precondition failed: telemetry.reconcile_environment_daily body md5 % (expected e71b2511ee69b1a7f273249c31979dbe)', v_md5;
    END IF;
END;
$pre$;

CREATE OR REPLACE PROCEDURE analytics.reconcile_energy_consumption_15min(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'energy_consumption_15min';
    v_fwd_lock  CONSTANT text := 'analytics.run_energy_consumption_15min_job';
    v_rw        INTERVAL := INTERVAL '8 days';
    v_coarse    INTERVAL := INTERVAL '1 hour';
    v_nmax      INTEGER  := 6;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_rows_ex   bigint  := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw     := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'coarse'           THEN v_coarse := (config ->> 'coarse')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax   := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        SELECT coarse_bucket_start, mism_rows
        FROM analytics.reconcile_energy_deficits(v_pipeline, v_ws, v_cp, v_coarse, v_nmax + 1)
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        v_rows_ex  := v_rows_ex + r.mism_rows;
        BEGIN
            v_repaired := v_repaired
                + analytics.refresh_energy_consumption_15min(r.coarse_bucket_start,
                                                             r.coarse_bucket_start + v_coarse);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, v_rows_ex, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

CREATE OR REPLACE PROCEDURE analytics.reconcile_energy_consumption_daily(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'energy_consumption_daily';
    v_fwd_lock  CONSTANT text := 'analytics.run_energy_consumption_daily_job';
    v_rw        INTERVAL := INTERVAL '21 days';
    v_nmax      INTEGER  := 6;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw   := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        WITH sites AS (
            SELECT st.id AS site_id, st.timezone
            FROM metadata.sites st
            WHERE COALESCE(st.lifecycle_status, 'ACTIVE') <> 'DECOMMISSIONED'
        ),
        days AS (
            SELECT si.site_id, si.timezone,
                   (g.d)::date AS local_date,
                   ((g.d)::date::timestamp AT TIME ZONE si.timezone)              AS local_start_utc,
                   (((g.d)::date + 1)::timestamp AT TIME ZONE si.timezone)        AS local_end_utc
            FROM sites si
            CROSS JOIN LATERAL generate_series(
                (v_ws AT TIME ZONE si.timezone)::date,
                (v_cp AT TIME ZONE si.timezone)::date,
                INTERVAL '1 day') g(d)
        ),
        parent AS (
            SELECT s.device_id, dy.local_start_utc, dy.local_end_utc,
                   sum(s.source_interval_count)::bigint AS p_si,
                   max(s.calculated_at) AS p_calc
            FROM days dy
            JOIN analytics.energy_consumption_15min s
              ON s.site_id = dy.site_id
             AND s.bucket_start >= dy.local_start_utc
             AND s.bucket_start <  dy.local_end_utc
            GROUP BY s.device_id, dy.local_start_utc, dy.local_end_utc
        ),
        child AS (
            SELECT c.device_id, c.bucket_start AS local_start_utc,
                   c.source_interval_count::bigint AS c_si,
                   c.calculated_at AS c_calc
            FROM analytics.energy_consumption_daily c
            WHERE c.bucket_start >= v_ws AND c.bucket_start < v_cp
        ),
        mism AS (
            SELECT DISTINCT p.local_start_utc, p.local_end_utc
            FROM parent p
            LEFT JOIN child c ON c.device_id = p.device_id AND c.local_start_utc = p.local_start_utc
            WHERE c.device_id IS NULL
               OR p.p_si   IS DISTINCT FROM c.c_si
               OR p.p_calc > c.c_calc
        )
        SELECT local_start_utc, local_end_utc
        FROM mism
        ORDER BY local_start_utc
        LIMIT v_nmax + 1
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        BEGIN
            v_repaired := v_repaired
                + analytics.refresh_energy_consumption_daily(r.local_start_utc, r.local_end_utc);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, NULL, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

CREATE OR REPLACE PROCEDURE telemetry.reconcile_environment_daily(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'telemetry', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'environment_daily';
    v_fwd_lock  CONSTANT text := 'telemetry.run_environment_daily_job';
    v_rw        INTERVAL := INTERVAL '35 days';
    v_nmax      INTEGER  := 8;
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_examined  integer := 0;
    v_mismatch  integer := 0;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
    r           RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw   := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax := (config ->> 'n_max')::INTEGER; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    FOR r IN
        WITH sites AS (
            SELECT st.id AS site_id, st.timezone
            FROM metadata.sites st
            WHERE COALESCE(st.lifecycle_status, 'ACTIVE') <> 'DECOMMISSIONED'
        ),
        days AS (
            SELECT si.site_id, si.timezone,
                   ((g.d)::date::timestamp AT TIME ZONE si.timezone)              AS local_start_utc,
                   (((g.d)::date + 1)::timestamp AT TIME ZONE si.timezone)        AS local_end_utc
            FROM sites si
            CROSS JOIN LATERAL generate_series(
                (v_ws AT TIME ZONE si.timezone)::date,
                (v_cp AT TIME ZONE si.timezone)::date,
                INTERVAL '1 day') g(d)
        ),
        src AS (
            SELECT em.device_id, dy.local_start_utc, dy.local_end_utc,
                   count(*)::bigint AS src_buckets
            FROM days dy
            JOIN telemetry.environment_measurements em
              ON em.site_id = dy.site_id
             AND em.bucket_start >= dy.local_start_utc
             AND em.bucket_start <  dy.local_end_utc
            GROUP BY em.device_id, dy.local_start_utc, dy.local_end_utc
        ),
        chi AS (
            SELECT c.device_id, c.bucket_start AS local_start_utc,
                   c.sample_count::bigint AS c_cnt
            FROM telemetry.environment_daily c
            WHERE c.bucket_start >= v_ws AND c.bucket_start < v_cp
        )
        SELECT DISTINCT s.local_start_utc, s.local_end_utc
        FROM src s
        LEFT JOIN chi c ON c.device_id = s.device_id AND c.local_start_utc = s.local_start_utc
        WHERE c.device_id IS NULL
           OR s.src_buckets > c.c_cnt
        ORDER BY s.local_start_utc
        LIMIT v_nmax + 1
    LOOP
        v_examined := v_examined + 1;
        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;
        v_mismatch := v_mismatch + 1;
        BEGIN
            v_repaired := v_repaired
                + telemetry.refresh_environment_daily(r.local_start_utc, r.local_end_utc);
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_sqlstate IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(v_outcome,
        CASE WHEN v_errs > 0 THEN 'FAILED'
             WHEN v_mismatch > 0 THEN 'REPAIRED'
             ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, NULL, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

ALTER PROCEDURE analytics.reconcile_energy_consumption_15min(integer, jsonb) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.reconcile_energy_consumption_15min(integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_energy_consumption_15min(integer, jsonb) TO ems_admin;
ALTER PROCEDURE analytics.reconcile_energy_consumption_daily(integer, jsonb) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE analytics.reconcile_energy_consumption_daily(integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_energy_consumption_daily(integer, jsonb) TO ems_admin;
ALTER PROCEDURE telemetry.reconcile_environment_daily(integer, jsonb) OWNER TO ems_admin;
REVOKE ALL ON PROCEDURE telemetry.reconcile_environment_daily(integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE telemetry.reconcile_environment_daily(integer, jsonb) TO ems_admin;

DO $post$
DECLARE
    v_md5 text;
BEGIN
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
      FROM pg_proc p WHERE p.oid = 'analytics.reconcile_energy_consumption_15min(integer,jsonb)'::regprocedure;
    IF v_md5 IS DISTINCT FROM '9084fb8ba971bba246699c489df17d85' THEN
        RAISE EXCEPTION 'Migration 297 rollback postcondition failed: analytics.reconcile_energy_consumption_15min body md5 % (expected 9084fb8ba971bba246699c489df17d85)', v_md5;
    END IF;
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
      FROM pg_proc p WHERE p.oid = 'analytics.reconcile_energy_consumption_daily(integer,jsonb)'::regprocedure;
    IF v_md5 IS DISTINCT FROM '7ba7388b76488536ef41040d5b3f528a' THEN
        RAISE EXCEPTION 'Migration 297 rollback postcondition failed: analytics.reconcile_energy_consumption_daily body md5 % (expected 7ba7388b76488536ef41040d5b3f528a)', v_md5;
    END IF;
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
      FROM pg_proc p WHERE p.oid = 'telemetry.reconcile_environment_daily(integer,jsonb)'::regprocedure;
    IF v_md5 IS DISTINCT FROM '35ff7b9caf33aa0362d9096ad6090d98' THEN
        RAISE EXCEPTION 'Migration 297 rollback postcondition failed: telemetry.reconcile_environment_daily body md5 % (expected 35ff7b9caf33aa0362d9096ad6090d98)', v_md5;
    END IF;
END;
$post$;
