-- ============================================================================
-- Release B1 guarded cancel (migrations 268, 269). The ONLY action in the B1
-- procedure, and only with its own explicit authorization, at most once.
--
-- Use only after prod_b1_lockwatch.sql shows ABORT_CANDIDATE for :pid. It
-- re-checks every abort condition at the moment it runs and calls
-- pg_cancel_backend only if all of them still hold:
--   * :pid is the migration backend: client backend, user ems_admin,
--     application_name 'psql', inside a transaction;
--   * it is waiting on a lock (wait_event_type = 'Lock') and one of its
--     ungranted locks has waited >= 60 s;
--   * at least one other session is queued behind it.
-- Otherwise it returns no CANCEL row and does nothing.
--
-- It never calls pg_terminate_backend. Cancelling rolls back only the
-- migration's own transaction (apply_migrations.sh wraps each migration and
-- its ledger insert in one BEGIN ... COMMIT); the runner then stops and the
-- deploy job fails before compose up.
--
-- After the cancel it waits 15 s and reports whether :pid is still present.
--   CANCEL|pid|signalled|lock_wait_s|queued|xact_s   (absent = guard refused)
--   AFTER15S|pid|present|state|wait
-- If CANCEL is absent, signalled is false, or AFTER15S shows present=true
-- and still waiting on Lock: stop and report. Do not retry, do not
-- terminate.
--
--   psql -X -v ON_ERROR_STOP=1 -v pid=<migration pid> \
--     -f scripts/diagnostics/prod_b1_guarded_cancel.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on
\pset format unaligned
SET application_name = 'ems_b1_guarded_cancel';
SET statement_timeout = '30s';
SET lock_timeout = '1s';
SET TIME ZONE 'UTC';

SELECT 'CANCEL|' || a.pid || '|' || pg_cancel_backend(a.pid) || '|'
       || round(extract(epoch FROM now() - w.waitstart)) || '|' || q.queued || '|'
       || round(extract(epoch FROM now() - a.xact_start))
FROM pg_stat_activity AS a
CROSS JOIN LATERAL (
    SELECT min(l.waitstart) AS waitstart FROM pg_locks AS l WHERE l.pid = a.pid AND NOT l.granted
) AS w
CROSS JOIN LATERAL (
    SELECT count(*) AS queued FROM pg_stat_activity AS b WHERE a.pid = ANY (pg_blocking_pids(b.pid))
) AS q
WHERE a.pid = :pid
  AND a.pid <> pg_backend_pid()
  AND a.backend_type = 'client backend'
  AND a.usename = 'ems_admin'
  AND a.application_name = 'psql'
  AND a.xact_start IS NOT NULL
  AND a.wait_event_type = 'Lock'
  AND w.waitstart <= now() - interval '60 seconds'
  AND q.queued >= 1;

SELECT pg_sleep(15);

SELECT 'AFTER15S|' || :pid || '|' || (count(*) > 0) || '|' || coalesce(max(a.state), '-') || '|'
       || coalesce(max(a.wait_event_type || ':' || a.wait_event), '-')
FROM pg_stat_activity AS a WHERE a.pid = :pid;
