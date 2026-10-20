-- ============================================================================
-- Release B1 lock watch (migrations 268, 269). READ-ONLY.
--
-- Samples every 5 s (psql \watch) while deploy-production.yml applies B1, and
-- prints one line per sample about the migration backend: the psql session
-- of user ems_admin run by scripts/apply_migrations.sh (application_name
-- 'psql', inside an open transaction). The release's other psql calls are
-- short autocommit SELECTs; every diagnostic in this directory sets its own
-- application_name, so it is never mistaken for the migration backend.
--
--   ts|mig_pid|xact_s|state|wait|lock_wait_s|blockers|queued|flag
--
-- flag:
--   IDLE         no migration backend (before / between / after migrations)
--   RUNNING      migration backend present, not waiting on a lock
--   WAITING      waiting on a lock for under 60 s
--   LONG_WAIT    waiting on one lock for >= 60 s, nothing queued behind it
--                (report only; not the abort rule)
--   ABORT_CANDIDATE  waiting on one lock for >= 60 s with at least one
--                session queued behind it (the B1 abort rule)
--
-- This script never cancels anything. Acting on ABORT_CANDIDATE is the
-- separately authorized operator step in the release plan (B1 abort rule).
--
-- Run with explicit authorization, read-only, in its own session. It stops
-- by itself after 180 samples (15 min; \watch count needs psql 16+, which the
-- production container has). Stopping it early by ending the SSH session can
-- leave its backend connected and idle: check for application_name
-- 'ems_b1_lockwatch' afterwards.
--   psql -X -v ON_ERROR_STOP=1 -f scripts/diagnostics/prod_b1_lockwatch.sql
-- ============================================================================
\pset footer off
\pset tuples_only on
\pset format unaligned
SET application_name = 'ems_b1_lockwatch';
SET statement_timeout = '4s';
SET lock_timeout = '1s';
SET TIME ZONE 'UTC';
SHOW default_transaction_read_only;

WITH mig AS (
    SELECT a.pid, a.state, a.xact_start, a.wait_event_type, a.wait_event
    FROM pg_stat_activity AS a
    WHERE a.pid <> pg_backend_pid()
      AND a.backend_type = 'client backend'
      AND a.usename = 'ems_admin'
      AND a.application_name = 'psql'
      AND a.xact_start IS NOT NULL
    ORDER BY a.xact_start
    LIMIT 1
),
w AS (
    SELECT m.pid, max(now() - l.waitstart) AS lock_wait
    FROM mig AS m JOIN pg_locks AS l ON l.pid = m.pid AND NOT l.granted
    GROUP BY m.pid
)
SELECT to_char(clock_timestamp(), 'HH24:MI:SS') || '|' ||
       coalesce(m.pid::TEXT, '-') || '|' ||
       coalesce(round(extract(epoch FROM now() - m.xact_start))::TEXT, '-') || '|' ||
       coalesce(m.state, '-') || '|' ||
       coalesce(m.wait_event_type || ':' || m.wait_event, '-') || '|' ||
       coalesce(round(extract(epoch FROM w.lock_wait))::TEXT, '0') || '|' ||
       coalesce((SELECT string_agg(b.pid || ':' || coalesce(nullif(b.application_name, ''), b.usename) || ':' ||
                                   coalesce(b.state, '') || ':' || round(extract(epoch FROM now() - b.xact_start)) || 's', ',')
                 FROM pg_stat_activity AS b WHERE b.pid = ANY (pg_blocking_pids(m.pid))), '-') || '|' ||
       coalesce((SELECT count(*) FROM pg_stat_activity AS q WHERE m.pid = ANY (pg_blocking_pids(q.pid)))::TEXT, '0') || '|' ||
       CASE
           WHEN m.pid IS NULL THEN 'IDLE'
           WHEN w.lock_wait >= interval '60 seconds'
            AND EXISTS (SELECT 1 FROM pg_stat_activity AS q WHERE m.pid = ANY (pg_blocking_pids(q.pid)))
               THEN 'ABORT_CANDIDATE'
           WHEN w.lock_wait >= interval '60 seconds' THEN 'LONG_WAIT'
           WHEN w.lock_wait IS NOT NULL THEN 'WAITING'
           ELSE 'RUNNING'
       END
FROM (SELECT 1) AS one
LEFT JOIN mig AS m ON true
LEFT JOIN w ON w.pid = m.pid
\watch i=5 c=180
