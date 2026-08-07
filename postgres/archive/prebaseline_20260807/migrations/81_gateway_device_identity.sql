-- ============================================================================
-- File: 81_gateway_device_identity.sql
-- Purpose:
--   Enforce stable organization-scoped natural keys for gateways and devices.
--
-- Production guarantees:
--   1. Existing records are preserved.
--   2. Migration refuses to continue if blank or duplicate external IDs exist.
--   3. Gateway external IDs are unique within an organization.
--   4. Device external IDs are unique within an organization.
--   5. Matching is case-insensitive and ignores surrounding whitespace.
-- ============================================================================

BEGIN;


-- ============================================================================
-- 1. REFUSE BLANK GATEWAY EXTERNAL IDS
-- ============================================================================

DO
$$
DECLARE
    v_blank_count BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_blank_count
    FROM metadata.gateways
    WHERE NULLIF(btrim(external_id), '') IS NULL;

    IF v_blank_count > 0 THEN
        RAISE EXCEPTION
            'Cannot enforce gateway identity: % gateways have blank external IDs',
            v_blank_count;
    END IF;
END;
$$;


-- ============================================================================
-- 2. REFUSE DUPLICATE GATEWAY EXTERNAL IDS
-- ============================================================================

DO
$$
DECLARE
    v_duplicate_count BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_duplicate_count
    FROM
    (
        SELECT
            organization_id,
            upper(btrim(external_id))
        FROM metadata.gateways
        GROUP BY
            organization_id,
            upper(btrim(external_id))
        HAVING COUNT(*) > 1
    ) conflicts;

    IF v_duplicate_count > 0 THEN
        RAISE EXCEPTION
            'Cannot enforce gateway identity: % duplicate organization-scoped external IDs found',
            v_duplicate_count;
    END IF;
END;
$$;


-- ============================================================================
-- 3. NORMALIZE AND REQUIRE GATEWAY EXTERNAL IDS
-- ============================================================================

UPDATE metadata.gateways
SET external_id = upper(btrim(external_id))
WHERE external_id IS DISTINCT FROM upper(btrim(external_id));


ALTER TABLE metadata.gateways
    ALTER COLUMN external_id SET NOT NULL;


CREATE UNIQUE INDEX IF NOT EXISTS gateways_org_external_id_ci_uq
    ON metadata.gateways
    (
        organization_id,
        upper(btrim(external_id))
    );


-- ============================================================================
-- 4. REFUSE BLANK DEVICE EXTERNAL IDS
-- ============================================================================

DO
$$
DECLARE
    v_blank_count BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_blank_count
    FROM metadata.devices
    WHERE NULLIF(btrim(external_id), '') IS NULL;

    IF v_blank_count > 0 THEN
        RAISE EXCEPTION
            'Cannot enforce device identity: % devices have blank external IDs',
            v_blank_count;
    END IF;
END;
$$;


-- ============================================================================
-- 5. REFUSE DUPLICATE DEVICE EXTERNAL IDS
-- ============================================================================

DO
$$
DECLARE
    v_duplicate_count BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_duplicate_count
    FROM
    (
        SELECT
            organization_id,
            upper(btrim(external_id))
        FROM metadata.devices
        GROUP BY
            organization_id,
            upper(btrim(external_id))
        HAVING COUNT(*) > 1
    ) conflicts;

    IF v_duplicate_count > 0 THEN
        RAISE EXCEPTION
            'Cannot enforce device identity: % duplicate organization-scoped external IDs found',
            v_duplicate_count;
    END IF;
END;
$$;


-- ============================================================================
-- 6. NORMALIZE AND REQUIRE DEVICE EXTERNAL IDS
-- ============================================================================

UPDATE metadata.devices
SET external_id = upper(btrim(external_id))
WHERE external_id IS DISTINCT FROM upper(btrim(external_id));


ALTER TABLE metadata.devices
    ALTER COLUMN external_id SET NOT NULL;


CREATE UNIQUE INDEX IF NOT EXISTS devices_org_external_id_ci_uq
    ON metadata.devices
    (
        organization_id,
        upper(btrim(external_id))
    );


COMMIT;
