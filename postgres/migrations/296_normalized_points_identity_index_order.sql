-- ============================================================================
-- Migration 296
-- telemetry.normalized_points: reorder the unique identity index from
-- (event_time, device_id, logical_point_id) to
-- (device_id, logical_point_id, event_time).
--
-- STAGING TRIAL FIRST. Production promotion is a separate, explicit
-- decision after the staging measurements below (staged release).
--
-- Why. Analytics B3 1-minute reads (analytics.get_portal_asset_point_series,
-- migrations 292/293) look up one meter point over a time range. On the
-- uncompressed chunk the only usable index is idx_norm_lp_time
-- (logical_point_id, event_time), which returns every device's rows for the
-- point; staging measured 2,768 page reads to return 60 rows for one hour
-- (1.47 s; about 35 s for one day) because the 7-day chunk (2.9 GB on
-- 2026-10-10) does not fit in memory. Compressed chunks are already
-- segmented by (organization_id, device_id, logical_point_id): one day
-- there took 11 ms. An index led by (device_id, logical_point_id) reads only
-- that meter point's rows.
--
-- Why reorder instead of adding an index. The identity index exists for
-- uniqueness and as the ON CONFLICT (event_time, device_id, logical_point_id)
-- arbiter of the normalization loader (migration 221) and recovery paths.
-- PostgreSQL infers the arbiter from the column SET, not the order, so the
-- reordered index serves the same ON CONFLICT clauses; uniqueness is
-- identical (same columns). Write cost stays the same (one index replaced by
-- one index). Verified locally on TimescaleDB 2.29.2 (staging's version)
-- with compressed chunks: ON CONFLICT DO UPDATE into uncompressed and
-- compressed chunks with both indexes and with only the reordered one;
-- duplicates still rejected in both; drop + rename; device + point + time
-- lookups become an index-only scan.
--
-- Change (one transaction, as the migration runner applies it):
--   1. CREATE UNIQUE INDEX uq_normalized_points_identity_v2 ON
--      telemetry.normalized_points (device_id, logical_point_id, event_time)
--      -- built on every uncompressed chunk (compressed chunks keep their
--      own indexes; TimescaleDB recreates hypertable indexes on
--      decompression).
--   2. DROP INDEX telemetry.uq_normalized_points_identity.
--   3. ALTER INDEX ... RENAME TO uq_normalized_points_identity (the name the
--      integration assertion and documentation use).
--
-- Locking (operational): building inside the migration transaction holds a
-- SHARE lock on the hypertable for the build, so inserts (the normalization
-- job, every minute) wait until COMMIT; raw messages keep arriving and are
-- normalized afterwards (raw retention 48 h). lock_timeout 10 s makes the
-- migration fail fast instead of queueing behind a long transaction.
-- Schedule: shortly after the previous chunk has been compressed (the
-- uncompressed chunk is then smallest). Measure the build time on staging
-- before deciding anything for production.
--
-- Rollback: a reverse migration with the same three steps in the old column
-- order (same locking profile).
-- ============================================================================

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '30min';

DO $pre$
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
    IF v_cols IS NULL THEN
        RAISE EXCEPTION 'Migration 296 precondition failed: telemetry.uq_normalized_points_identity is missing, not unique or not valid.';
    END IF;
    IF v_cols = 'device_id,logical_point_id,event_time' THEN
        RAISE EXCEPTION 'Migration 296 precondition failed: the identity index is already in the new order.';
    END IF;
    IF v_cols <> 'event_time,device_id,logical_point_id' THEN
        RAISE EXCEPTION 'Migration 296 precondition failed: unexpected identity index columns (%).', v_cols;
    END IF;
    IF to_regclass('telemetry.uq_normalized_points_identity_v2') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 296 precondition failed: telemetry.uq_normalized_points_identity_v2 already exists.';
    END IF;
END;
$pre$;

CREATE UNIQUE INDEX uq_normalized_points_identity_v2
    ON telemetry.normalized_points (device_id, logical_point_id, event_time);

DROP INDEX telemetry.uq_normalized_points_identity;

ALTER INDEX telemetry.uq_normalized_points_identity_v2 RENAME TO uq_normalized_points_identity;

DO $post$
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
    IF v_cols IS DISTINCT FROM 'device_id,logical_point_id,event_time' THEN
        RAISE EXCEPTION 'Migration 296 postcondition failed: identity index columns are %.', v_cols;
    END IF;
    IF to_regclass('telemetry.uq_normalized_points_identity_v2') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 296 postcondition failed: the temporary index name still exists.';
    END IF;
    RAISE NOTICE 'Migration 296: identity index reordered to (device_id, logical_point_id, event_time); uniqueness and ON CONFLICT arbiter unchanged.';
END;
$post$;
