-- ============================================================================
-- Migration 222 -- Restore the "Migration 203 (retained)" EXCEPTION paragraph
-- to COMMENT ON PROCEDURE telemetry.recover_failed_raw_messages(integer).
--
-- WHAT
--   Migration 218 re-issued the procedure comment but dropped the
--   "Migration 203 (retained)" paragraph -- the one explaining WHY a
--   per-candidate BEGIN...EXCEPTION WHEN OTHERS...END block cannot be added
--   alongside the migration-203 per-candidate COMMIT (PostgreSQL forbids a
--   transaction-control statement once an exception has been caught in the
--   same call frame).
--
--   scripts/test/assert_recovery_per_candidate_commit.sql requires
--   obj_description('telemetry.recover_failed_raw_messages(integer)') to
--   contain the word EXCEPTION; without that paragraph the structural check
--   fails once migration 218 lands. This migration re-issues COMMENT ON
--   PROCEDURE with migration 218's exact text plus that paragraph restored
--   verbatim (the wording committed in 1a856f0).
--
-- WHAT CHANGES
--   Exactly one statement: COMMENT ON PROCEDURE
--   telemetry.recover_failed_raw_messages(integer). No procedure-body change,
--   no other DDL.
--
-- NOT TOUCHED
--   telemetry.recover_failed_raw_messages() body; any table, constraint,
--   index, job, grant, view or other object; migration 220 and its file (its
--   original applied identity is retained -- this is a forward correction,
--   not a rewrite of 220).
-- ============================================================================

BEGIN;

COMMENT ON PROCEDURE telemetry.recover_failed_raw_messages(integer) IS
'Replays OPEN/RETRY_PENDING/DEFERRED_UNCOMMISSIONED telemetry.raw_message_failures rows, oldest raw_received_at first (ORDER BY raw_received_at, FOR UPDATE SKIP LOCKED, LIMIT p_limit, p_limit in [1,1000], default 100), through the same supersession (migration 201/204) and targeted normalized-points (migration 202) logic as the canonical pipeline. '
'Migration 203: each candidate is its own durable transaction -- this procedure COMMITs after every candidate''s complete unit of work, so a run cancelled at max_runtime keeps every candidate already resolved in it. Invoke ONLY as a bare top-level CALL. '
'Migration 206: population selection is purely age-based against the live telemetry.raw_messages retention policy (read dynamically from timescaledb_information.jobs); a candidate older than the retention cutoff is marked PERMANENT_FAILURE immediately, without the expensive path. '
'Migration 218: BEFORE the expensive current_elements CTE / supersession NOT EXISTS / resolve_site_capture_bucket() / normalized_points_for_recovery_candidate() work -- and AFTER the retention branch -- the candidate''s source MQTT UID is resolved via metadata.device_identifiers -> metadata.devices. If it does not resolve to a commissioned (lifecycle_status=''ACTIVE''), profiled device, the candidate is set to DEFERRED_UNCOMMISSIONED with its replay_attempt_count rolled back (a deferral is not a replay attempt), next_replay_at one hour out, and an explicit DEVICE_NOT_COMMISSIONED reason -- NOT PERMANENT_FAILURE. The loop re-scans DEFERRED_UNCOMMISSIONED rows every run, so a candidate rejoins the normal recovery path automatically, with no operator step and no data loss, once its device is commissioned. No UID-specific logic. Job 1077 schedule / max_runtime / config are unchanged. '
'Migration 203 (retained): this procedure intentionally does NOT add per-candidate EXCEPTION handling -- a per-candidate BEGIN...EXCEPTION WHEN OTHERS...END block combined with the per-candidate COMMIT fails with "invalid transaction termination" as soon as the handler catches a real error, because PostgreSQL forbids a transaction-control statement after an exception has been caught in the same call frame. Per-candidate commit and per-candidate error isolation are mutually incompatible in this procedure shape; only the former is implemented. A genuinely failing (not merely slow) candidate can still abort the current run at that point, rolling back only its own uncommitted work; every previously committed candidate in that run stays resolved. ';

COMMIT;
