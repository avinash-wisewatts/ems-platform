-- ============================================================================
-- Release D post-deploy step: return the six migration-300 jobs to their
-- 1-minute production schedules (decision D9). NOT a migration.
--
-- Run only with explicit approval, once, right after the Release D deploy
-- run has finished and its post-deployment verification has passed:
--
--   psql -X -v ON_ERROR_STOP=1 -v target=production \
--        -f docs/10-operations/prepared/release-d/post_deploy_restore_1min_schedules.sql
--
-- `target=production` additionally asserts the production job IDs and that
-- the deploy reached migration 308. `target=local-test` skips those two
-- checks (used to test this script on the disposable local test database).
--
-- Schedule only: no procedure body, job config, retry or runtime setting, and
-- no other job changes. One transaction; any failed check rolls everything
-- back. Checkpoints make the order irrelevant: the next 1-minute runs pick up
-- whatever the 5-minute runs had not yet processed.
--
-- Restored values are production's settings read on 2026-10-23 12:10 UTC
-- (read-only), before migration 300 ran there:
--
--   job   stage                                 interval  fixed  initial_start (UTC)
--   1000  telemetry.run_normalization_job        1 min     yes    2026-07-16 05:42:24.227074
--   1001  telemetry.run_energy_routing_job       1 min     yes    2026-08-13 10:41:50
--   1012  telemetry.run_environment_routing_job  1 min     yes    2026-07-17 03:54:24.461312
--   1063  analytics.run_energy_consumption_1min  1 min     yes    2026-08-13 13:26:48.450093
--   1044  refresh telemetry.ca_energy_1min       1 min     no     (none)
--   1083  refresh ca_energy_phase_power_1min     1 min     no     (none)
--
-- 1044 / 1083: TimescaleDB does not clear initial_start, so the value
-- migration 300 set stays in the catalog; it has no effect on a non-fixed
-- schedule (the next run is always the previous finish + 1 minute).
--
-- Undo (back to five-minute batching): only by the separate future approval
-- to enable five-minute batching; re-run migration 300's schedule block.
-- ============================================================================
\set ON_ERROR_STOP on
\if :{?target}
\else
\echo 'Set -v target=production (or target=local-test).'
\quit
\endif

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
SELECT set_config('d9.target', :'target', true);

CREATE TEMP TABLE d9_targets (
    label         text PRIMARY KEY,
    prod_job_id   integer NOT NULL,
    fixed         boolean NOT NULL,
    initial_start timestamptz,
    job_id        integer
) ON COMMIT DROP;

INSERT INTO d9_targets (label, prod_job_id, fixed, initial_start) VALUES
    ('normalization',        1000, true,  '2026-07-16 05:42:24.227074+00'),
    ('energy_routing',       1001, true,  '2026-08-13 10:41:50+00'),
    ('environment_routing',  1012, true,  '2026-07-17 03:54:24.461312+00'),
    ('consumption_1min',     1063, true,  '2026-08-13 13:26:48.450093+00'),
    ('ca_energy_1min',       1044, false, NULL),
    ('ca_energy_phase_1min', 1083, false, NULL);

-- 1. Preconditions: migration 300 applied (and, on production, the whole
--    deploy through 308); each target found exactly once by name and still on
--    migration 300's five-minute fixed schedule.
DO $pre$
DECLARE
    t     RECORD;
    v_n   integer;
    v_job integer;
    v_bad text;
BEGIN
    IF current_setting('d9.target') NOT IN ('production', 'local-test') THEN
        RAISE EXCEPTION 'D9 restore: target must be production or local-test, got %', current_setting('d9.target');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id = '300_pipeline_five_minute_batch_schedule') THEN
        RAISE EXCEPTION 'D9 restore: migration 300 is not applied; nothing to restore.';
    END IF;
    IF current_setting('d9.target') = 'production'
       AND NOT EXISTS (SELECT 1 FROM admin.schema_migrations WHERE migration_id = '308_security_definer_job_routines_revoke_public') THEN
        RAISE EXCEPTION 'D9 restore: the deploy has not reached migration 308; wait for the deploy run to finish.';
    END IF;

    FOR t IN SELECT label FROM d9_targets LOOP
        SELECT count(*), min(j.job_id) INTO v_n, v_job
        FROM timescaledb_information.jobs AS j
        WHERE CASE t.label
            WHEN 'normalization'        THEN j.proc_schema = 'telemetry' AND j.proc_name = 'run_normalization_job'
            WHEN 'energy_routing'       THEN j.proc_schema = 'telemetry' AND j.proc_name = 'run_energy_routing_job'
            WHEN 'environment_routing'  THEN j.proc_schema = 'telemetry' AND j.proc_name = 'run_environment_routing_job'
            WHEN 'consumption_1min'     THEN j.proc_schema = 'analytics' AND j.proc_name = 'run_energy_consumption_1min_job'
            WHEN 'ca_energy_1min'       THEN j.proc_name = 'policy_refresh_continuous_aggregate'
                                         AND j.hypertable_schema = 'telemetry' AND j.hypertable_name = 'ca_energy_1min'
            WHEN 'ca_energy_phase_1min' THEN j.proc_name = 'policy_refresh_continuous_aggregate'
                                         AND j.hypertable_schema = 'telemetry' AND j.hypertable_name = 'ca_energy_phase_power_1min'
        END;
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'D9 restore: expected exactly one % job, found %', t.label, v_n;
        END IF;
        UPDATE d9_targets SET job_id = v_job WHERE label = t.label;
    END LOOP;

    IF current_setting('d9.target') = 'production' THEN
        SELECT string_agg(format('%s is job %s, expected %s', label, job_id, prod_job_id), ', ') INTO v_bad
        FROM d9_targets WHERE job_id <> prod_job_id;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'D9 restore: production job IDs differ: %', v_bad;
        END IF;
    END IF;

    SELECT string_agg(format('%s (job %s) every %s fixed %s', m.label, m.job_id, j.schedule_interval, j.fixed_schedule), ', ') INTO v_bad
    FROM d9_targets m JOIN timescaledb_information.jobs j ON j.job_id = m.job_id
    WHERE j.schedule_interval <> INTERVAL '5 minutes' OR NOT j.fixed_schedule OR NOT j.scheduled;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'D9 restore: targets are not on the migration-300 five-minute schedule (already restored, paused or changed): %', v_bad;
    END IF;
END
$pre$;

-- Snapshot of every job, to prove only the six targets' schedules changed.
CREATE TEMP TABLE d9_before ON COMMIT DROP AS
SELECT j.job_id, j.schedule_interval, j.fixed_schedule, j.initial_start, j.scheduled,
       j.max_runtime, j.max_retries, j.retry_period, j.config,
       j.check_schema, j.check_name, j.proc_schema, j.proc_name
FROM timescaledb_information.jobs AS j;

-- 2. Restore. Fixed jobs: next slot on their original second-of-minute grid
--    at least 10 s from now. Non-fixed refreshes: next minute + 18 / 19 s
--    (their production position before 300, after normalization at :24).
DO $restore$
DECLARE
    t      RECORD;
    v_next timestamptz;
BEGIN
    FOR t IN SELECT * FROM d9_targets ORDER BY prod_job_id LOOP
        IF t.fixed THEN
            v_next := t.initial_start + make_interval(
                mins => ceil(extract(epoch FROM (now() + INTERVAL '10 seconds' - t.initial_start)) / 60)::integer);
            PERFORM alter_job(
                t.job_id,
                schedule_interval => INTERVAL '1 minute',
                fixed_schedule    => TRUE,
                initial_start     => t.initial_start,
                next_start        => v_next
            );
        ELSE
            v_next := date_trunc('minute', now()) + INTERVAL '1 minute'
                      + CASE t.label WHEN 'ca_energy_1min' THEN INTERVAL '18 seconds' ELSE INTERVAL '19 seconds' END;
            PERFORM alter_job(
                t.job_id,
                schedule_interval => INTERVAL '1 minute',
                fixed_schedule    => FALSE,
                next_start        => v_next
            );
        END IF;
        RAISE NOTICE 'D9 restore: job % (%) every 1 minute, fixed %, first run %', t.job_id, t.label, t.fixed, v_next;
    END LOOP;
END
$restore$;

-- 3. Postconditions: targets on 1 minute with the original fixed / grid;
--    their other settings and every other job unchanged.
DO $post$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(format('%s (job %s)', m.label, m.job_id), ', ') INTO v_bad
    FROM d9_targets m
    JOIN timescaledb_information.jobs j ON j.job_id = m.job_id
    JOIN d9_before b ON b.job_id = m.job_id
    WHERE j.schedule_interval <> INTERVAL '1 minute'
       OR j.fixed_schedule IS DISTINCT FROM m.fixed
       OR (m.fixed AND j.initial_start IS DISTINCT FROM m.initial_start)
       OR (j.scheduled, j.max_runtime, j.max_retries, j.retry_period, j.config, j.check_schema, j.check_name)
          IS DISTINCT FROM
          (b.scheduled, b.max_runtime, b.max_retries, b.retry_period, b.config, b.check_schema, b.check_name);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'D9 restore: target settings wrong after alter_job: %', v_bad;
    END IF;

    SELECT string_agg(format('job %s (%s.%s)', b.job_id, b.proc_schema, b.proc_name), ', ') INTO v_bad
    FROM d9_before b
    JOIN timescaledb_information.jobs j ON j.job_id = b.job_id
    WHERE b.job_id NOT IN (SELECT job_id FROM d9_targets)
      AND (j.schedule_interval, j.fixed_schedule, j.initial_start, j.scheduled, j.max_runtime,
           j.max_retries, j.retry_period, j.config, j.check_schema, j.check_name)
          IS DISTINCT FROM
          (b.schedule_interval, b.fixed_schedule, b.initial_start, b.scheduled, b.max_runtime,
           b.max_retries, b.retry_period, b.config, b.check_schema, b.check_name);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'D9 restore: non-target jobs changed: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs) <> (SELECT count(*) FROM d9_before) THEN
        RAISE EXCEPTION 'D9 restore: the number of jobs changed';
    END IF;
END
$post$;

SELECT m.job_id, m.label, j.schedule_interval, j.fixed_schedule, j.initial_start, s.next_start
FROM d9_targets m
JOIN timescaledb_information.jobs j ON j.job_id = m.job_id
JOIN timescaledb_information.job_stats s ON s.job_id = m.job_id
ORDER BY m.prod_job_id;

COMMIT;
