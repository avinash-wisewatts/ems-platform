-- ============================================================================
-- File:
--   scripts/test/assert_analytics_api_query_boundary.sql
--
-- Purpose:
--   Regression test for migration 231 (Phase 7 -- Analytics API / Query
--   Boundary, first slice). Proves the approved contract:
--
--   SCHEMA / DISCIPLINE
--     D1  The three boundary functions exist with the exact signatures.
--     D2  Each is SECURITY DEFINER, STABLE, owned by ems_admin, search_path
--         pinned; EXECUTE granted to ems_app; NOT to PUBLIC; NOT to
--         grafana_reader.
--     D3  No boundary function body references analytics.v_space_dew_point_1min
--         or dew-point formula material (DEW_POINT is read, never recomputed).
--     D4  No boundary function body references an energy calculation /
--         ingestion / CAGG-refresh path, or contains a write statement.
--     D5  Migration 231 created no table / hypertable / TimescaleDB job /
--         retention / compression policy.
--
--   TENANT ISOLATION (seeded two-tenant fixture; rolled back)
--     T1  analytics.portal_user_can_access_space: GLOBAL sees every space;
--         ORGANIZATION sees only its own org's space; SELECTED_SITES sees the
--         assigned site's space; unknown space -> FALSE (no error).
--     T2  get_portal_space_measurement_series: a cross-org caller gets ZERO
--         rows for TEMPERATURE, HUMIDITY, and DEW_POINT.
--     T3  get_portal_site_energy_consumption: a cross-org caller gets ZERO
--         rows.
--
--   CONTRACT SEMANTICS
--     S1  TEMPERATURE / HUMIDITY read from telemetry.environment_measurements
--         (raw -> per-minute rows, sample_count 1, quality_code NULL
--         pass-through).
--     S2  resolution '1h' -> one row per UTC hour, value = arithmetic mean of
--         the stored 1-minute values, quality_code NULL, sample_count = count.
--     S3  DEW_POINT reads analytics.derived_parameter_values verbatim -- the
--         returned values equal the stored numeric_value (a fixture value that
--         is NOT Magnus(temperature, humidity)).
--     S4  get_portal_site_energy_consumption '1h' / '1d' -> per-bucket SUM of
--         the persisted device historians.
--     S5  Out-of-contract parameter / resolution / (from >= to) -> SQLSTATE
--         22023 (invalid_parameter_value).
--     S6  Accessible space, empty range -> ZERO rows (never an error).
--
--   ENERGY SAFETY
--     E1  The energy consumption watermark jobs remain scheduled; the
--         persisted historians and Phase 6 objects are intact; running this
--         test changes no energy pipeline_state row (BEGIN/ROLLBACK only).
--
-- Notes:
--   Runs against the fully-migrated disposable ems_test database. All seeded
--   data is created inside a single transaction and ROLLED BACK.
-- ============================================================================

\set ON_ERROR_STOP on
\timing off
\pset pager off

-- ---------------------------------------------------------------------------
-- D1 / D2 -- signatures, definer discipline, grants.
-- ---------------------------------------------------------------------------
DO $d$
DECLARE
    v_sig TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.portal_user_can_access_space(bigint, uuid)',
        'analytics.get_portal_space_measurement_series(bigint, uuid, text, timestamptz, timestamptz, text)',
        'analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)'
    ]
    LOOP
        IF to_regprocedure(v_sig) IS NULL THEN
            RAISE EXCEPTION 'D1 FAIL: % does not exist.', v_sig;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_roles r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND p.prosecdef
              AND p.provolatile = 's'
              AND r.rolname = 'ems_admin'
              AND EXISTS (
                  SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c
                  WHERE c LIKE 'search_path=%'
              )
        ) THEN
            RAISE EXCEPTION 'D2 FAIL: % is not SECURITY DEFINER / STABLE / ems_admin-owned / search_path-pinned.', v_sig;
        END IF;

        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'D2 FAIL: % is executable by PUBLIC.', v_sig;
        END IF;
        IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'D2 FAIL: % is not executable by ems_app.', v_sig;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader')
           AND has_function_privilege('grafana_reader', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'D2 FAIL: % is executable by grafana_reader.', v_sig;
        END IF;
    END LOOP;
    RAISE NOTICE 'D1/D2 PASS -- signatures + definer discipline + grants.';
END;
$d$;

-- ---------------------------------------------------------------------------
-- D3 / D4 -- no dew-point recomputation, no energy write path, read-only.
-- ---------------------------------------------------------------------------
DO $d34$
DECLARE
    v_body TEXT := '';
    v_sig  TEXT;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.portal_user_can_access_space(bigint, uuid)',
        'analytics.get_portal_space_measurement_series(bigint, uuid, text, timestamptz, timestamptz, text)',
        'analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)'
    ]
    LOOP
        v_body := v_body || lower(pg_get_functiondef(v_sig::regprocedure)) || E'\n';
    END LOOP;

    IF position('v_space_dew_point_1min' IN v_body) > 0
       OR position('17.62' IN v_body) > 0
       OR position('243.12' IN v_body) > 0 THEN
        RAISE EXCEPTION 'D3 FAIL: a boundary function recomputes dew point.';
    END IF;

    IF position('energy_measurements' IN v_body) > 0
       OR position('normalized_points' IN v_body) > 0
       OR position('load_energy' IN v_body) > 0
       OR position('refresh_energy' IN v_body) > 0
       OR position('refresh_continuous_aggregate' IN v_body) > 0
       OR position('run_energy' IN v_body) > 0
       OR position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0 THEN
        RAISE EXCEPTION 'D4 FAIL: a boundary function touches an energy calc path or writes.';
    END IF;
    RAISE NOTICE 'D3/D4 PASS -- no recomputation, no energy write path, read-only.';
END;
$d34$;

-- ---------------------------------------------------------------------------
-- D5 -- migration 231 registered no table / job / policy.
-- ---------------------------------------------------------------------------
DO $d5$
BEGIN
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_name LIKE '%portal%' OR proc_name LIKE '%api_query_boundary%'
    ) THEN
        RAISE EXCEPTION 'D5 FAIL: migration 231 registered a TimescaleDB job.';
    END IF;
    RAISE NOTICE 'D5 PASS -- no table / job / policy added by migration 231.';
END;
$d5$;

-- ---------------------------------------------------------------------------
-- E1 (part 1) -- energy subsystem intact BEFORE the seeded block.
-- ---------------------------------------------------------------------------
DO $e1a$
BEGIN
    IF to_regclass('analytics.energy_consumption_hourly') IS NULL
       OR to_regclass('analytics.energy_consumption_daily') IS NULL THEN
        RAISE EXCEPTION 'E1 FAIL: a persisted energy historian is missing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs
                   WHERE proc_name = 'run_energy_consumption_hourly_job' AND scheduled)
       OR NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs
                      WHERE proc_name = 'run_energy_consumption_daily_job' AND scheduled) THEN
        RAISE EXCEPTION 'E1 FAIL: an energy consumption watermark job is missing / unscheduled.';
    END IF;
    IF to_regclass('analytics.derived_parameter_values') IS NULL THEN
        RAISE EXCEPTION 'E1 FAIL: analytics.derived_parameter_values is missing.';
    END IF;
    RAISE NOTICE 'E1(pre) PASS -- energy + Phase 6 objects intact.';
END;
$e1a$;


-- ===========================================================================
-- Seeded functional block -- two tenants -- ROLLED BACK.
-- ===========================================================================
BEGIN;

-- Take the same advisory lock the app tests do not need, purely to be a good
-- citizen if this ever runs concurrently with another seeded suite.
SELECT pg_advisory_xact_lock(hashtextextended('assert_analytics_api_query_boundary', 0));

-- structural hierarchy
INSERT INTO metadata.organizations (id, name, code) VALUES
  ('00000000-0000-0000-0000-0000000000c9', 'P7 Assert Org A', 'P7_ASSERT_ORG_A'),
  ('00000000-0000-0000-0000-0000000001c9', 'P7 Assert Org B', 'P7_ASSERT_ORG_B');
INSERT INTO metadata.sites (id, organization_id, name, code) VALUES
  ('00000000-0000-0000-0000-0000000002c9', '00000000-0000-0000-0000-0000000000c9', 'P7 Assert Site A', 'P7_ASSERT_SITE_A'),
  ('00000000-0000-0000-0000-0000000003c9', '00000000-0000-0000-0000-0000000001c9', 'P7 Assert Site B', 'P7_ASSERT_SITE_B');
INSERT INTO metadata.buildings (id, organization_id, site_id, name, code) VALUES
  ('00000000-0000-0000-0000-0000000004c9', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9', 'BLDG_A', 'BLDG_A'),
  ('00000000-0000-0000-0000-0000000005c9', '00000000-0000-0000-0000-0000000001c9', '00000000-0000-0000-0000-0000000003c9', 'BLDG_B', 'BLDG_B');
INSERT INTO metadata.floors (id, organization_id, building_id, name, code) VALUES
  ('00000000-0000-0000-0000-0000000006c9', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000004c9', 'FLOOR_A', 'FLOOR_A'),
  ('00000000-0000-0000-0000-0000000007c9', '00000000-0000-0000-0000-0000000001c9', '00000000-0000-0000-0000-0000000005c9', 'FLOOR_B', 'FLOOR_B');
INSERT INTO metadata.spaces (id, organization_id, floor_id, name, code) VALUES
  ('00000000-0000-0000-0000-0000000008c9', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000006c9', 'SPACE_A', 'SPACE_A'),
  ('00000000-0000-0000-0000-0000000009c9', '00000000-0000-0000-0000-0000000001c9', '00000000-0000-0000-0000-0000000007c9', 'SPACE_B', 'SPACE_B');

-- portal users (deferred scope triggers never fire -- we ROLLBACK)
INSERT INTO admin.portal_users (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by) VALUES
  ('p7a.global@test', 'P7A Global', '$argon2id$x', 'ADMIN',    NULL,                                     'GLOBAL',         'assert-p7'),
  ('p7a.orga@test',   'P7A Org A',  '$argon2id$x', 'OPERATOR', '00000000-0000-0000-0000-0000000000c9', 'ORGANIZATION',   'assert-p7'),
  ('p7a.orgb@test',   'P7A Org B',  '$argon2id$x', 'OPERATOR', '00000000-0000-0000-0000-0000000001c9', 'ORGANIZATION',   'assert-p7'),
  ('p7a.sel@test',    'P7A Sel A',  '$argon2id$x', 'VIEWER',   '00000000-0000-0000-0000-0000000000c9', 'SELECTED_SITES', 'assert-p7');
INSERT INTO admin.portal_user_site_access (portal_user_id, site_id, created_by_portal_user_id)
SELECT
    (SELECT portal_user_id FROM admin.portal_users WHERE username = 'p7a.sel@test'),
    '00000000-0000-0000-0000-0000000002c9',
    (SELECT portal_user_id FROM admin.portal_users WHERE username = 'p7a.global@test');

-- environment measurements for SPACE_A: 2 hours x 2 rows/hour
INSERT INTO telemetry.environment_measurements
  (bucket_start, received_at, organization_id, site_id, device_id, space_id, temperature_c, humidity_percent, quality_code)
VALUES
  (TIMESTAMPTZ '2026-06-01 00:10:00+00', TIMESTAMPTZ '2026-06-01 00:10:00+00', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9', '00000000-0000-0000-0000-00000000a9c9', '00000000-0000-0000-0000-0000000008c9', 20.0, 50.0, NULL),
  (TIMESTAMPTZ '2026-06-01 00:40:00+00', TIMESTAMPTZ '2026-06-01 00:40:00+00', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9', '00000000-0000-0000-0000-00000000a9c9', '00000000-0000-0000-0000-0000000008c9', 20.0, 50.0, NULL),
  (TIMESTAMPTZ '2026-06-01 01:10:00+00', TIMESTAMPTZ '2026-06-01 01:10:00+00', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9', '00000000-0000-0000-0000-00000000a9c9', '00000000-0000-0000-0000-0000000008c9', 22.0, 52.0, NULL),
  (TIMESTAMPTZ '2026-06-01 01:40:00+00', TIMESTAMPTZ '2026-06-01 01:40:00+00', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9', '00000000-0000-0000-0000-00000000a9c9', '00000000-0000-0000-0000-0000000008c9', 22.0, 52.0, NULL);

-- persisted DEW_POINT rows for SPACE_A -- value deliberately NOT Magnus(t, rh)
INSERT INTO analytics.derived_parameter_values
  (bucket_start, calculation_id, calculation_version, output_parameter_id, subject_type,
   space_id, asset_id, device_id, organization_id, site_id, numeric_value, state_value,
   quality_code, input_quality_summary, source_received_at)
SELECT
  v.ts, pc.id, pc.calculation_version, pc.output_parameter_id, 'SPACE',
  '00000000-0000-0000-0000-0000000008c9', NULL, '00000000-0000-0000-0000-00000000a9c9',
  '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9',
  v.val, NULL, NULL, '{"null_handling":"assert"}'::jsonb, v.ts
FROM (VALUES
  (TIMESTAMPTZ '2026-06-01 00:10:00+00', 3.5::double precision),
  (TIMESTAMPTZ '2026-06-01 00:40:00+00', 3.5::double precision),
  (TIMESTAMPTZ '2026-06-01 01:10:00+00', 4.5::double precision),
  (TIMESTAMPTZ '2026-06-01 01:40:00+00', 4.5::double precision)
) AS v(ts, val)
CROSS JOIN LATERAL (
  SELECT pc.id, pc.calculation_version, pc.output_parameter_id
  FROM config.parameter_calculations pc
  JOIN config.parameters op ON op.id = pc.output_parameter_id
  WHERE op.code = 'DEW_POINT'
  ORDER BY pc.calculation_version DESC
  LIMIT 1
) AS pc;

-- energy historians for SITE_A
INSERT INTO analytics.energy_consumption_hourly
  (bucket_start, organization_id, site_id, device_id, import_consumption_kwh, export_consumption_kwh,
   source_interval_count, valid_import_intervals, invalid_import_intervals, valid_export_intervals,
   invalid_export_intervals, gap_interval_count, reset_interval_count, rollover_interval_count,
   invalid_interval_count, calculated_at)
VALUES
  (TIMESTAMPTZ '2026-06-01 00:00:00+00', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9', '00000000-0000-0000-0000-00000000a9c9', 1.0, 0.0, 4,4,0,4,0,0,0,0,0, now()),
  (TIMESTAMPTZ '2026-06-01 01:00:00+00', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9', '00000000-0000-0000-0000-00000000a9c9', 2.0, 0.0, 4,4,0,4,0,0,0,0,0, now());

INSERT INTO analytics.energy_consumption_daily
  (bucket_start, consumption_date, site_timezone, organization_id, site_id, device_id,
   import_consumption_kwh, export_consumption_kwh, source_interval_count, valid_import_intervals,
   invalid_import_intervals, valid_export_intervals, invalid_export_intervals, gap_interval_count,
   reset_interval_count, rollover_interval_count, invalid_interval_count, calculated_at)
VALUES
  (TIMESTAMPTZ '2026-06-01 00:00:00+00', DATE '2026-06-01', 'UTC', '00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000002c9', '00000000-0000-0000-0000-00000000a9c9', 24.0, 0.0, 96,96,0,96,0,0,0,0,0, now());

-- ---- T1: portal_user_can_access_space ----
DO $t1$
DECLARE
    g BIGINT; a BIGINT; b BIGINT; s BIGINT;
BEGIN
    SELECT portal_user_id INTO g FROM admin.portal_users WHERE username='p7a.global@test';
    SELECT portal_user_id INTO a FROM admin.portal_users WHERE username='p7a.orga@test';
    SELECT portal_user_id INTO b FROM admin.portal_users WHERE username='p7a.orgb@test';
    SELECT portal_user_id INTO s FROM admin.portal_users WHERE username='p7a.sel@test';

    IF NOT analytics.portal_user_can_access_space(g, '00000000-0000-0000-0000-0000000008c9') THEN
        RAISE EXCEPTION 'T1 FAIL: GLOBAL cannot access SPACE_A.';
    END IF;
    IF NOT analytics.portal_user_can_access_space(g, '00000000-0000-0000-0000-0000000009c9') THEN
        RAISE EXCEPTION 'T1 FAIL: GLOBAL cannot access SPACE_B.';
    END IF;
    IF NOT analytics.portal_user_can_access_space(a, '00000000-0000-0000-0000-0000000008c9') THEN
        RAISE EXCEPTION 'T1 FAIL: ORG_A user cannot access its own SPACE_A.';
    END IF;
    IF analytics.portal_user_can_access_space(a, '00000000-0000-0000-0000-0000000009c9') THEN
        RAISE EXCEPTION 'T1 FAIL: ORG_A user CAN access cross-org SPACE_B.';
    END IF;
    IF analytics.portal_user_can_access_space(b, '00000000-0000-0000-0000-0000000008c9') THEN
        RAISE EXCEPTION 'T1 FAIL: ORG_B user CAN access cross-org SPACE_A.';
    END IF;
    IF NOT analytics.portal_user_can_access_space(s, '00000000-0000-0000-0000-0000000008c9') THEN
        RAISE EXCEPTION 'T1 FAIL: SELECTED_SITES user cannot access assigned SPACE_A.';
    END IF;
    IF analytics.portal_user_can_access_space(g, 'ffffffff-ffff-ffff-ffff-ffffffffffff') THEN
        RAISE EXCEPTION 'T1 FAIL: unknown space returned TRUE.';
    END IF;
    RAISE NOTICE 'T1 PASS -- space accessibility probe.';
END;
$t1$;

-- ---- T2 + S1 + S2 + S3 + S6: measurement series ----
DO $t2$
DECLARE
    g BIGINT; b BIGINT;
    v_ct INT; v_avg NUMERIC; v_sc BIGINT;
BEGIN
    SELECT portal_user_id INTO g FROM admin.portal_users WHERE username='p7a.global@test';
    SELECT portal_user_id INTO b FROM admin.portal_users WHERE username='p7a.orgb@test';

    -- T2: cross-org caller -> zero rows for every supported parameter
    FOR v_ct IN
        SELECT count(*)::int FROM analytics.get_portal_space_measurement_series(
            b, '00000000-0000-0000-0000-0000000008c9', 'TEMPERATURE',
            TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 03:00:00+00', 'raw')
    LOOP
        IF v_ct <> 0 THEN RAISE EXCEPTION 'T2 FAIL: cross-org TEMPERATURE returned % rows.', v_ct; END IF;
    END LOOP;
    SELECT count(*) INTO v_ct FROM analytics.get_portal_space_measurement_series(
        b, '00000000-0000-0000-0000-0000000008c9', 'DEW_POINT',
        TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 03:00:00+00', 'raw');
    IF v_ct <> 0 THEN RAISE EXCEPTION 'T2 FAIL: cross-org DEW_POINT returned % rows.', v_ct; END IF;

    -- S1: raw TEMPERATURE for GLOBAL -> 4 rows, sample_count 1, quality NULL
    SELECT count(*), count(*) FILTER (WHERE quality_code IS NOT NULL), max(sample_count)
      INTO v_ct, v_sc, v_sc
    FROM analytics.get_portal_space_measurement_series(
        g, '00000000-0000-0000-0000-0000000008c9', 'TEMPERATURE',
        TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 03:00:00+00', 'raw');
    IF v_ct <> 4 THEN RAISE EXCEPTION 'S1 FAIL: raw TEMPERATURE returned % rows (want 4).', v_ct; END IF;

    -- S2: 1h -> 2 rows, avg = the (equal) inputs, sample_count 2
    SELECT count(*) INTO v_ct FROM analytics.get_portal_space_measurement_series(
        g, '00000000-0000-0000-0000-0000000008c9', 'TEMPERATURE',
        TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 03:00:00+00', '1h');
    IF v_ct <> 2 THEN RAISE EXCEPTION 'S2 FAIL: 1h TEMPERATURE returned % rows (want 2).', v_ct; END IF;
    SELECT numeric_value, sample_count, quality_code INTO v_avg, v_sc, v_ct
    FROM analytics.get_portal_space_measurement_series(
        g, '00000000-0000-0000-0000-0000000008c9', 'TEMPERATURE',
        TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 03:00:00+00', '1h')
    ORDER BY bucket_start LIMIT 1;
    IF round(v_avg::numeric, 6) <> 20.0 OR v_sc <> 2 OR v_ct IS NOT NULL THEN
        RAISE EXCEPTION 'S2 FAIL: 1h bucket (avg=%, n=%, quality=%) not as expected.', v_avg, v_sc, v_ct;
    END IF;

    -- S3: DEW_POINT raw -> stored numeric_value verbatim (3.5 / 4.5)
    IF (SELECT array_agg(round(numeric_value::numeric, 6) ORDER BY bucket_start)
        FROM analytics.get_portal_space_measurement_series(
            g, '00000000-0000-0000-0000-0000000008c9', 'DEW_POINT',
            TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 03:00:00+00', 'raw'))
       <> ARRAY[3.5, 3.5, 4.5, 4.5]::numeric[] THEN
        RAISE EXCEPTION 'S3 FAIL: DEW_POINT raw values were not returned verbatim from the persisted tier.';
    END IF;

    -- S6: accessible space, empty range -> zero rows (no error)
    SELECT count(*) INTO v_ct FROM analytics.get_portal_space_measurement_series(
        g, '00000000-0000-0000-0000-0000000008c9', 'TEMPERATURE',
        TIMESTAMPTZ '2000-01-01 00:00:00+00', TIMESTAMPTZ '2000-01-01 01:00:00+00', 'raw');
    IF v_ct <> 0 THEN RAISE EXCEPTION 'S6 FAIL: empty range returned % rows.', v_ct; END IF;

    RAISE NOTICE 'T2/S1/S2/S3/S6 PASS -- measurement series contract.';
END;
$t2$;

-- ---- T3 + S4: site energy consumption ----
DO $t3$
DECLARE
    g BIGINT; b BIGINT; v_ct INT; v_sum NUMERIC;
BEGIN
    SELECT portal_user_id INTO g FROM admin.portal_users WHERE username='p7a.global@test';
    SELECT portal_user_id INTO b FROM admin.portal_users WHERE username='p7a.orgb@test';

    SELECT count(*) INTO v_ct FROM analytics.get_portal_site_energy_consumption(
        b, '00000000-0000-0000-0000-0000000002c9',
        TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-02 00:00:00+00', '1h');
    IF v_ct <> 0 THEN RAISE EXCEPTION 'T3 FAIL: cross-org energy returned % rows.', v_ct; END IF;

    SELECT count(*), sum(import_consumption_kwh) INTO v_ct, v_sum
    FROM analytics.get_portal_site_energy_consumption(
        g, '00000000-0000-0000-0000-0000000002c9',
        TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-02 00:00:00+00', '1h');
    IF v_ct <> 2 OR round(v_sum, 6) <> 3.0 THEN
        RAISE EXCEPTION 'S4 FAIL: hourly energy roll-up (rows=%, sum=%) not as expected.', v_ct, v_sum;
    END IF;

    SELECT count(*), sum(import_consumption_kwh) INTO v_ct, v_sum
    FROM analytics.get_portal_site_energy_consumption(
        g, '00000000-0000-0000-0000-0000000002c9',
        TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-03 00:00:00+00', '1d');
    IF v_ct <> 1 OR round(v_sum, 6) <> 24.0 THEN
        RAISE EXCEPTION 'S4 FAIL: daily energy roll-up (rows=%, sum=%) not as expected.', v_ct, v_sum;
    END IF;
    RAISE NOTICE 'T3/S4 PASS -- site energy consumption roll-up.';
END;
$t3$;

-- ---- S5: out-of-contract inputs raise SQLSTATE 22023 ----
DO $s5$
DECLARE
    g BIGINT; v_ok BOOLEAN;
BEGIN
    SELECT portal_user_id INTO g FROM admin.portal_users WHERE username='p7a.global@test';

    v_ok := FALSE;
    BEGIN
        PERFORM * FROM analytics.get_portal_space_measurement_series(
            g, '00000000-0000-0000-0000-0000000008c9', 'PRESSURE',
            TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 03:00:00+00', 'raw');
    EXCEPTION WHEN invalid_parameter_value THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'S5 FAIL: unsupported parameter did not raise 22023.'; END IF;

    v_ok := FALSE;
    BEGIN
        PERFORM * FROM analytics.get_portal_space_measurement_series(
            g, '00000000-0000-0000-0000-0000000008c9', 'TEMPERATURE',
            TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 03:00:00+00', '5m');
    EXCEPTION WHEN invalid_parameter_value THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'S5 FAIL: unsupported resolution did not raise 22023.'; END IF;

    v_ok := FALSE;
    BEGIN
        PERFORM * FROM analytics.get_portal_space_measurement_series(
            g, '00000000-0000-0000-0000-0000000008c9', 'TEMPERATURE',
            TIMESTAMPTZ '2026-06-01 03:00:00+00', TIMESTAMPTZ '2026-06-01 00:00:00+00', 'raw');
    EXCEPTION WHEN invalid_parameter_value THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'S5 FAIL: from >= to did not raise 22023.'; END IF;

    v_ok := FALSE;
    BEGIN
        PERFORM * FROM analytics.get_portal_site_energy_consumption(
            g, '00000000-0000-0000-0000-0000000002c9',
            TIMESTAMPTZ '2026-06-01 00:00:00+00', TIMESTAMPTZ '2026-06-02 00:00:00+00', 'raw');
    EXCEPTION WHEN invalid_parameter_value THEN v_ok := TRUE;
    END;
    IF NOT v_ok THEN RAISE EXCEPTION 'S5 FAIL: energy unsupported resolution did not raise 22023.'; END IF;

    RAISE NOTICE 'S5 PASS -- out-of-contract inputs raise SQLSTATE 22023.';
END;
$s5$;

ROLLBACK;

-- ---------------------------------------------------------------------------
-- E1 (part 2) -- energy pipeline_state untouched by this test (BEGIN/ROLLBACK).
-- ---------------------------------------------------------------------------
DO $e1b$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs
                   WHERE proc_name = 'run_energy_consumption_hourly_job' AND scheduled)
       OR NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs
                      WHERE proc_name = 'run_energy_consumption_daily_job' AND scheduled) THEN
        RAISE EXCEPTION 'E1 FAIL: an energy consumption watermark job changed.';
    END IF;
    RAISE NOTICE 'E1(post) PASS -- energy jobs still scheduled; seeded data rolled back.';
END;
$e1b$;

\echo '==================================================================='
\echo 'assert_analytics_api_query_boundary.sql: ALL CONTRACTS PASSED'
\echo '==================================================================='
