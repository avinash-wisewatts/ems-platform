-- ============================================================================
-- File: 79_primary_meter_integrity.sql
-- Purpose:
--   Enforce one-to-one PRIMARY_METER ownership between operational assets and
--   physical metering devices.
--
-- Rules:
--   1. One device may be PRIMARY_METER for at most one asset.
--   2. One asset may have at most one PRIMARY_METER device.
--
-- The existing device-side rule is retained. This migration adds the missing
-- asset-side rule.
-- ============================================================================

BEGIN;


-- ============================================================================
-- 1. REFUSE MIGRATION IF EXISTING DATA VIOLATES THE NEW RULE
-- ============================================================================

DO $$
DECLARE
    v_conflicting_asset_count BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_conflicting_asset_count
    FROM
    (
        SELECT ad.asset_id
        FROM metadata.asset_devices ad
        WHERE ad.relationship_type = 'PRIMARY_METER'
        GROUP BY ad.asset_id
        HAVING COUNT(*) > 1
    ) conflicts;

    IF v_conflicting_asset_count > 0 THEN
        RAISE EXCEPTION
            'Cannot enforce one PRIMARY_METER per asset: % conflicting assets found.',
            v_conflicting_asset_count;
    END IF;
END;
$$;


-- ============================================================================
-- 2. ENFORCE ONE PRIMARY METER PER ASSET
-- ============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS uq_asset_devices_asset_primary_meter
    ON metadata.asset_devices (asset_id)
    WHERE relationship_type = 'PRIMARY_METER';


COMMIT;
