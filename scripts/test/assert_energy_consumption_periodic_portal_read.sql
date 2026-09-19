\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS — Migration 248 contract
--
-- Proves analytics.get_portal_site_energy_consumption_periodic(bigint, uuid,
-- timestamptz, timestamptz, text) against REAL rows in
-- analytics.energy_consumption_daily (no mocking, no Python layer):
--   - Weekly (Monday-anchored), Monthly, and Yearly grouping are correct;
--   - a partial first/last period sums only the days actually present;
--   - a range with zero underlying days returns zero rows (the existing
--     no_data contract, upstream in build_energy_consumption_response,
--     depends on this);
--   - tenant isolation: a portal user with no access to the site gets zero
--     rows, even though the site has real data;
--   - grouping uses the already-site-local consumption_date column, not a
--     UTC reinterpretation of bucket_start -- proven with an Asia/Kolkata
--     site (UTC+5:30) whose bucket_start instants therefore do NOT fall on
--     UTC calendar-day/week/month boundaries.
--
-- All test records are created inside one transaction and rolled back.
-- =============================================================================

BEGIN;

INSERT INTO metadata.organizations (id, name, code, description, is_active)
VALUES
    ('98500000-0000-0000-0000-000000000001', 'Periodic Contract Tenant', 'PERIODIC_CONTRACT', 'Disposable migration 248 contract tenant', TRUE),
    ('98500000-0000-0000-0000-000000000002', 'Periodic Contract Other Tenant', 'PERIODIC_CONTRACT_OTHER', 'Disposable migration 248 tenant-isolation control tenant', TRUE);

INSERT INTO metadata.sites (id, organization_id, name, code, timezone, address, is_active)
VALUES
    ('98510000-0000-0000-0000-000000000001', '98500000-0000-0000-0000-000000000001', 'Periodic Contract Site', 'PERIODIC_CONTRACT_SITE', 'Asia/Kolkata', '{}'::jsonb, TRUE);

-- Site-local daily rows, all real per-day totals -- no fabricated values.
-- 2026-08-24 is a Monday. Days: Aug24(Mon,10) Aug25(Tue,20) -- week 1;
-- Aug30(Sun,7) closes week 1; Aug31(Mon,5) opens week 2 and August-end;
-- Sep01(Tue,3) opens September. Each bucket_start is the real UTC instant
-- of that date's Asia/Kolkata local midnight (00:00+05:30 = 18:30 UTC the
-- previous UTC calendar day) -- deliberately off the UTC calendar grid, to
-- prove grouping does not silently reinterpret it in UTC.
INSERT INTO analytics.energy_consumption_daily
    (bucket_start, consumption_date, site_timezone, organization_id, site_id, device_id,
     source_interval_count, import_consumption_kwh, export_consumption_kwh,
     valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals,
     gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count)
VALUES
    ('2026-08-24T00:00:00+05:30', '2026-08-24', 'Asia/Kolkata', '98500000-0000-0000-0000-000000000001', '98510000-0000-0000-0000-000000000001', '98520000-0000-0000-0000-000000000001',
     96, 10, 0, 96, 0, 96, 0, 0, 0, 0, 0),
    ('2026-08-25T00:00:00+05:30', '2026-08-25', 'Asia/Kolkata', '98500000-0000-0000-0000-000000000001', '98510000-0000-0000-0000-000000000001', '98520000-0000-0000-0000-000000000001',
     96, 20, 0, 96, 0, 96, 0, 0, 0, 0, 0),
    ('2026-08-30T00:00:00+05:30', '2026-08-30', 'Asia/Kolkata', '98500000-0000-0000-0000-000000000001', '98510000-0000-0000-0000-000000000001', '98520000-0000-0000-0000-000000000001',
     96, 7, 0, 96, 0, 96, 0, 0, 0, 0, 0),
    ('2026-08-31T00:00:00+05:30', '2026-08-31', 'Asia/Kolkata', '98500000-0000-0000-0000-000000000001', '98510000-0000-0000-0000-000000000001', '98520000-0000-0000-0000-000000000001',
     96, 5, 0, 96, 0, 96, 0, 0, 0, 0, 0),
    ('2026-09-01T00:00:00+05:30', '2026-09-01', 'Asia/Kolkata', '98500000-0000-0000-0000-000000000001', '98510000-0000-0000-0000-000000000001', '98520000-0000-0000-0000-000000000001',
     96, 3, 0, 96, 0, 96, 0, 0, 0, 0, 0);

DO $$
DECLARE
    v_authorized_user_id BIGINT;
    v_unauthorized_user_id BIGINT;
    v_row RECORD;
    v_count INT;
BEGIN
    INSERT INTO admin.portal_users
        (username, display_name, password_hash, role_code, is_active, created_by, access_scope_mode)
    VALUES
        ('periodic-contract-admin', 'Periodic Contract Admin', 'x', 'ADMIN', TRUE, 'test', 'GLOBAL')
    RETURNING portal_user_id INTO v_authorized_user_id;

    INSERT INTO admin.portal_users
        (username, display_name, password_hash, role_code, is_active, created_by, organization_id, access_scope_mode)
    VALUES
        ('periodic-contract-outsider', 'Periodic Contract Outsider', 'x', 'VIEWER', TRUE, 'test',
         '98500000-0000-0000-0000-000000000002', 'ORGANIZATION')
    RETURNING portal_user_id INTO v_unauthorized_user_id;

    -- ------------------------------------------------------------------
    -- WEEKLY: two weeks in range. Week 1 (Aug24 Mon .. Aug30 Sun) has 3 of
    -- 7 days present (10+20+7=37, PARTIAL -- the other 4 days genuinely
    -- have no row); Week 2 (Aug31 Mon .. Sep06 Sun) has 2 of 7 days
    -- present (5+3=8, also PARTIAL, and itself a partial trailing period
    -- since the requested range ends mid-week).
    -- ------------------------------------------------------------------
    SELECT bucket_start, import_consumption_kwh INTO v_row
    FROM analytics.get_portal_site_energy_consumption_periodic(
        v_authorized_user_id, '98510000-0000-0000-0000-000000000001',
        '2026-08-24T00:00:00+05:30'::timestamptz, '2026-09-02T00:00:00+05:30'::timestamptz, 'week'
    )
    ORDER BY bucket_start LIMIT 1 OFFSET 0;
    IF v_row.bucket_start IS DISTINCT FROM '2026-08-23T18:30:00+00'::timestamptz OR v_row.import_consumption_kwh IS DISTINCT FROM 37 THEN
        RAISE EXCEPTION 'Weekly week-1 assertion failed: got bucket_start=%, import_kwh=%', v_row.bucket_start, v_row.import_consumption_kwh;
    END IF;

    SELECT bucket_start, import_consumption_kwh INTO v_row
    FROM analytics.get_portal_site_energy_consumption_periodic(
        v_authorized_user_id, '98510000-0000-0000-0000-000000000001',
        '2026-08-24T00:00:00+05:30'::timestamptz, '2026-09-02T00:00:00+05:30'::timestamptz, 'week'
    )
    ORDER BY bucket_start LIMIT 1 OFFSET 1;
    IF v_row.bucket_start IS DISTINCT FROM '2026-08-30T18:30:00+00'::timestamptz OR v_row.import_consumption_kwh IS DISTINCT FROM 8 THEN
        RAISE EXCEPTION 'Weekly week-2 (partial trailing period) assertion failed: got bucket_start=%, import_kwh=%', v_row.bucket_start, v_row.import_consumption_kwh;
    END IF;

    SELECT count(*) INTO v_count FROM analytics.get_portal_site_energy_consumption_periodic(
        v_authorized_user_id, '98510000-0000-0000-0000-000000000001',
        '2026-08-24T00:00:00+05:30'::timestamptz, '2026-09-02T00:00:00+05:30'::timestamptz, 'week'
    );
    IF v_count != 2 THEN
        RAISE EXCEPTION 'Weekly assertion failed: expected exactly 2 buckets, got %', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- MONTHLY: August (10+20+7+5=42) and September (3) -- proves the
    -- cross-month boundary and a single-day trailing partial month.
    -- ------------------------------------------------------------------
    SELECT bucket_start, import_consumption_kwh INTO v_row
    FROM analytics.get_portal_site_energy_consumption_periodic(
        v_authorized_user_id, '98510000-0000-0000-0000-000000000001',
        '2026-08-24T00:00:00+05:30'::timestamptz, '2026-09-02T00:00:00+05:30'::timestamptz, 'month'
    )
    ORDER BY bucket_start LIMIT 1 OFFSET 0;
    IF v_row.bucket_start IS DISTINCT FROM '2026-08-23T18:30:00+00'::timestamptz OR v_row.import_consumption_kwh IS DISTINCT FROM 42 THEN
        RAISE EXCEPTION 'Monthly August assertion failed: got bucket_start=%, import_kwh=%', v_row.bucket_start, v_row.import_consumption_kwh;
    END IF;

    SELECT bucket_start, import_consumption_kwh INTO v_row
    FROM analytics.get_portal_site_energy_consumption_periodic(
        v_authorized_user_id, '98510000-0000-0000-0000-000000000001',
        '2026-08-24T00:00:00+05:30'::timestamptz, '2026-09-02T00:00:00+05:30'::timestamptz, 'month'
    )
    ORDER BY bucket_start LIMIT 1 OFFSET 1;
    IF v_row.bucket_start IS DISTINCT FROM '2026-08-31T18:30:00+00'::timestamptz OR v_row.import_consumption_kwh IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'Monthly September (partial trailing period) assertion failed: got bucket_start=%, import_kwh=%', v_row.bucket_start, v_row.import_consumption_kwh;
    END IF;

    -- ------------------------------------------------------------------
    -- YEARLY: all 5 days fall in 2026 -- 10+20+7+5+3=45, one bucket.
    -- ------------------------------------------------------------------
    SELECT bucket_start, import_consumption_kwh INTO v_row
    FROM analytics.get_portal_site_energy_consumption_periodic(
        v_authorized_user_id, '98510000-0000-0000-0000-000000000001',
        '2026-08-24T00:00:00+05:30'::timestamptz, '2026-09-02T00:00:00+05:30'::timestamptz, 'year'
    )
    ORDER BY bucket_start LIMIT 1;
    IF v_row.bucket_start IS DISTINCT FROM '2026-08-23T18:30:00+00'::timestamptz OR v_row.import_consumption_kwh IS DISTINCT FROM 45 THEN
        RAISE EXCEPTION 'Yearly assertion failed: got bucket_start=%, import_kwh=%', v_row.bucket_start, v_row.import_consumption_kwh;
    END IF;

    -- ------------------------------------------------------------------
    -- NO-DATA: a range with zero underlying rows returns zero rows (the
    -- has_data/no_data contract is derived from row COUNT upstream).
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count FROM analytics.get_portal_site_energy_consumption_periodic(
        v_authorized_user_id, '98510000-0000-0000-0000-000000000001',
        '2020-01-01T00:00:00Z'::timestamptz, '2020-02-01T00:00:00Z'::timestamptz, 'month'
    );
    IF v_count != 0 THEN
        RAISE EXCEPTION 'No-data assertion failed: expected 0 rows, got %', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- TENANT ISOLATION: a portal user with no access to this site/org
    -- gets zero rows, even though the site genuinely has data.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count FROM analytics.get_portal_site_energy_consumption_periodic(
        v_unauthorized_user_id, '98510000-0000-0000-0000-000000000001',
        '2026-08-24T00:00:00+05:30'::timestamptz, '2026-09-02T00:00:00+05:30'::timestamptz, 'month'
    );
    IF v_count != 0 THEN
        RAISE EXCEPTION 'Tenant isolation assertion failed: unauthorized portal user received % row(s)', v_count;
    END IF;

    RAISE NOTICE 'All migration 248 assertions passed.';
END
$$;

ROLLBACK;

SELECT 'Energy consumption periodic (Weekly/Monthly/Yearly) aggregation contract assertions passed.' AS result;
