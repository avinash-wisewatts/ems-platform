-- ============================================================================
-- File:
--   49_remove_legacy_energy_test_row.sql
--
-- Purpose:
--   Remove the original manually inserted proof-of-concept energy row.
--
-- Safety:
--   The row is deleted only when all identifying values match the known
--   historical test record. This prevents accidental deletion if ID 1 is ever
--   reused or if the database differs from the expected development state.
-- ============================================================================

DO
$$
DECLARE
    v_deleted_rows INTEGER;
BEGIN
    DELETE FROM telemetry.energy_measurements
    WHERE id = 1
      AND received_at =
          TIMESTAMPTZ '2026-07-15 16:25:52.713768+05:30'
      AND device_id =
          '009c7759-3b65-46e7-8e87-3738df287ee4'::UUID
      AND source_timestamp =
          TIMESTAMPTZ '2018-01-19 17:21:23+05:30';

    GET DIAGNOSTICS v_deleted_rows = ROW_COUNT;

    IF v_deleted_rows = 1 THEN
        RAISE NOTICE
            'Deleted the legacy proof-of-concept energy row';
    ELSIF v_deleted_rows = 0 THEN
        RAISE NOTICE
            'Legacy proof-of-concept energy row was not present';
    ELSE
        RAISE EXCEPTION
            'Unexpectedly deleted % legacy rows',
            v_deleted_rows;
    END IF;
END;
$$;
