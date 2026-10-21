-- LOCAL ONLY test fixture (see lib.sh) (copies of disposable template databases, scheduler
-- stopped): production-shaped job ids and a clean, production-like stats state.
SET client_min_messages = warning;
CREATE OR REPLACE PROCEDURE public.fixture_noop(job_id int, config jsonb) LANGUAGE plpgsql AS $$ BEGIN END $$;
DO $$
DECLARE v int;
BEGIN
    FOREACH v IN ARRAY ARRAY[1053, 1062, 1063, 1064, 1097, 1100, 1103, 1114, 1115, 1116, 1117, 1118, 1119, 1120] LOOP
        IF NOT EXISTS (SELECT 1 FROM _timescaledb_catalog.bgw_job WHERE id = v) THEN
            PERFORM setval('_timescaledb_catalog.bgw_job_id_seq', v - 1, true);
            PERFORM add_job('public.fixture_noop', '1 hour', initial_start => now() + interval '10 years');
        END IF;
    END LOOP;
    PERFORM setval('_timescaledb_catalog.bgw_job_id_seq', 5000, true);
END $$;
UPDATE _timescaledb_catalog.bgw_job SET scheduled = (id NOT IN (1053, 1114, 1115, 1116, 1117, 1118, 1119, 1120));
-- One clean stats row per job: last run finished and succeeded.
DELETE FROM _timescaledb_internal.bgw_job_stat;
INSERT INTO _timescaledb_internal.bgw_job_stat
    (job_id, last_start, last_finish, next_start, last_successful_finish, last_run_success,
     total_runs, total_duration, total_duration_failures, total_successes, total_failures,
     total_crashes, consecutive_failures, consecutive_crashes, flags)
SELECT id, now() - interval '70 seconds', now() - interval '60 seconds', now() + interval '1 hour',
       now() - interval '60 seconds', true, 100, interval '10 seconds', interval '0', 100, 0, 0, 0, 0, 0
FROM _timescaledb_catalog.bgw_job;
-- Failure baseline 2840 (all jobs except 1114) held by paused job 1053.
UPDATE _timescaledb_internal.bgw_job_stat SET total_failures = 2840 WHERE job_id = 1053;
DELETE FROM _timescaledb_internal.bgw_job_stat_history WHERE succeeded IS NOT TRUE;
