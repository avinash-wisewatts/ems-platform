-- ============================================================================
-- Rollback for migration 296 (telemetry.normalized_points identity index
-- order).
--
-- Controlled reversal. NOT run as part of any migration. Restores
-- uq_normalized_points_identity to its pre-296 column order
-- (event_time, device_id, logical_point_id): build the old-order unique
-- index under a temporary name, drop the reordered one, rename. Same column
-- set, so uniqueness and the ON CONFLICT (event_time, device_id,
-- logical_point_id) arbiter are unaffected throughout. The migration ledger
-- row for 296 is left in place (record the rollback in the runbook).
--
-- Locking: identical to migration 296 -- a SHARE lock on the hypertable for
-- the build, so inserts wait until COMMIT (raw messages are normalized
-- afterwards). lock_timeout 10 s fails fast instead of queueing.
--
-- Refuses unless the identity index is currently in the 296 order and the
-- temporary name is free.
--
-- Run manually, inside a single transaction, after explicit approval:
--   psql -X -v ON_ERROR_STOP=1 -U ems_admin -d <db> \
--     -f postgres/maintenance/296_normalized_points_identity_index_order_rollback.sql
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '30min';

DO $rollback_guard$
DECLARE
    v_cols TEXT;
BEGIN
    SELECT string_agg(a.attname, ',' ORDER BY k.ord)
    INTO v_cols
    FROM pg_index AS i
    CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute AS a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    WHERE i.indexrelid = to_regclass('telemetry.uq_normalized_points_identity')
      AND i.indisunique AND i.indisvalid;
    IF v_cols IS DISTINCT FROM 'device_id,logical_point_id,event_time' THEN
        RAISE EXCEPTION 'Rollback 296 refused: the identity index is not in the migration 296 order (found %).', v_cols;
    END IF;
    IF to_regclass('telemetry.uq_normalized_points_identity_pre296') IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 296 refused: telemetry.uq_normalized_points_identity_pre296 already exists.';
    END IF;
END;
$rollback_guard$;

CREATE UNIQUE INDEX uq_normalized_points_identity_pre296
    ON telemetry.normalized_points (event_time, device_id, logical_point_id);

DROP INDEX telemetry.uq_normalized_points_identity;

ALTER INDEX telemetry.uq_normalized_points_identity_pre296 RENAME TO uq_normalized_points_identity;

DO $rollback_check$
DECLARE
    v_cols TEXT;
BEGIN
    SELECT string_agg(a.attname, ',' ORDER BY k.ord)
    INTO v_cols
    FROM pg_index AS i
    CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute AS a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    WHERE i.indexrelid = to_regclass('telemetry.uq_normalized_points_identity')
      AND i.indisunique AND i.indisvalid AND i.indisready;
    IF v_cols IS DISTINCT FROM 'event_time,device_id,logical_point_id' THEN
        RAISE EXCEPTION 'Rollback 296 check failed: identity index columns are %.', v_cols;
    END IF;
    RAISE NOTICE 'Rollback 296: identity index restored to (event_time, device_id, logical_point_id).';
END;
$rollback_check$;

COMMIT;
