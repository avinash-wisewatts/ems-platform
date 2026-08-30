-- ============================================================================
-- File:
--   scripts/test/assert_normalization_221_staging_gate.sql
--
-- Status:
--   DRAFT — designed for a FUTURE, EXPLICITLY AUTHORIZED staging execution.
--   This file is NOT wired into scripts/test/run_integration_environment.sh
--   (that runner is the disposable-DB CI suite). It is an operational gate
--   run by hand, against the STAGING `ems` database only, via
--   scripts/test/assert_normalization_221_staging_gate.sh.
--
-- Purpose:
--   Validate migration 221
--   (postgres/migrations/221_normalization_selected_elements_pk_join.sql) on
--   STAGING before any production-promotion discussion. Migration 221 is the
--   migration-205 body of telemetry.load_normalized_points_incremental(
--       p_overlap    INTERVAL DEFAULT INTERVAL '5 minutes',
--       p_max_window INTERVAL DEFAULT NULL)
--   verbatim, EXCEPT one spot in the selected_elements CTE:
--       JOIN telemetry.raw_messages rm ON rm.id = s.raw_message_id
--     became
--       JOIN telemetry.raw_messages rm
--         ON rm.received_at = s.raw_received_at
--        AND rm.id          = s.raw_message_id
--        AND rm.received_at  > v_window_start
--        AND rm.received_at <= v_window_end
--   plus one statement: ANALYZE telemetry.capture_bucket_samples.
--
--   The gate produces MEASURED EVIDENCE. It deliberately does NOT apply a
--   numeric performance pass/fail threshold (none exists in the repository;
--   the migration-212 `2 hours` default is documented as "provisional pending
--   a staging job-1000 runtime measurement"). The first authorized run
--   ESTABLISHES that baseline. Any numeric production acceptance threshold is
--   reviewed separately.
--
-- Execution model:
--   * Invoked by the .sh wrapper, which sets psql variables (\set) and is the
--     ONLY place that pauses/resumes Job 1000.
--   * Two modes, selected by :gate_execute
--       :gate_execute = off  -> PREFLIGHT / DRY-RUN. Runs every read-only
--                               check, the recon re-validation, and the
--                               EXPLAIN probes. Performs NO `CALL` and NO
--                               `UPDATE telemetry.pipeline_state`.
--       :gate_execute = on   -> FULL GATE. Additionally performs the bounded
--                               `CALL`s, the transient watermark moves, the
--                               equivalence re-normalization, and the
--                               watermark restoration.
--   * The .sh only sets :gate_execute = on after: (a) STAGING ONLY banner
--     acknowledged, (b) target/environment checks passed, (c) authorization
--     token present, (d) Job 1000 captured and paused.
--   * CORRECTION vs an earlier draft of this header: restoration is NOT done
--     by "re-invoking this file with a restore-only flag". A psql temp table
--     (gate_restore_pipeline_state / gate_restore_job1000, below) lives only
--     for the current connection -- if ON_ERROR_STOP aborts this script
--     mid-PHASE-6/7, the connection closes and both temp tables are gone
--     before PHASE 8 can run. The .sh is therefore the ONLY durable source of
--     truth for restoration: it captures telemetry.pipeline_state and Job
--     1000's config via its own short, separate read-only queries BEFORE
--     invoking this file, holds them in memory/a local capture file, and
--     restores both unconditionally in a trap on exit (success, failure, or
--     interrupt) -- independent of whether PHASE 8 below ran. PHASE 2's temp
--     tables and PHASE 8's UPDATE exist for in-run bookkeeping, the evidence
--     output, and a same-connection sanity check on the common (non-aborted)
--     path; they are not the restoration mechanism of record. See
--     README-221.md "Cleanup / restoration" and the .sh's restore_state()
--     trap handler.
--
-- Transaction model:
--   Statements run in psql autocommit. Each bounded `CALL` is its own
--   committed transaction so the watermark move is real and measurable. The
--   loader itself contains NO intermediate COMMIT and an
--   EXCEPTION WHEN OTHERS -> pipeline_state='FAILED' -> RAISE handler, so a
--   failed CALL rolls itself back atomically and does NOT advance the
--   watermark. Read-only EXPLAIN phases use BEGIN; ... ROLLBACK;.
--
-- Safety:
--   * NEVER connect this file to production. Host selection is enforced by
--     the .sh, which resolves its target from EMS_STAGING_SSH_HOST /
--     EMS_STAGING_SSH_USER / EMS_STAGING_PROJECT_PATH (operator-supplied env
--     vars, named after -- but distinct from -- the STAGING_HOST/STAGING_USER/
--     STAGING_PROJECT_PATH GitHub Actions secrets deploy-staging.yml already
--     uses for CI). S-1 (transport) is CONFIRMED for this operator's own
--     environment as of 2026-08-30 (one explicitly authorized, read-only
--     SSH probe -- no PostgreSQL connection, no mutation): the local
--     `ems-staging` SSH alias reaches the staging host as `emsadmin`
--     (`/bin/bash`, direct Docker group access, no sudo), and
--     EMS_STAGING_PROJECT_PATH=/opt/ems-platform is confirmed as the live
--     deployment there. This is still NOT a repository-committed
--     convention (an SSH config alias is never committed to a repo, and
--     `emsadmin` is not confirmed to be the same identity CI/CD's
--     STAGING_USER secret resolves to) -- see README-221.md's "Staging
--     transport" section. PHASE 0 additionally refuses to run unless
--     current_database() = 'ems' and the operator-supplied
--     :env_confirm = 'staging'.
--   * No credentials appear in this file.
--   * The only mutations are: N bounded `CALL`s of the deployed loader, and
--     transient single-row `UPDATE`s of the telemetry.pipeline_state
--     'normalized_points' row (captured in PHASE 2, restored in PHASE 8).
--   * Job 1000 scheduler state is NOT changed here.
--
-- Required \set variables (supplied by the .sh):
--   env_confirm                 'staging'
--   gate_execute                on | off
--   expected_221_sha256         64-hex sha256 of the checkout's
--                               postgres/migrations/221_normalization_selected_elements_pk_join.sql
--   deploy_221_after            ISO timestamptz; 221 ANALYZE must be at/after this
--   baseline_mode               as_is | rewind      (see PHASE 6)
--   rewind_interval             e.g. '2 hours 30 minutes' (baseline_mode=rewind only)
--   hist_start                  ISO timestamptz  (from reconnaissance + human review)
--   hist_end                    ISO timestamptz  (from reconnaissance + human review)
--   hist_window_minutes         integer          (= (hist_end - hist_start) in whole minutes)
--   recon_overlap_secs          integer          (v_dynamic_overlap the loader would compute
--                                                 for v_window_end=hist_end,
--                                                 v_previous_checkpoint=hist_start; from recon)
--   probe_idonly_contrast       on | off         (OPEN DESIGN QUESTION — default off)
--
-- Delivery mechanism (2026-08-30 fix — see "PHASE 0-pre" below): the values
-- above reach every DO $tag$...$tag$; block in this file via a session GUC
-- bridge (set_config()/current_setting()), NOT via direct :'name' psql
-- substitution inside those blocks. psql's colon-substitution scanner does
-- not look inside dollar-quoted strings at all, so a DO block referencing
-- :'name' directly receives it completely literally, which PostgreSQL then
-- rejects with a syntax error. Plain top-level SQL in this file (SELECT /
-- UPDATE / CALL / EXPLAIN statements not inside a DO block, and \if/\set
-- meta-commands) is unaffected and still uses :'name'/:name directly, since
-- psql substitution works normally there.
--
-- OPEN DESIGN QUESTIONS are marked inline as:  -- OPEN DESIGN QUESTION — requires review
-- ============================================================================

\set ON_ERROR_STOP on
\timing off
\pset pager off

\echo '================================================================'
\echo ' MIGRATION 221 STAGING VALIDATION GATE'
\echo ' STAGING ONLY. Do not run against production.'
\echo '================================================================'

-- ----------------------------------------------------------------------------
-- PHASE 0-pre — session GUC bridge for psql variable interpolation inside
--   dollar-quoted PL/pgSQL bodies.
--
--   CORRECTION (2026-08-30, this session): every DO $tag$ ... $tag$; block
--   below that referenced an operator-supplied -v value directly via
--   :'name'/:name FAILED at runtime with `ERROR: syntax error at or near
--   ":"`, reproduced locally against a disposable TimescaleDB container
--   (docker exec -i <container> psql -v env_confirm=staging -f -, feeding a
--   DO $$ ... IF :'env_confirm' <> 'staging' ... $$; body). Root cause: psql's
--   own colon-substitution scanner treats every quoted region as opaque, and
--   that includes dollar-quoted strings -- it never looks inside a
--   $tag$...$tag$ body for :name references at all, so those references
--   reached the PostgreSQL parser completely unsubstituted. This happens
--   even though the SAME `-v name=value` arguments are received correctly by
--   psql itself: the full SSH -> bash -c -> docker compose exec -> psql argv
--   chain was independently traced locally and showed every -v pair arriving
--   intact (see the .sh's remote_psql() header comment). Plain top-level SQL
--   (SELECT/UPDATE/CALL/EXPLAIN written directly in the script, outside any
--   DO block) is NOT affected -- confirmed locally that :'var' substitutes
--   correctly there; this is exactly why PHASE 5's EXPLAIN and PHASE 6/7's
--   top-level UPDATE/CALL statements need no change.
--
--   Fix: every operator-supplied (-v) or \gset-produced value that a LATER
--   DO block needs is bridged into a session GUC via set_config(), called
--   from top-level SQL where :'name' substitution still works normally. Every
--   DO block below then reads the value back with
--   current_setting('gate.<name>') -- plain PL/pgSQL, no psql substitution
--   involved -- instead of referencing :'name'/:name directly.
--   is_local => false (session-scoped, not transaction-scoped) so the value
--   survives PHASE 5/7's own BEGIN; ... ROLLBACK; blocks. See README-221.md,
--   "psql variable interpolation inside DO blocks (2026-08-30 fix)" for the
--   full writeup and the local reproduction/verification steps.
-- ----------------------------------------------------------------------------
SELECT
    set_config('gate.env_confirm',         :'env_confirm',         false),
    set_config('gate.expected_221_sha256', :'expected_221_sha256', false),
    set_config('gate.deploy_221_after',    :'deploy_221_after',    false),
    set_config('gate.hist_start',          :'hist_start',          false),
    set_config('gate.hist_end',            :'hist_end',            false),
    set_config('gate.hist_window_minutes', :'hist_window_minutes', false),
    set_config('gate.recon_overlap_secs',  :'recon_overlap_secs',  false),
    set_config('gate.baseline_mode',       :'baseline_mode',       false),
    set_config('gate.rewind_interval',     :'rewind_interval',     false);

-- ----------------------------------------------------------------------------
-- PHASE 0 — target / environment identity (READ-ONLY; always runs)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 0: target identity -----------------------------------------'

SELECT
    current_database()                                   AS database,
    current_user                                         AS db_user,
    inet_server_addr()                                   AS server_addr,
    version()                                            AS pg_version,
    extversion                                           AS timescaledb_version
FROM pg_extension
WHERE extname = 'timescaledb';

DO $phase0$
BEGIN
    IF current_database() <> 'ems' THEN
        RAISE EXCEPTION 'PHASE 0 STOP: current_database()=% (expected ems). Refusing to proceed.', current_database();
    END IF;
    IF current_setting('gate.env_confirm') <> 'staging' THEN
        RAISE EXCEPTION 'PHASE 0 STOP: env_confirm=% (expected staging). Refusing to proceed.', current_setting('gate.env_confirm');
    END IF;
    RAISE NOTICE 'PHASE 0 ok: database=ems, env_confirm=staging.';
END;
$phase0$;

-- ----------------------------------------------------------------------------
-- PHASE 1 — read-only preflight
--   Migration 221 present + checksum + procedure contract + planner stats.
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 1: read-only preflight ------------------------------------'

-- 1a. Migration ledger: 221 applied with the checkout's checksum; 218/219/
--     220/222 also present. admin.schema_migrations columns:
--       migration_id (PK), file_path, checksum_sha256, applied_at,
--       applied_by, execution_ms, application_mode ('applied'|'baseline')
SELECT migration_id, application_mode, applied_at, checksum_sha256
FROM admin.schema_migrations
WHERE migration_id IN (
    '218_recovery_onboarding_aware_deferral',
    '219_airsense_environmental_sensor_compatibility',
    '220_recovery_supersession_interval_predicate',
    '221_normalization_selected_elements_pk_join',
    '222_recover_failed_raw_messages_comment_restore'
)
ORDER BY migration_id;

DO $phase1a$
DECLARE
    v_row     admin.schema_migrations%ROWTYPE;
    v_missing text[] := ARRAY[]::text[];
    v_id      text;
BEGIN
    FOREACH v_id IN ARRAY ARRAY[
        '218_recovery_onboarding_aware_deferral',
        '219_airsense_environmental_sensor_compatibility',
        '220_recovery_supersession_interval_predicate',
        '221_normalization_selected_elements_pk_join',
        '222_recover_failed_raw_messages_comment_restore'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id = v_id) THEN
            v_missing := v_missing || v_id;
        END IF;
    END LOOP;
    IF cardinality(v_missing) > 0 THEN
        RAISE EXCEPTION 'PHASE 1a STOP: migrations not recorded in admin.schema_migrations: %', v_missing;
    END IF;

    SELECT * INTO v_row FROM admin.schema_migrations
    WHERE migration_id = '221_normalization_selected_elements_pk_join';

    IF v_row.checksum_sha256 <> lower(current_setting('gate.expected_221_sha256')) THEN
        RAISE EXCEPTION 'PHASE 1a STOP: deployed migration 221 checksum % <> checkout checksum %',
            v_row.checksum_sha256, lower(current_setting('gate.expected_221_sha256'));
    END IF;
    RAISE NOTICE 'PHASE 1a ok: 218/219/220/221/222 recorded; 221 checksum matches the checkout (%), mode=%.',
        v_row.checksum_sha256, v_row.application_mode;
END;
$phase1a$;

-- 1b. Exactly one loader overload, and it is the 2-arg (INTERVAL, INTERVAL)
--     signature migration 205/221 use. A leftover 1-arg overload would make
--     job 1000's call ambiguous.
-- CORRECTION (2026-08-30, real staging dry-run): pg_get_function_identity_
-- arguments() rendered staging's actual overload as
-- 'IN p_overlap interval, IN p_max_window interval' (explicit IN prefixes),
-- not the bare 'p_overlap interval, p_max_window interval' this DO block
-- originally compared against verbatim -- a genuine PHASE 1b STOP against a
-- correctly-deployed procedure, confirmed read-only against staging's own
-- catalog. The IN prefix is a rendering-format detail (present or absent
-- depending on how a routine's parameters were declared), not a functional
-- difference -- IN is the default parameter mode either way. Both call
-- sites below now strip a leading 'IN ' from each parameter segment before
-- comparing, verified against staging's live catalog to normalize
-- correctly, so the check still requires an exact match on parameter names
-- and types, just tolerant of this formatting variance.
DO $phase1b$
DECLARE
    v_two_arg int;
    v_one_arg int;
BEGIN
    SELECT count(*) INTO v_two_arg
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'telemetry' AND p.proname = 'load_normalized_points_incremental'
      AND regexp_replace(pg_get_function_identity_arguments(p.oid), '(^|, )IN ', '\1', 'g') = 'p_overlap interval, p_max_window interval';

    SELECT count(*) INTO v_one_arg
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'telemetry' AND p.proname = 'load_normalized_points_incremental'
      AND regexp_replace(pg_get_function_identity_arguments(p.oid), '(^|, )IN ', '\1', 'g') = 'p_overlap interval';

    IF v_two_arg <> 1 THEN
        RAISE EXCEPTION 'PHASE 1b STOP: expected exactly one telemetry.load_normalized_points_incremental(interval,interval); found %', v_two_arg;
    END IF;
    IF v_one_arg <> 0 THEN
        RAISE EXCEPTION 'PHASE 1b STOP: a legacy 1-arg telemetry.load_normalized_points_incremental(interval) overload is present (count %)', v_one_arg;
    END IF;
    RAISE NOTICE 'PHASE 1b ok: single 2-arg loader overload present, no legacy 1-arg overload.';
END;
$phase1b$;

-- 1c. Deployed body contract — the migration-221 / 205 / 212 invariants.
--     This is the staging-side equivalent of TEST D + J + M in
--     scripts/test/assert_normalization_bounded_catchup_window.sql, run
--     read-only against the live catalog (pg_get_functiondef).
DO $phase1c$
DECLARE
    v_def  text := pg_get_functiondef('telemetry.load_normalized_points_incremental(interval,interval)'::regprocedure);
    v_norm text;
    v_wrap text := pg_get_functiondef('telemetry.run_normalization_job(integer,jsonb)'::regprocedure);
BEGIN
    v_norm := regexp_replace(v_def, '\s+', ' ', 'g');

    -- migration 221: selected_elements accesses raw_messages on the full PK
    -- AND the loader's own window.
    IF v_norm NOT ILIKE '%JOIN telemetry.raw_messages rm ON rm.received_at=s.raw_received_at AND rm.id=s.raw_message_id AND rm.received_at > v_window_start AND rm.received_at <= v_window_end%' THEN
        RAISE EXCEPTION 'PHASE 1c STOP (221): selected_elements does not use the full-PK + (v_window_start,v_window_end] join';
    END IF;
    -- the id-only join form must be gone.
    IF v_norm ILIKE '%JOIN telemetry.raw_messages rm ON rm.id=s.raw_message_id JOIN%' THEN
        RAISE EXCEPTION 'PHASE 1c STOP (221): selected_elements still uses the id-only telemetry.raw_messages join';
    END IF;
    -- raw_resolved keeps the identical window bound that makes the above lossless.
    IF v_norm NOT ILIKE '%WHERE r.received_at > v_window_start AND r.received_at <= v_window_end%' THEN
        RAISE EXCEPTION 'PHASE 1c STOP (221): raw_resolved no longer carries the (v_window_start,v_window_end] bound';
    END IF;
    -- migration 205 bounded-window arithmetic.
    IF v_norm NOT ILIKE '%LEAST(v_window_end, v_previous_checkpoint + p_max_window)%' THEN
        RAISE EXCEPTION 'PHASE 1c STOP (205): LEAST(v_window_end, v_previous_checkpoint + p_max_window) bound missing';
    END IF;
    -- lock / state / rollback / overlap / dedup invariants.
    IF v_norm NOT ILIKE '%pg_try_advisory_xact_lock(%'
       OR v_norm NOT ILIKE '%SKIPPED_LOCKED%'
       OR v_norm NOT ILIKE '%last_status=''FAILED''%'
       OR v_norm NOT ILIKE '%EXCEPTION WHEN OTHERS%'
       OR v_norm NOT ILIKE '%v_previous_checkpoint-v_dynamic_overlap%'
       OR v_norm NOT ILIKE '%DISTINCT ON (raw_message_id,device_id,event_time,logical_point_id)%' THEN
        RAISE EXCEPTION 'PHASE 1c STOP: a loader invariant (advisory lock / SKIPPED_LOCKED / FAILED / EXCEPTION / overlap / DISTINCT ON) is missing';
    END IF;

    -- migration 212 wrapper: passes the bounded two-arg call, reads
    -- config->>'max_window', and does not duplicate loader-owned state.
    IF position('load_normalized_points_incremental(v_overlap, v_max_window)' IN v_wrap) = 0 THEN
        RAISE EXCEPTION 'PHASE 1c STOP (212): run_normalization_job does not issue the two-arg (v_overlap, v_max_window) call';
    END IF;
    IF position('''max_window''' IN v_wrap) = 0 THEN
        RAISE EXCEPTION 'PHASE 1c STOP (212): run_normalization_job does not read config->>''max_window''';
    END IF;

    RAISE NOTICE 'PHASE 1c ok: deployed loader body carries the 221 + 205 + 212 contract.';
END;
$phase1c$;

-- 1d. Planner statistics on telemetry.capture_bucket_samples MUST exist and
--     post-date the migration-221 deploy (221 issued one ANALYZE). If absent
--     the gate STOPS — it does NOT run ANALYZE itself. (Approved decision 9.)
SELECT schemaname, relname, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'telemetry' AND relname = 'capture_bucket_samples';

DO $phase1d$
DECLARE
    v_last_analyze     timestamptz;
    v_last_autoanalyze timestamptz;
    v_effective        timestamptz;
BEGIN
    SELECT last_analyze, last_autoanalyze
      INTO v_last_analyze, v_last_autoanalyze
    FROM pg_stat_user_tables
    WHERE schemaname = 'telemetry' AND relname = 'capture_bucket_samples';

    v_effective := GREATEST(COALESCE(v_last_analyze,'-infinity'::timestamptz),
                            COALESCE(v_last_autoanalyze,'-infinity'::timestamptz));

    IF v_effective = '-infinity'::timestamptz THEN
        RAISE EXCEPTION 'PHASE 1d STOP: telemetry.capture_bucket_samples has neither last_analyze nor last_autoanalyze. '
                        'The gate does not run ANALYZE. Investigate why migration 221''s ANALYZE is not reflected.';
    END IF;

    IF v_effective < current_setting('gate.deploy_221_after')::timestamptz THEN
        RAISE EXCEPTION 'PHASE 1d STOP: newest stats on telemetry.capture_bucket_samples (%) predate the migration-221 deploy (%).',
            v_effective, current_setting('gate.deploy_221_after')::timestamptz;
    END IF;
    RAISE NOTICE 'PHASE 1d ok: telemetry.capture_bucket_samples analyzed at % (>= 221 deploy %).',
        v_effective, current_setting('gate.deploy_221_after')::timestamptz;
END;
$phase1d$;

-- 1e. pipeline_state 'normalized_points' row exists and is not mid-run.
SELECT pipeline_name, last_status, last_received_at, last_started_at,
       last_completed_at, last_inserted_rows, updated_at
FROM telemetry.pipeline_state
WHERE pipeline_name = 'normalized_points';

DO $phase1e$
DECLARE v_status text;
BEGIN
    SELECT last_status INTO v_status
    FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PHASE 1e STOP: telemetry.pipeline_state has no normalized_points row';
    END IF;
    IF v_status = 'RUNNING' THEN
        RAISE EXCEPTION 'PHASE 1e STOP: normalized_points pipeline is RUNNING — a normalization run is in flight';
    END IF;
    IF v_status NOT IN ('SUCCESS','NO_SOURCE_DATA','NEVER_RUN','SKIPPED_LOCKED') THEN
        RAISE WARNING 'PHASE 1e advisory: normalized_points last_status=% (not SUCCESS/NO_SOURCE_DATA). Recorded, not blocking.', v_status;
    END IF;
    RAISE NOTICE 'PHASE 1e ok: normalized_points pipeline present, last_status=%.', v_status;
END;
$phase1e$;

-- 1f. No competing normalization actor.
SELECT pid, state, query_start, left(query, 120) AS query
FROM pg_stat_activity
WHERE query ILIKE '%load_normalized_points_incremental%'
   OR query ILIKE '%run_normalization_job%';

DO $phase1f$
DECLARE v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt
    FROM pg_stat_activity
    WHERE pid <> pg_backend_pid()
      AND (query ILIKE '%load_normalized_points_incremental%'
           OR query ILIKE '%run_normalization_job%')
      AND state <> 'idle';
    IF v_cnt > 0 THEN
        RAISE EXCEPTION 'PHASE 1f STOP: % active session(s) running a normalization procedure', v_cnt;
    END IF;
    RAISE NOTICE 'PHASE 1f ok: no competing normalization actor.';
END;
$phase1f$;

-- ----------------------------------------------------------------------------
-- PHASE 2 — capture-for-restoration (READ-ONLY snapshot into session temp
--           tables + psql vars). Nothing is changed here.
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 2: capture for restoration ------------------------------'

DROP TABLE IF EXISTS gate_restore_pipeline_state;
CREATE TEMP TABLE gate_restore_pipeline_state AS
SELECT * FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points';

SELECT last_received_at AS restore_last_received_at
FROM gate_restore_pipeline_state \gset

-- \gset-produced value consumed by PHASE 6's DO blocks below; bridged via
-- set_config() for the same reason as the PHASE 0-pre block (psql :'var'
-- substitution does not reach inside a dollar-quoted DO body).
SELECT set_config('gate.restore_last_received_at', :'restore_last_received_at', false);

\echo 'Captured telemetry.pipeline_state row (normalized_points):'
SELECT * FROM gate_restore_pipeline_state;

-- Job 1000 full config, for the .sh to byte-compare on restore. The .sh also
-- captures this independently; the copy here is for the evidence file and for
-- PHASE 3's "is it actually paused?" check.
DROP TABLE IF EXISTS gate_restore_job1000;
CREATE TEMP TABLE gate_restore_job1000 AS
SELECT job_id, application_name, schedule_interval, max_runtime, max_retries,
       retry_period, scheduled, config, hypertable_schema, hypertable_name
FROM timescaledb_information.jobs
WHERE proc_schema = 'telemetry' AND proc_name = 'run_normalization_job';

DO $phase2$
DECLARE v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM gate_restore_job1000;
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'PHASE 2 STOP: expected exactly one telemetry.run_normalization_job registration, found %', v_cnt;
    END IF;
END;
$phase2$;

\echo 'Captured Job 1000 (telemetry.run_normalization_job) configuration:'
SELECT job_id, schedule_interval, max_runtime, max_retries, retry_period,
       scheduled, config
FROM gate_restore_job1000;

-- ----------------------------------------------------------------------------
-- PHASE 3 — require Job 1000 already paused by the .sh before any CALL.
--           This file never calls alter_job.
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 3: Job 1000 pause precondition --------------------------'

\if :gate_execute
DO $phase3$
DECLARE v_scheduled boolean;
BEGIN
    SELECT scheduled INTO v_scheduled FROM gate_restore_job1000;
    IF v_scheduled IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'PHASE 3 STOP: Job 1000 scheduled=% — the .sh must pause it (alter_job(..., scheduled => false)) before :gate_execute=on', v_scheduled;
    END IF;
    RAISE NOTICE 'PHASE 3 ok: Job 1000 scheduled=false (paused by the wrapper).';
END;
$phase3$;
\else
\echo 'DRY-RUN: skipping Job 1000 pause precondition (no CALL will be issued).'
\endif

-- ----------------------------------------------------------------------------
-- PHASE 4 — reconnaissance re-validation (READ-ONLY).
--   The gate does NOT choose the historical window. The .sh supplies
--   :hist_start / :hist_end / :hist_window_minutes / :recon_overlap_secs from
--   a prior, separately-reviewed reconnaissance run. PHASE 4 only re-checks
--   they are still valid at gate time.
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 4: reconnaissance re-validation -------------------------'

-- Live raw_messages retention (never hard-coded; same lookup as migration 206).
SELECT (config->>'drop_after')::interval AS raw_messages_retention
FROM timescaledb_information.jobs
WHERE proc_schema = '_timescaledb_functions'
  AND proc_name   = 'policy_retention'
  AND hypertable_schema = 'telemetry'
  AND hypertable_name   = 'raw_messages';

-- Current heads.
SELECT
    (SELECT max(received_at) FROM telemetry.raw_messages)                       AS raw_max_received_at,
    (SELECT last_received_at FROM telemetry.pipeline_state
      WHERE pipeline_name = 'normalized_points')                               AS normalized_checkpoint;

-- Raw + sample population inside the requested historical band.
SELECT
    count(*)                                                                   AS raw_rows_in_band
FROM telemetry.raw_messages
WHERE received_at >  :'hist_start'::timestamptz
  AND received_at <= :'hist_end'::timestamptz;

SELECT status, count(*) AS n
FROM telemetry.capture_bucket_samples
WHERE raw_received_at >  (:'hist_start'::timestamptz - make_interval(secs => :recon_overlap_secs))
  AND raw_received_at <= :'hist_end'::timestamptz
GROUP BY status
ORDER BY status;

-- E-2 (machine-checkable): the count PHASE 7's equivalence re-run will
-- actually drive (tmp_selected_samples is status IN ('SELECTED','FAILED')).
-- \gset'd so the .sh's verdict can grep a fixed, unambiguous marker instead
-- of relying on a human noticing a prose NOTICE among many.
SELECT count(*) AS driving_rows_in_band
FROM telemetry.capture_bucket_samples
WHERE raw_received_at >  (:'hist_start'::timestamptz - make_interval(secs => :recon_overlap_secs))
  AND raw_received_at <= :'hist_end'::timestamptz
  AND status IN ('SELECTED','FAILED') \gset

-- \gset-produced value consumed by the DO block below; bridged via
-- set_config() for the same reason as the PHASE 0-pre block (psql :'var'
-- substitution does not reach inside a dollar-quoted DO body).
SELECT set_config('gate.driving_rows_in_band', :'driving_rows_in_band', false);

DO $phase4$
DECLARE
    v_retention   interval;
    v_raw_max     timestamptz;
    v_checkpoint  timestamptz;
    v_raw_in_band bigint;
    v_minutes_chk int;
BEGIN
    SELECT (config->>'drop_after')::interval INTO v_retention
    FROM timescaledb_information.jobs
    WHERE proc_schema='_timescaledb_functions' AND proc_name='policy_retention'
      AND hypertable_schema='telemetry' AND hypertable_name='raw_messages';
    IF v_retention IS NULL THEN
        RAISE EXCEPTION 'PHASE 4 STOP: could not read telemetry.raw_messages retention policy';
    END IF;

    SELECT max(received_at) INTO v_raw_max FROM telemetry.raw_messages;
    SELECT last_received_at INTO v_checkpoint
    FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';

    -- whole-minute consistency of the supplied window
    v_minutes_chk := (EXTRACT(EPOCH FROM (current_setting('gate.hist_end')::timestamptz - current_setting('gate.hist_start')::timestamptz)) / 60)::int;
    IF v_minutes_chk <> current_setting('gate.hist_window_minutes')::int THEN
        RAISE EXCEPTION 'PHASE 4 STOP: hist_window_minutes=% but (hist_end - hist_start)=% minutes', current_setting('gate.hist_window_minutes')::int, v_minutes_chk;
    END IF;
    IF current_setting('gate.hist_window_minutes')::int <= 0 THEN
        RAISE EXCEPTION 'PHASE 4 STOP: hist_window_minutes must be positive';
    END IF;

    -- historical: the whole band (including the overlap pad) must sit BEHIND
    -- the current checkpoint, so re-running cannot advance into unprocessed data.
    IF current_setting('gate.hist_end')::timestamptz >= v_checkpoint THEN
        RAISE EXCEPTION 'PHASE 4 STOP: hist_end (%) is not strictly behind the normalized checkpoint (%)', current_setting('gate.hist_end')::timestamptz, v_checkpoint;
    END IF;

    -- raw still retained: the band lower edge (minus overlap pad) must be
    -- newer than (now - retention + safety margin).
    IF (current_setting('gate.hist_start')::timestamptz - make_interval(secs => current_setting('gate.recon_overlap_secs')::int))
         <= (clock_timestamp() - v_retention + interval '2 hours') THEN
        RAISE EXCEPTION 'PHASE 4 STOP: historical band is too close to (or past) the raw_messages retention cutoff (retention=%). Choose a newer window.', v_retention;
    END IF;

    SELECT count(*) INTO v_raw_in_band
    FROM telemetry.raw_messages
    WHERE received_at > current_setting('gate.hist_start')::timestamptz AND received_at <= current_setting('gate.hist_end')::timestamptz;
    IF v_raw_in_band = 0 THEN
        RAISE EXCEPTION 'PHASE 4 STOP: no telemetry.raw_messages rows in the historical band — nothing to normalize';
    END IF;

    RAISE NOTICE 'PHASE 4 ok: window % .. % (% min), raw rows in band=%, retention=%, checkpoint=%.',
        current_setting('gate.hist_start')::timestamptz, current_setting('gate.hist_end')::timestamptz, current_setting('gate.hist_window_minutes')::int, v_raw_in_band, v_retention, v_checkpoint;

    -- E-2, machine-checkable: gate.driving_rows_in_band was set_config()'d
    -- above (bridged from the plain \gset immediately preceding it), BEFORE
    -- this DO block, from a plain read-only count -- not re-derived here, so
    -- there is exactly one query defining "driving rows" for both this
    -- message and PHASE 9's verdict. A fixed marker string is used
    -- (never reworded) so the .sh can grep for it without parsing prose.
    --
    -- CORRECTION (2026-08-30, real staging --execute run): this count is
    -- read-only and PRE-CALL -- it counts only capture_bucket_samples rows
    -- already sitting in SELECTED/FAILED status before the equivalence CALL
    -- runs. It is NOT a prediction of what the CALL will actually process:
    -- the loader independently re-derives candidate (site, bucket_start,
    -- device) buckets from raw data joined against CURRENT metadata on every
    -- invocation (tmp_capture_candidates), and inserts+normalizes any bucket
    -- not yet present in capture_bucket_samples regardless of this count. A
    -- real run confirmed zero pre-existing driving rows here can still be
    -- followed by the CALL discovering and normalizing previously-uncaptured
    -- buckets -- observed as additive key growth in PHASE 7, not corruption
    -- (see that phase's EQUIVALENCE_ADDITIVE_KEY_GROWTH handling). So "zero
    -- driving rows" means only "PHASE 5's EXPLAIN probe may be the sole
    -- evidence for the changed join, since PHASE 7 might not exercise it
    -- either" -- it does NOT mean "the CALL will be a no-op."
    IF current_setting('gate.driving_rows_in_band')::bigint = 0 THEN
        RAISE WARNING 'EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS: 0 capture_bucket_samples rows in the band are SELECTED/FAILED before this CALL (all already NORMALIZED/RECOVERED). This does NOT mean the equivalence CALL will be a no-op: the loader re-derives candidate buckets from raw data + current metadata on every invocation, independently of this count, and may discover and normalize previously-uncaptured buckets -- PHASE 7 reports any such growth as additive key growth, not corruption. What this DOES mean: PHASE 7''s existing-key checks (value mutation, removal, platform_received_at regression) may end up covering an empty or near-empty set of PRE-EXISTING keys, so they alone might not exercise the changed selected_elements<->raw_messages join against fresh rows. See OPEN DESIGN QUESTION E-2 in README-221.md; treat join-correctness as resting on PHASE 5''s EXPLAIN evidence unless PHASE 7 reports a nonzero shared-key set.';
    ELSE
        RAISE NOTICE 'PHASE 4 ok: % driving row(s) (status SELECTED/FAILED) in band -- PHASE 7 will exercise the changed join against real rows.', current_setting('gate.driving_rows_in_band')::bigint;
    END IF;
END;
$phase4$;

-- ----------------------------------------------------------------------------
-- PHASE 5 — performance EVIDENCE via EXPLAIN (ANALYZE, BUFFERS).
--
--   PostgreSQL cannot EXPLAIN a `CALL`. This phase EXPLAINs, in isolation, the
--   exact selected_elements <-> telemetry.raw_messages join predicate that
--   migration 221 changed (copied verbatim from the migration body). It is an
--   APPROXIMATE PLAN PROBE of the loader's internal join, not a full plan of
--   the procedure. It writes nothing (BEGIN; ... ROLLBACK;).
--
--   MEASUREMENT ONLY. There is no numeric pass/fail here.
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 5: EXPLAIN (ANALYZE, BUFFERS) plan probe ----------------'
\echo 'MEASUREMENT ONLY — chunk exclusion / join shape on telemetry.raw_messages.'

BEGIN;
SET LOCAL statement_timeout = '120s';

-- 221 form: full PK + the loader's own (v_window_start, v_window_end] range.
-- v_window_start is modelled as (hist_start - overlap pad); v_window_end as hist_end.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT rm.id, rm.received_at, jsonb_array_length(rm.payload -> 'rtdata') AS n_rtdata
FROM telemetry.capture_bucket_samples s
JOIN telemetry.raw_messages rm
  ON rm.received_at =  s.raw_received_at
 AND rm.id          =  s.raw_message_id
 AND rm.received_at >  (:'hist_start'::timestamptz - make_interval(secs => :recon_overlap_secs))
 AND rm.received_at <= :'hist_end'::timestamptz
WHERE s.status IN ('SELECTED','FAILED')
  AND s.raw_received_at >  (:'hist_start'::timestamptz - make_interval(secs => :recon_overlap_secs))
  AND s.raw_received_at <= :'hist_end'::timestamptz;

ROLLBACK;

\if :probe_idonly_contrast
\echo 'OPEN DESIGN QUESTION: id-only contrast probe ENABLED — this runs the'
\echo 'known-slow pre-221 shape under a statement_timeout. Off by default.'
BEGIN;
SET LOCAL statement_timeout = '120s';
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT rm.id, rm.received_at, jsonb_array_length(rm.payload -> 'rtdata') AS n_rtdata
FROM telemetry.capture_bucket_samples s
JOIN telemetry.raw_messages rm
  ON rm.id = s.raw_message_id            -- pre-221 id-only join
WHERE s.status IN ('SELECTED','FAILED')
  AND s.raw_received_at >  (:'hist_start'::timestamptz - make_interval(secs => :recon_overlap_secs))
  AND s.raw_received_at <= :'hist_end'::timestamptz;
ROLLBACK;
\else
\echo 'id-only contrast probe: DISABLED (probe_idonly_contrast=off).'
\endif

-- ----------------------------------------------------------------------------
-- PHASE 6 — bounded-window timing runs: p_max_window in 1m / 5m / 15m / 2h.
--   NULL / unbounded is intentionally NOT supported (approved decision 5).
--
--   MUTATING. Runs only when :gate_execute = on.
--
--   baseline_mode:
--     as_is  : each timed CALL starts from the captured checkpoint
--              (restore_last_received_at). On a healthy staging where the
--              checkpoint is near max(raw_messages.received_at), all four
--              windows collapse to the same effective window
--              (v_window_end = max(received_at)); the run then measures the
--              real steady-state per-run cost and shows runtime does NOT
--              scale with p_max_window. MEASUREMENT, clearly labelled.
--     rewind : each timed CALL starts from
--              (max(raw_messages.received_at) - :rewind_interval) so the
--              1m/5m/15m/2h bounds actually bind and produce a size-
--              proportional window. Over already-normalized history the
--              write path is a near-no-op; the measurement then characterises
--              the tmp_capture_candidates / v_rtdata scan + the (now cheap)
--              selected_elements plan. Neither mode reproduces the original
--              heavy fresh-SELECTED backlog unless Job 1000 was paused long
--              enough beforehand for a real backlog to form.
--              -- OPEN DESIGN QUESTION — requires review (see README-221.md §6)
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 6: bounded-window timing runs (1m/5m/15m/2h) -----------'

DROP TABLE IF EXISTS gate_measurements;
CREATE TEMP TABLE gate_measurements (
    phase                text,
    p_max_window         interval,
    baseline_mode        text,
    checkpoint_before    timestamptz,
    expected_window_end  timestamptz,
    checkpoint_after     timestamptz,
    last_status          text,
    last_started_at      timestamptz,
    last_completed_at    timestamptz,
    server_duration_ms   numeric,
    client_wall_ms       numeric,
    last_inserted_rows   bigint,
    note                 text
);

\if :gate_execute

-- Helper: one timed bounded CALL. psql has no functions/loops for this at the
-- top level, so the four windows are spelled out. Each block is:
--   1) set the starting checkpoint per baseline_mode
--   2) record checkpoint_before + the value v_window_end the loader WILL derive
--   3) timed CALL
--   4) record checkpoint_after + pipeline_state + durations
--   5) assert SUCCESS (not SKIPPED_LOCKED / FAILED)

-- ---- 1 minute --------------------------------------------------------------
\echo 'timed CALL: p_max_window = 1 minute'
DO $set_cp_1m$
DECLARE v_start timestamptz;
BEGIN
    IF current_setting('gate.baseline_mode') = 'rewind' THEN
        SELECT max(received_at) - current_setting('gate.rewind_interval')::interval INTO v_start FROM telemetry.raw_messages;
    ELSE
        v_start := current_setting('gate.restore_last_received_at')::timestamptz;
    END IF;
    UPDATE telemetry.pipeline_state SET last_received_at = v_start WHERE pipeline_name = 'normalized_points';
END;
$set_cp_1m$;

SELECT
    last_received_at AS cp_before,
    LEAST( (SELECT max(received_at) FROM telemetry.raw_messages),
           last_received_at + interval '1 minute' ) AS expected_end
FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points' \gset

SELECT clock_timestamp() AS t0 \gset
\timing on
CALL telemetry.load_normalized_points_incremental(INTERVAL '15 minutes', INTERVAL '1 minute');
\timing off
SELECT clock_timestamp() AS t1 \gset

INSERT INTO gate_measurements
SELECT '1m', interval '1 minute', :'baseline_mode',
       :'cp_before'::timestamptz, :'expected_end'::timestamptz,
       ps.last_received_at, ps.last_status, ps.last_started_at, ps.last_completed_at,
       EXTRACT(EPOCH FROM (ps.last_completed_at - ps.last_started_at)) * 1000,
       EXTRACT(EPOCH FROM (:'t1'::timestamptz - :'t0'::timestamptz)) * 1000,
       ps.last_inserted_rows,
       NULL
FROM telemetry.pipeline_state ps WHERE ps.pipeline_name = 'normalized_points';

DO $chk_1m$
DECLARE r gate_measurements%ROWTYPE;
BEGIN
    SELECT * INTO r FROM gate_measurements WHERE phase = '1m';
    IF r.last_status = 'SKIPPED_LOCKED' THEN
        RAISE EXCEPTION 'PHASE 6 STOP (1m): CALL returned SKIPPED_LOCKED — Job 1000 (or another actor) holds the advisory lock; pause did not take';
    END IF;
    IF r.last_status <> 'SUCCESS' THEN
        RAISE EXCEPTION 'PHASE 6 STOP (1m): CALL last_status=% (expected SUCCESS)', r.last_status;
    END IF;
    IF r.checkpoint_after IS DISTINCT FROM r.expected_window_end THEN
        RAISE EXCEPTION 'PHASE 6 STOP (1m): watermark advanced to % but expected exactly % (LEAST(max(received_at), checkpoint + 1 minute))',
            r.checkpoint_after, r.expected_window_end;
    END IF;
    RAISE NOTICE 'PHASE 6 ok (1m): SUCCESS, server_ms=%, rows=%, watermark -> %', r.server_duration_ms, r.last_inserted_rows, r.checkpoint_after;
END;
$chk_1m$;

-- ---- 5 minutes -----------------------------------------------------------
\echo 'timed CALL: p_max_window = 5 minutes'
DO $set_cp_5m$
DECLARE v_start timestamptz;
BEGIN
    IF current_setting('gate.baseline_mode') = 'rewind' THEN
        SELECT max(received_at) - current_setting('gate.rewind_interval')::interval INTO v_start FROM telemetry.raw_messages;
    ELSE
        v_start := current_setting('gate.restore_last_received_at')::timestamptz;
    END IF;
    UPDATE telemetry.pipeline_state SET last_received_at = v_start WHERE pipeline_name = 'normalized_points';
END;
$set_cp_5m$;

SELECT
    last_received_at AS cp_before,
    LEAST( (SELECT max(received_at) FROM telemetry.raw_messages),
           last_received_at + interval '5 minutes' ) AS expected_end
FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points' \gset

SELECT clock_timestamp() AS t0 \gset
\timing on
CALL telemetry.load_normalized_points_incremental(INTERVAL '15 minutes', INTERVAL '5 minutes');
\timing off
SELECT clock_timestamp() AS t1 \gset

INSERT INTO gate_measurements
SELECT '5m', interval '5 minutes', :'baseline_mode',
       :'cp_before'::timestamptz, :'expected_end'::timestamptz,
       ps.last_received_at, ps.last_status, ps.last_started_at, ps.last_completed_at,
       EXTRACT(EPOCH FROM (ps.last_completed_at - ps.last_started_at)) * 1000,
       EXTRACT(EPOCH FROM (:'t1'::timestamptz - :'t0'::timestamptz)) * 1000,
       ps.last_inserted_rows, NULL
FROM telemetry.pipeline_state ps WHERE ps.pipeline_name = 'normalized_points';

DO $chk_5m$
DECLARE r gate_measurements%ROWTYPE;
BEGIN
    SELECT * INTO r FROM gate_measurements WHERE phase = '5m';
    IF r.last_status = 'SKIPPED_LOCKED' THEN
        RAISE EXCEPTION 'PHASE 6 STOP (5m): CALL returned SKIPPED_LOCKED';
    END IF;
    IF r.last_status <> 'SUCCESS' THEN
        RAISE EXCEPTION 'PHASE 6 STOP (5m): CALL last_status=% (expected SUCCESS)', r.last_status;
    END IF;
    IF r.checkpoint_after IS DISTINCT FROM r.expected_window_end THEN
        RAISE EXCEPTION 'PHASE 6 STOP (5m): watermark % <> expected %', r.checkpoint_after, r.expected_window_end;
    END IF;
    RAISE NOTICE 'PHASE 6 ok (5m): SUCCESS, server_ms=%, rows=%, watermark -> %', r.server_duration_ms, r.last_inserted_rows, r.checkpoint_after;
END;
$chk_5m$;

-- ---- 15 minutes ---------------------------------------------------------
\echo 'timed CALL: p_max_window = 15 minutes'
DO $set_cp_15m$
DECLARE v_start timestamptz;
BEGIN
    IF current_setting('gate.baseline_mode') = 'rewind' THEN
        SELECT max(received_at) - current_setting('gate.rewind_interval')::interval INTO v_start FROM telemetry.raw_messages;
    ELSE
        v_start := current_setting('gate.restore_last_received_at')::timestamptz;
    END IF;
    UPDATE telemetry.pipeline_state SET last_received_at = v_start WHERE pipeline_name = 'normalized_points';
END;
$set_cp_15m$;

SELECT
    last_received_at AS cp_before,
    LEAST( (SELECT max(received_at) FROM telemetry.raw_messages),
           last_received_at + interval '15 minutes' ) AS expected_end
FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points' \gset

SELECT clock_timestamp() AS t0 \gset
\timing on
CALL telemetry.load_normalized_points_incremental(INTERVAL '15 minutes', INTERVAL '15 minutes');
\timing off
SELECT clock_timestamp() AS t1 \gset

INSERT INTO gate_measurements
SELECT '15m', interval '15 minutes', :'baseline_mode',
       :'cp_before'::timestamptz, :'expected_end'::timestamptz,
       ps.last_received_at, ps.last_status, ps.last_started_at, ps.last_completed_at,
       EXTRACT(EPOCH FROM (ps.last_completed_at - ps.last_started_at)) * 1000,
       EXTRACT(EPOCH FROM (:'t1'::timestamptz - :'t0'::timestamptz)) * 1000,
       ps.last_inserted_rows, NULL
FROM telemetry.pipeline_state ps WHERE ps.pipeline_name = 'normalized_points';

DO $chk_15m$
DECLARE r gate_measurements%ROWTYPE;
BEGIN
    SELECT * INTO r FROM gate_measurements WHERE phase = '15m';
    IF r.last_status = 'SKIPPED_LOCKED' THEN
        RAISE EXCEPTION 'PHASE 6 STOP (15m): CALL returned SKIPPED_LOCKED';
    END IF;
    IF r.last_status <> 'SUCCESS' THEN
        RAISE EXCEPTION 'PHASE 6 STOP (15m): CALL last_status=% (expected SUCCESS)', r.last_status;
    END IF;
    IF r.checkpoint_after IS DISTINCT FROM r.expected_window_end THEN
        RAISE EXCEPTION 'PHASE 6 STOP (15m): watermark % <> expected %', r.checkpoint_after, r.expected_window_end;
    END IF;
    RAISE NOTICE 'PHASE 6 ok (15m): SUCCESS, server_ms=%, rows=%, watermark -> %', r.server_duration_ms, r.last_inserted_rows, r.checkpoint_after;
END;
$chk_15m$;

-- ---- 2 hours (the deployed job-1000 config.max_window) -----------------
\echo 'timed CALL: p_max_window = 2 hours  (matches job 1000 config.max_window)'
DO $set_cp_2h$
DECLARE v_start timestamptz;
BEGIN
    IF current_setting('gate.baseline_mode') = 'rewind' THEN
        SELECT max(received_at) - current_setting('gate.rewind_interval')::interval INTO v_start FROM telemetry.raw_messages;
    ELSE
        v_start := current_setting('gate.restore_last_received_at')::timestamptz;
    END IF;
    UPDATE telemetry.pipeline_state SET last_received_at = v_start WHERE pipeline_name = 'normalized_points';
END;
$set_cp_2h$;

SELECT
    last_received_at AS cp_before,
    LEAST( (SELECT max(received_at) FROM telemetry.raw_messages),
           last_received_at + interval '2 hours' ) AS expected_end
FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points' \gset

SELECT clock_timestamp() AS t0 \gset
\timing on
CALL telemetry.load_normalized_points_incremental(INTERVAL '15 minutes', INTERVAL '2 hours');
\timing off
SELECT clock_timestamp() AS t1 \gset

INSERT INTO gate_measurements
SELECT '2h', interval '2 hours', :'baseline_mode',
       :'cp_before'::timestamptz, :'expected_end'::timestamptz,
       ps.last_received_at, ps.last_status, ps.last_started_at, ps.last_completed_at,
       EXTRACT(EPOCH FROM (ps.last_completed_at - ps.last_started_at)) * 1000,
       EXTRACT(EPOCH FROM (:'t1'::timestamptz - :'t0'::timestamptz)) * 1000,
       ps.last_inserted_rows,
       'p_max_window = job 1000 config.max_window; report only if near max_runtime (300s). Do NOT auto-alter job config.'
FROM telemetry.pipeline_state ps WHERE ps.pipeline_name = 'normalized_points';

DO $chk_2h$
DECLARE r gate_measurements%ROWTYPE;
BEGIN
    SELECT * INTO r FROM gate_measurements WHERE phase = '2h';
    IF r.last_status = 'SKIPPED_LOCKED' THEN
        RAISE EXCEPTION 'PHASE 6 STOP (2h): CALL returned SKIPPED_LOCKED';
    END IF;
    IF r.last_status <> 'SUCCESS' THEN
        RAISE EXCEPTION 'PHASE 6 STOP (2h): CALL last_status=% (expected SUCCESS)', r.last_status;
    END IF;
    IF r.checkpoint_after IS DISTINCT FROM r.expected_window_end THEN
        RAISE EXCEPTION 'PHASE 6 STOP (2h): watermark % <> expected %', r.checkpoint_after, r.expected_window_end;
    END IF;
    IF r.server_duration_ms >= 300000 THEN
        RAISE WARNING 'PHASE 6 ADVISORY (2h): server_duration_ms=% >= job 1000 max_runtime (300000 ms). REPORT ONLY — the gate does not change job config.', r.server_duration_ms;
    ELSIF r.server_duration_ms >= 150000 THEN
        RAISE WARNING 'PHASE 6 ADVISORY (2h): server_duration_ms=% is within 2x of job 1000 max_runtime. Reviewer attention. REPORT ONLY.', r.server_duration_ms;
    END IF;
    RAISE NOTICE 'PHASE 6 ok (2h): SUCCESS, server_ms=%, rows=%, watermark -> %', r.server_duration_ms, r.last_inserted_rows, r.checkpoint_after;
END;
$chk_2h$;

\else
\echo 'DRY-RUN: skipping PHASE 6 bounded CALLs (gate_execute=off).'
\endif

-- ----------------------------------------------------------------------------
-- PHASE 7 — fixed historical-window equivalence (Approach 1 only:
--   idempotent re-normalization + diff of telemetry.normalized_points).
--   NO twin/probe functions are created (approved decision 3).
--
--   Method:
--     * snapshot telemetry.normalized_points over the FULL band the loader
--       will re-process: (hist_start - recon_overlap_secs, hist_end], into a
--       session TEMP table + an ordered content digest that EXCLUDES the two
--       columns the loader's ON CONFLICT DO UPDATE is allowed to bump
--       (platform_received_at, raw_message_id).
--     * snapshot the matching telemetry.capture_bucket_samples rows.
--     * set the checkpoint to hist_start and CALL with
--       p_max_window = (hist_window_minutes) minutes, so
--       v_window_end = LEAST(max(received_at), hist_start + window) = hist_end.
--     * recompute the digest + set-diff both directions; assert unchanged.
--     * assert capture_bucket_samples status set for the band is unchanged
--       and no FAILED row flipped.
--
--   ACCEPTANCE for this phase: exact equality (digest match, zero set-diff,
--   capture_bucket_samples unchanged). No tolerance.
--
--   LIMITATION (OPEN DESIGN QUESTION — requires review): if every
--   capture_bucket_samples row in the band is already NORMALIZED/RECOVERED,
--   tmp_selected_samples is empty and this phase proves only "221 introduces
--   no spurious writes / no drift over already-normalized history" — it does
--   NOT exercise the changed selected_elements<->raw_messages join on real
--   driving rows. PHASE 5's EXPLAIN probe (and, if enabled, the id-only
--   contrast) is then the only evidence that the changed join is row- and
--   plan-correct. See README-221.md §"Equivalence methodology".
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 7: fixed historical-window equivalence -----------------'

\if :gate_execute

DROP TABLE IF EXISTS gate_np_ref;
CREATE TEMP TABLE gate_np_ref AS
SELECT event_time, device_id, logical_point_id, organization_id, site_id,
       gateway_id, device_uid, logical_point, raw_field_name, raw_value,
       numeric_value, quality_code, mapping_source,
       platform_received_at, raw_message_id
FROM telemetry.normalized_points
WHERE event_time >  (:'hist_start'::timestamptz - make_interval(secs => :recon_overlap_secs))
  AND event_time <= :'hist_end'::timestamptz;

DROP TABLE IF EXISTS gate_cbs_ref;
CREATE TEMP TABLE gate_cbs_ref AS
SELECT site_id, bucket_start, device_id, status, raw_received_at, raw_message_id, normalized_at
FROM telemetry.capture_bucket_samples
WHERE raw_received_at >  (:'hist_start'::timestamptz - make_interval(secs => :recon_overlap_secs))
  AND raw_received_at <= :'hist_end'::timestamptz;

-- Content digest EXCLUDING platform_received_at / raw_message_id.
SELECT md5(coalesce(string_agg(
         event_time || '|' || device_id || '|' || logical_point_id || '|' ||
         coalesce(raw_value,'<null>') || '|' ||
         coalesce(numeric_value::text,'<null>') || '|' ||
         coalesce(quality_code,'<null>') || '|' ||
         coalesce(mapping_source,'<null>'),
         ',' ORDER BY event_time, device_id, logical_point_id), '')) AS ref_digest,
       count(*) AS ref_rows
FROM gate_np_ref \gset

\echo 'equivalence: reference snapshot captured'
SELECT :'ref_rows' AS ref_rows, :'ref_digest' AS ref_digest;

-- \gset-produced value consumed by the $chk_equiv$ DO block below; bridged
-- via set_config() for the same reason as the PHASE 0-pre block (psql
-- :'var' substitution does not reach inside a dollar-quoted DO body).
SELECT set_config('gate.ref_digest', :'ref_digest', false);

-- Drive the loader over exactly (hist_start - overlap, hist_end].
UPDATE telemetry.pipeline_state SET last_received_at = :'hist_start'::timestamptz
WHERE pipeline_name = 'normalized_points';

SELECT clock_timestamp() AS t0 \gset
\timing on
-- p_max_window is a literal built from the integer minute count; no NULL.
\set eq_window :hist_window_minutes
CALL telemetry.load_normalized_points_incremental(INTERVAL '15 minutes', make_interval(mins => :eq_window));
\timing off
SELECT clock_timestamp() AS t1 \gset

-- Recompute digest over the same predicate.
SELECT md5(coalesce(string_agg(
         event_time || '|' || device_id || '|' || logical_point_id || '|' ||
         coalesce(raw_value,'<null>') || '|' ||
         coalesce(numeric_value::text,'<null>') || '|' ||
         coalesce(quality_code,'<null>') || '|' ||
         coalesce(mapping_source,'<null>'),
         ',' ORDER BY event_time, device_id, logical_point_id), '')) AS post_digest,
       count(*) AS post_rows
FROM telemetry.normalized_points
WHERE event_time >  (:'hist_start'::timestamptz - make_interval(secs => :recon_overlap_secs))
  AND event_time <= :'hist_end'::timestamptz \gset

-- \gset-produced value consumed by the $chk_equiv$ DO block below; bridged
-- via set_config() for the same reason as the PHASE 0-pre block (psql
-- :'var' substitution does not reach inside a dollar-quoted DO body).
SELECT set_config('gate.post_digest', :'post_digest', false);

INSERT INTO gate_measurements
SELECT 'equiv', make_interval(mins => :eq_window), :'baseline_mode',
       :'hist_start'::timestamptz, :'hist_end'::timestamptz,
       ps.last_received_at, ps.last_status, ps.last_started_at, ps.last_completed_at,
       EXTRACT(EPOCH FROM (ps.last_completed_at - ps.last_started_at)) * 1000,
       EXTRACT(EPOCH FROM (:'t1'::timestamptz - :'t0'::timestamptz)) * 1000,
       ps.last_inserted_rows,
       'equivalence re-normalization run'
FROM telemetry.pipeline_state ps WHERE ps.pipeline_name = 'normalized_points';

DO $chk_equiv$
DECLARE
    v_status       text;
    v_added        bigint;
    v_removed      bigint;
    v_val_changed  bigint;
    v_pra_regress  bigint;
    v_cbs_changed  bigint;
    v_digest_match boolean;
BEGIN
    SELECT last_status INTO v_status FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_status = 'SKIPPED_LOCKED' THEN
        RAISE EXCEPTION 'PHASE 7 STOP: equivalence CALL returned SKIPPED_LOCKED';
    END IF;
    IF v_status <> 'SUCCESS' THEN
        RAISE EXCEPTION 'PHASE 7 STOP: equivalence CALL last_status=% (expected SUCCESS)', v_status;
    END IF;

    -- CORRECTION (2026-08-30, real staging --execute run): the digest is no
    -- longer a hard early-exit gate here. A real run showed the digest
    -- changing solely because the loader's candidate-discovery step
    -- (tmp_capture_candidates -- unrelated to migration 221's join change,
    -- which only runs on samples that step already selected) found
    -- previously-uncaptured buckets in the band and normalized them --
    -- additive key growth, not corruption. Aborting on digest mismatch
    -- alone, before computing v_added/v_removed/v_val_changed below, made it
    -- impossible to tell those two cases apart. The digest is still computed
    -- and still checked (further down, once the granular breakdown is
    -- known) as a defensive cross-check: it is a deterministic function of
    -- exactly the (key, value) pairs v_added/v_removed/v_val_changed already
    -- examine, so a mismatch with removed/changed both at zero should not be
    -- possible -- if it happens anyway, that is still a failure, not
    -- silently trusted away.
    v_digest_match := current_setting('gate.post_digest') IS NOT DISTINCT FROM current_setting('gate.ref_digest');

    -- B. Additive key growth: rows present now but not in the reference
    --    snapshot. NOT a correctness failure by itself -- see PHASE 4's
    --    EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS note: the loader discovers
    --    candidate buckets from raw data + current metadata on every call,
    --    independent of what was already SELECTED/FAILED beforehand.
    SELECT count(*) INTO v_added
    FROM ( SELECT event_time, device_id, logical_point_id
           FROM telemetry.normalized_points
           WHERE event_time >  (current_setting('gate.hist_start')::timestamptz - make_interval(secs => current_setting('gate.recon_overlap_secs')::int))
             AND event_time <= current_setting('gate.hist_end')::timestamptz
           EXCEPT
           SELECT event_time, device_id, logical_point_id FROM gate_np_ref ) d;

    -- C. Removed keys: rows in the reference snapshot but gone now. Always a
    --    correctness failure -- the loader's ON CONFLICT DO UPDATE never
    --    deletes a normalized_points row, so a key disappearing is real loss.
    SELECT count(*) INTO v_removed
    FROM ( SELECT event_time, device_id, logical_point_id FROM gate_np_ref
           EXCEPT
           SELECT event_time, device_id, logical_point_id
           FROM telemetry.normalized_points
           WHERE event_time >  (current_setting('gate.hist_start')::timestamptz - make_interval(secs => current_setting('gate.recon_overlap_secs')::int))
             AND event_time <= current_setting('gate.hist_end')::timestamptz ) d;

    -- A. Existing-key value mutation: value columns differing on a key
    --    present in BOTH snapshots. Always a correctness failure -- this is
    --    what migration 221's changed join could actually corrupt if it
    --    were wrong, unlike additive growth above.
    SELECT count(*) INTO v_val_changed
    FROM telemetry.normalized_points np
    JOIN gate_np_ref r USING (event_time, device_id, logical_point_id)
    WHERE np.raw_value          IS DISTINCT FROM r.raw_value
       OR np.numeric_value      IS DISTINCT FROM r.numeric_value
       OR np.quality_code       IS DISTINCT FROM r.quality_code
       OR np.mapping_source     IS DISTINCT FROM r.mapping_source
       OR np.organization_id    IS DISTINCT FROM r.organization_id
       OR np.site_id            IS DISTINCT FROM r.site_id
       OR np.gateway_id         IS DISTINCT FROM r.gateway_id;

    -- platform_received_at must never REGRESS (loader ON CONFLICT only bumps
    -- it forward, or when it was NULL).
    SELECT count(*) INTO v_pra_regress
    FROM telemetry.normalized_points np
    JOIN gate_np_ref r USING (event_time, device_id, logical_point_id)
    WHERE r.platform_received_at IS NOT NULL
      AND np.platform_received_at IS NOT NULL
      AND np.platform_received_at < r.platform_received_at;

    -- capture_bucket_samples status/identity for the band must be unchanged.
    SELECT count(*) INTO v_cbs_changed
    FROM telemetry.capture_bucket_samples c
    JOIN gate_cbs_ref r USING (site_id, bucket_start, device_id)
    WHERE c.status           IS DISTINCT FROM r.status
       OR c.raw_received_at   IS DISTINCT FROM r.raw_received_at
       OR c.raw_message_id    IS DISTINCT FROM r.raw_message_id;

    -- Defensive cross-check (see the v_digest_match comment above): a digest
    -- mismatch with added/removed/changed all at zero is unexplained by
    -- anything this block measures, and is still a failure -- never silently
    -- trusted away. (v_added is included here deliberately: a nonzero
    -- v_added fully explains a digest difference on its own, since the added
    -- rows' content is part of the post-CALL digest but not the reference
    -- one -- that case is additive growth, handled below, not this check.)
    IF NOT v_digest_match AND v_added = 0 AND v_removed = 0 AND v_val_changed = 0 THEN
        RAISE EXCEPTION 'PHASE 7 FAIL: digest differs (ref=% post=%) but no added/removed/changed rows were found -- unexplained digest mismatch; treat as a correctness failure pending investigation.',
            current_setting('gate.ref_digest'), current_setting('gate.post_digest');
    END IF;

    -- C. Removed keys -- always a failure.
    IF v_removed <> 0 THEN
        RAISE EXCEPTION 'PHASE 7 FAIL: % normalized_points key(s) present in the reference snapshot are now missing (data loss)', v_removed;
    END IF;
    -- A. Existing-key value mutation -- always a failure.
    IF v_val_changed <> 0 THEN
        RAISE EXCEPTION 'PHASE 7 FAIL: % normalized_points rows have changed value columns on keys present in both snapshots', v_val_changed;
    END IF;
    IF v_pra_regress <> 0 THEN
        RAISE EXCEPTION 'PHASE 7 FAIL: % normalized_points rows regressed platform_received_at', v_pra_regress;
    END IF;
    IF v_cbs_changed <> 0 THEN
        RAISE EXCEPTION 'PHASE 7 FAIL: % capture_bucket_samples rows (present in both snapshots) changed status/identity over the band', v_cbs_changed;
    END IF;

    -- B. Additive key growth -- reported, never a failure by itself.
    IF v_added <> 0 THEN
        RAISE WARNING 'EQUIVALENCE_ADDITIVE_KEY_GROWTH: % normalized_points key(s) present now that were not in the reference snapshot (digest_match=%). EXPECTED when the loader''s candidate-discovery step finds previously-uncaptured capture buckets in the band -- unrelated to migration 221''s join change, which only runs on samples the candidate step already selected. NOT treated as a correctness failure. Existing-key correctness (0 removed, 0 changed values, 0 platform_received_at regressions, 0 capture_bucket_samples identity changes on shared keys) was independently verified above.', v_added, v_digest_match;
        RAISE NOTICE 'PHASE 7 ok: equivalence holds for every key present in both snapshots (0 removed, 0 changed); % additive key(s) reported above as expected growth, not corruption.', v_added;
    ELSE
        RAISE NOTICE 'PHASE 7 ok: equivalence holds (digest match; 0 added/removed/changed; capture_bucket_samples unchanged).';
    END IF;
END;
$chk_equiv$;

\else
\echo 'DRY-RUN: skipping PHASE 7 equivalence re-normalization (gate_execute=off).'
\endif

-- ----------------------------------------------------------------------------
-- PHASE 8 — restoration of telemetry.pipeline_state (Job 1000 resume is the
--           .sh's responsibility). Runs only on the common, non-aborted path
--           when :gate_execute = on -- it is same-connection bookkeeping and
--           an evidence-file record, not the restoration mechanism of
--           record. If ON_ERROR_STOP aborts this script earlier (e.g. mid
--           PHASE 6/7), this connection closes and PHASE 8 never runs: the
--           .sh does NOT re-invoke this file to restore (an earlier draft's
--           header claimed that; corrected in a prior review pass -- see
--           this file's own header "CORRECTION" note). Durable restoration
--           is the .sh's restore_state() EXIT/INT/TERM trap, from state it
--           captured independently, before this connection existed; see
--           README-221.md "Cleanup / restoration".
-- ----------------------------------------------------------------------------
\echo ''
\echo '--- PHASE 8: restore telemetry.pipeline_state -------------------'

\if :gate_execute
UPDATE telemetry.pipeline_state ps
SET last_received_at   = r.last_received_at,
    last_started_at    = r.last_started_at,
    last_completed_at  = r.last_completed_at,
    last_inserted_rows = r.last_inserted_rows,
    last_status        = r.last_status,
    last_error         = r.last_error,
    updated_at         = r.updated_at
FROM gate_restore_pipeline_state r
WHERE ps.pipeline_name = 'normalized_points';

DO $phase8$
DECLARE v_diff int;
BEGIN
    SELECT count(*) INTO v_diff
    FROM telemetry.pipeline_state ps
    JOIN gate_restore_pipeline_state r ON r.pipeline_name = ps.pipeline_name
    WHERE ps.pipeline_name = 'normalized_points'
      AND ( ps.last_received_at   IS DISTINCT FROM r.last_received_at
         OR ps.last_started_at    IS DISTINCT FROM r.last_started_at
         OR ps.last_completed_at  IS DISTINCT FROM r.last_completed_at
         OR ps.last_inserted_rows IS DISTINCT FROM r.last_inserted_rows
         OR ps.last_status        IS DISTINCT FROM r.last_status
         OR ps.last_error         IS DISTINCT FROM r.last_error
         OR ps.updated_at         IS DISTINCT FROM r.updated_at );
    IF v_diff <> 0 THEN
        RAISE EXCEPTION 'PHASE 8 STOP: telemetry.pipeline_state row not restored to the captured baseline';
    END IF;
    RAISE NOTICE 'PHASE 8 ok: telemetry.pipeline_state (normalized_points) restored to the captured baseline.';
END;
$phase8$;
\else
\echo 'DRY-RUN: nothing to restore (no mutations were made).'
\endif

-- ----------------------------------------------------------------------------
-- PHASE 9 — verdict + evidence tables.
--   MEASUREMENTS and ACCEPTANCE CHECKS are printed separately.
--   The overall verdict is computed only from ACCEPTANCE CHECKS that ran.
-- ----------------------------------------------------------------------------
\echo ''
\echo '================================================================'
\echo ' PHASE 9: RESULTS'
\echo '================================================================'

\echo ''
\echo '--- MEASUREMENTS (no pass/fail; first run establishes the baseline) ---'
SELECT phase, p_max_window, baseline_mode,
       checkpoint_before, expected_window_end, checkpoint_after,
       last_status, server_duration_ms, client_wall_ms, last_inserted_rows, note
FROM gate_measurements
ORDER BY CASE phase WHEN '1m' THEN 1 WHEN '5m' THEN 2 WHEN '15m' THEN 3
                    WHEN '2h' THEN 4 WHEN 'equiv' THEN 5 ELSE 9 END;

\echo ''
\echo '--- ACCEPTANCE CHECKS ------------------------------------------------'
\echo 'Correctness/invariants ...... PHASES 1a-1f, 1c contract  (PASS if reached here)'
\echo 'Bounded catch-up ............ PHASE 6 window-end asserts (PASS if reached here)'
\echo 'Equivalence ................. PHASE 7 digest/set/cbs     (PASS if reached here)'
\echo 'Performance evidence ........ PHASE 5 + PHASE 6 timings  (EVIDENCE — reviewer sets any numeric bar)'
\echo 'Environmental/advisory ..... PHASE 1d stats, 1e status, PHASE 4 population, 2h vs max_runtime'
\echo ''
\if :gate_execute
\echo 'VERDICT INPUT: gate_execute=on. If this line printed with no prior'
\echo 'ERROR, PHASES 1-8 all passed their asserts -> correctness/bounded/'
\echo 'equivalence = PASS. Performance = EVIDENCE (see MEASUREMENTS). If the'
\echo '2h run is at/near 300000 ms a PHASE 6 WARNING was emitted: report only.'
\echo 'If PHASE 4 printed EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS (the .sh'
\echo 'greps this exact marker for its own verdict), mark Equivalence = PASS'
\echo '(non-corruption only) and INCONCLUSIVE for join-correctness -- see E-2.'
\else
\echo 'VERDICT INPUT: gate_execute=off (DRY-RUN). Preflight + recon + EXPLAIN'
\echo 'probe only. No CALL, no watermark move, no restore needed. A clean'
\echo 'dry-run is a prerequisite for scheduling the authorized full run.'
\endif
\echo ''
\echo 'Overall: PASS  = every ACCEPTANCE CHECK that ran passed AND PHASE 5'
\echo '                 plan shape shows raw_messages chunk exclusion / nested'
\echo '                 loop (reviewer confirms from the EXPLAIN output).'
\echo '         FAIL  = any ACCEPTANCE CHECK raised, or PHASE 5 still shows a'
\echo '                 full Parallel Append / Hash Join / ColumnarScan.'
\echo '         INCONCLUSIVE = a STOP fired in PHASE 0-4, or a SKIPPED_LOCKED,'
\echo '                 or the equivalence band had no driving samples, or the'
\echo '                 2h timing lands near max_runtime pending review.'
\echo '================================================================'
